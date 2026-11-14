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
    /// When set, the document is sent to this kaiba server's POST /graphql
    /// endpoint instead of executing against the local store.
    var endpoint: URL?
    /// Environment-variable NAME holding the API key for --endpoint requests;
    /// the secret value itself never appears on the command line.
    var apiKeyEnvironmentVariable: String?
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
    var endpointRaw: String?
    var apiKeyEnvironmentVariable: String?
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--endpoint":
        guard let value = iterator.next() else { throw GraphQLCommandError.missingValue(argument) }
        endpointRaw = value
      case "--api-key-env":
        guard let value = iterator.next() else { throw GraphQLCommandError.missingValue(argument) }
        apiKeyEnvironmentVariable = value
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
    var endpoint: URL?
    if let endpointRaw {
      guard let url = URL(string: endpointRaw), url.scheme != nil, url.host != nil else {
        throw GraphQLCommandError.invalidUsage("--endpoint expects an http(s) URL, got: \(endpointRaw)")
      }
      endpoint = url
    }
    if apiKeyEnvironmentVariable != nil, endpoint == nil {
      throw GraphQLCommandError.invalidUsage("--api-key-env requires --endpoint")
    }
    return Options(
      noteRoot: noteRoot,
      configuration: configuration,
      document: query,
      variables: variables,
      operationName: operationName,
      endpoint: endpoint,
      apiKeyEnvironmentVariable: apiKeyEnvironmentVariable
    )
  }

  /// Returns (output, exitCode). GraphQL-level errors exit 1 with the body
  /// still printed so scripts can inspect diagnostics.
  static func run(_ options: Options) async throws -> (String, Int32) {
    let executor: any GraphQLDocumentExecuting
    if let endpoint = options.endpoint {
      var bearerToken: String?
      if let variableName = options.apiKeyEnvironmentVariable {
        guard let token = ProcessInfo.processInfo.environment[variableName], !token.isEmpty else {
          throw GraphQLCommandError.invalidUsage(
            "environment variable \(variableName) is not set (--api-key-env)"
          )
        }
        bearerToken = token
      }
      executor = GraphQLHTTPDocumentClient(
        endpoint: GraphQLHTTPDocumentClient.endpointURL(from: endpoint),
        bearerToken: bearerToken
      )
    } else {
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
      let aiConfiguration = options.configuration.ai
      executor = NoteGraphQLDocumentExecutor(
        service: GraphQLNoteGraphQLService(
          service: service,
          agentInvoker: AgentInvokerFactory.makeInvoker(configuration: aiConfiguration),
          agentProvider: aiConfiguration?.agent?.provider,
          agentModel: aiConfiguration?.agent?.model,
          agentModelCatalog: graphQLAgentModelCatalog(configuration: aiConfiguration)
        ),
        s3Profiles: try KaibaConfigurationLoader.makeS3Profiles(
          configuration: options.configuration,
          environment: ProcessInfo.processInfo.environment
        )
      )
    }
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

private func graphQLAgentModelCatalog(
  configuration: KaibaAIConfiguration?
) -> (@Sendable () async throws -> AgentGatewayModelCatalogResult)? {
  guard let agent = configuration?.agent, let provider = agent.provider, !provider.isEmpty else { return nil }
  return {
    try await AgentGatewayCLIModelCatalog(
      commandPath: agent.commandPath,
      vendor: provider,
      apiKeyEnvironment: agent.apiKeyEnvironmentVariable
    ).models()
  }
}
