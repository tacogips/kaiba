import AppCore
import Foundation
import KaibaCLIKit
import KaibaClient

var arguments = Array(CommandLine.arguments.dropFirst())

// Resolve the command once from the positional grammar. Only complete global
// option pairs may precede it, so later option values can never become commands.
func resolvedCommandToken(in arguments: [String]) -> (index: Int, value: String)? {
  var cursor = 0
  while cursor < arguments.count {
    if arguments[cursor] == "--note-root" || arguments[cursor] == "--config" {
      guard cursor + 1 < arguments.count else { return nil }
      cursor += 2
    } else {
      return (cursor, arguments[cursor])
    }
  }
  return nil
}

func commandRequestsHelp(
  in arguments: [String],
  valueOptions: Set<String>
) -> Bool {
  var cursor = 0
  while cursor < arguments.count {
    let argument = arguments[cursor]
    if valueOptions.contains(argument) {
      cursor += 2
    } else {
      if argument == "--help" || argument == "-h" { return true }
      cursor += 1
    }
  }
  return false
}

func extractGlobalConfiguration(
  from arguments: inout [String]
) throws -> (noteRoot: String, configuration: KaibaConfiguration) {
  let resolver = AppCommand(arguments: [])
  var noteRootOverride: String?
  if let rootIndex = arguments.firstIndex(of: "--note-root") {
    guard rootIndex + 1 < arguments.count else {
      FileHandle.standardError.write(Data("Error: missing value for --note-root\n".utf8))
      exit(2)
    }
    noteRootOverride = arguments[rootIndex + 1]
    arguments.removeSubrange(rootIndex...(rootIndex + 1))
  }
  var configPathOverride: String?
  if let configIndex = arguments.firstIndex(of: "--config") {
    guard configIndex + 1 < arguments.count else {
      FileHandle.standardError.write(Data("Error: missing value for --config\n".utf8))
      exit(2)
    }
    configPathOverride = arguments[configIndex + 1]
    arguments.removeSubrange(configIndex...(configIndex + 1))
  }
  let path = resolver.resolveConfigPath(override: configPathOverride)
  return (
    resolver.resolveNoteRoot(override: noteRootOverride),
    try KaibaConfigurationLoader.load(
      at: path,
      required: configPathOverride != nil
        || !(ProcessInfo.processInfo.environment["KAIBA_CONFIG_PATH"] ?? "").isEmpty
    )
  )
}

// `kaiba serve` and `kaiba graphql` are async paths; everything else stays on
// the synchronous AppCommand router.
let commandToken = resolvedCommandToken(in: arguments)

if let commandToken, commandToken.value == "serve",
  !commandRequestsHelp(
    in: Array(arguments.dropFirst(commandToken.index + 1)),
    valueOptions: ["--host", "--port", "--web-root", "--note-root", "--config"]
  ) {
  var serveArguments = arguments
  serveArguments.remove(at: commandToken.index)
  do {
    let global = try extractGlobalConfiguration(from: &serveArguments)
    let options = try ServeCommand.parse(
      arguments: serveArguments,
      noteRoot: global.noteRoot,
      configuration: global.configuration
    )
    try await ServeCommand.run(options)
    exit(0)
  } catch {
    FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
    exit(1)
  }
}

if let commandToken, commandToken.value == "graphql" {
  let commandArguments = Array(arguments.dropFirst(commandToken.index + 1))
  let graphQLValueOptions: Set<String> = [
    "--endpoint", "--api-key-env", "--file", "--variables", "--operation",
    "--filter", "--output", "--note-root", "--config"
  ]
  let requestsHelp = commandRequestsHelp(
    in: commandArguments,
    valueOptions: graphQLValueOptions
  )
  if GraphQLSchemaCommand.isSchemaSubcommand(arguments: commandArguments), !requestsHelp {
    let leadingGlobalArguments = Array(arguments[..<commandToken.index])
    let schemaArguments = leadingGlobalArguments + commandArguments.dropFirst()
    let result = await GraphQLSchemaCommand.run(arguments: Array(schemaArguments))
    if !result.standardOutput.isEmpty {
      FileHandle.standardOutput.write(Data((result.standardOutput + "\n").utf8))
    }
    if !result.standardError.isEmpty {
      FileHandle.standardError.write(Data((result.standardError + "\n").utf8))
    }
    exit(result.exitCode)
  } else if !requestsHelp {
    var graphqlArguments = arguments
    graphqlArguments.remove(at: commandToken.index)
    do {
      let global = try extractGlobalConfiguration(from: &graphqlArguments)
      let options = try GraphQLCommand.parse(
        arguments: graphqlArguments,
        noteRoot: global.noteRoot,
        configuration: global.configuration
      )
      let (output, exitCode) = try await GraphQLCommand.run(options)
      if !output.isEmpty {
        print(output)
      }
      exit(exitCode)
    } catch let error as GraphQLSchemaCommandError {
      FileHandle.standardError.write(Data((error.description + "\n").utf8))
      exit(2)
    } catch let error as KaibaClientError {
      FileHandle.standardError.write(Data((error.description + "\n").utf8))
      switch error {
      case .invalidEndpoint, .invalidConfiguration, .invalidRequest, .invalidRegex:
        exit(2)
      default:
        exit(1)
      }
    } catch {
      FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
      exit(1)
    }
  }
}

if let commandToken, commandToken.value == "ai",
  !commandRequestsHelp(
    in: Array(arguments.dropFirst(commandToken.index + 1)),
    valueOptions: [
      "--note", "--notebook", "--resume", "--to", "--provider", "--model",
      "--title", "--output", "--limit", "--note-root", "--config"
    ]
  ) {
  var aiArguments = arguments
  aiArguments.remove(at: commandToken.index)
  do {
    let global = try extractGlobalConfiguration(from: &aiArguments)
    let options = try AICommand.parse(
      arguments: aiArguments,
      noteRoot: global.noteRoot,
      configuration: global.configuration
    )
    let (output, exitCode) = try await AICommand.run(options)
    if !output.isEmpty {
      if exitCode == 0 {
        print(output)
      } else {
        FileHandle.standardError.write(Data((output + "\n").utf8))
      }
    }
    exit(exitCode)
  } catch {
    FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
    exit(1)
  }
}

let command = AppCommand(arguments: arguments)

do {
  let output = try command.run()
  if !output.isEmpty {
    print(output)
  }
} catch AppCommand.Error.unknownArgument(let argument) {
  FileHandle.standardError.write(Data("Unknown argument: \(argument)\n".utf8))
  exit(2)
} catch {
  FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
  exit(1)
}
