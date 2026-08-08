import AppCore
import AppGraphQL
import Foundation

/// `kaiba graphql` — execute a note GraphQL document against the local store
/// and print the JSON response body ("data"/"errors") to stdout.
struct GraphQLCommand {
  struct Options {
    var noteRoot: String
    var configuration: KaibaConfiguration
    var document: String
    var variables: JSONObject = [:]
    var operationName: String?
  }

  enum GraphQLCommandError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case missingValue(String)
    case invalidUsage(String)

    var description: String {
      switch self {
      case .invalidArgument(let argument): return "unknown graphql argument: \(argument)"
      case .missingValue(let option): return "missing value for \(option)"
      case .invalidUsage(let message): return message
      }
    }
  }

  static func parse(
    arguments: [String],
    noteRoot: String,
    configuration: KaibaConfiguration = KaibaConfiguration()
  ) throws -> Options {
    var document: String?
    var file: String?
    var readStdin = false
    var variablesRaw: String?
    var operationName: String?
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--file":
        guard let value = iterator.next() else { throw GraphQLCommandError.missingValue(argument) }
        file = value
      case "--variables":
        guard let value = iterator.next() else { throw GraphQLCommandError.missingValue(argument) }
        variablesRaw = value
      case "--operation":
        guard let value = iterator.next() else { throw GraphQLCommandError.missingValue(argument) }
        operationName = value
      case "-":
        readStdin = true
      default:
        if argument.hasPrefix("-") {
          throw GraphQLCommandError.invalidArgument(argument)
        }
        guard document == nil else {
          throw GraphQLCommandError.invalidUsage("multiple documents were provided")
        }
        document = argument
      }
    }

    let sources = [document != nil, file != nil, readStdin].filter { $0 }
    guard sources.count == 1 else {
      throw GraphQLCommandError.invalidUsage(
        "graphql requires exactly one of <document>, --file <path>, or -"
      )
    }
    let query: String
    if let document {
      query = document
    } else if let file {
      query = try String(
        contentsOf: URL(fileURLWithPath: (file as NSString).expandingTildeInPath),
        encoding: .utf8
      )
    } else {
      let data = FileHandle.standardInput.readDataToEndOfFile()
      guard let text = String(data: data, encoding: .utf8) else {
        throw GraphQLCommandError.invalidUsage("stdin is not valid UTF-8")
      }
      query = text
    }

    var variables: JSONObject = [:]
    if let variablesRaw {
      guard
        let value = try? JSONDecoder().decode(JSONValue.self, from: Data(variablesRaw.utf8)),
        case let .object(object) = value
      else {
        throw GraphQLCommandError.invalidUsage("--variables expects a JSON object")
      }
      variables = object
    }
    return Options(
      noteRoot: noteRoot,
      configuration: configuration,
      document: query,
      variables: variables,
      operationName: operationName
    )
  }

  /// Returns (output, exitCode). GraphQL-level errors exit 1 with the body
  /// still printed so scripts can inspect diagnostics.
  static func run(_ options: Options) async throws -> (String, Int32) {
    try FileManager.default.createDirectory(
      atPath: options.noteRoot,
      withIntermediateDirectories: true
    )
    let service = try NoteService(
      driver: KaibaConfigurationLoader.makeDriver(
        configuration: options.configuration.database,
        noteRoot: options.noteRoot,
        environment: ProcessInfo.processInfo.environment
      )
    )
    let executor = NoteGraphQLDocumentExecutor(
      service: GraphQLNoteGraphQLService(service: service),
      s3Profiles: try KaibaConfigurationLoader.makeS3Profiles(
        configuration: options.configuration,
        environment: ProcessInfo.processInfo.environment
      )
    )
    let response = await executor.execute(GraphQLDocumentRequest(
      query: options.document,
      variables: options.variables,
      operationName: options.operationName
    ))
    guard response.handled else {
      return ("Error: the document contains no supported note GraphQL root field", 1)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let body = String(
      data: try encoder.encode(JSONValue.object(response.body)),
      encoding: .utf8
    ) ?? "{}"
    let failed = response.status >= 400 || response.body["errors"] != nil
    return (body, failed ? 1 : 0)
  }
}
