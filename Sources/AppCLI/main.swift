import AppCore
import Foundation

var arguments = Array(CommandLine.arguments.dropFirst())

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
if let serveIndex = arguments.firstIndex(of: "serve"),
  !arguments.contains("--help"), !arguments.contains("-h") {
  var serveArguments = arguments
  serveArguments.remove(at: serveIndex)
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

if let graphqlIndex = arguments.firstIndex(of: "graphql"),
  !arguments.contains("--help"), !arguments.contains("-h") {
  var graphqlArguments = arguments
  graphqlArguments.remove(at: graphqlIndex)
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
  } catch {
    FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
    exit(1)
  }
}

// `ai` must be the command itself (only the global option pairs may precede
// it) so values like `kaiba search ai` are never hijacked.
func isCommandToken(at index: Int, in arguments: [String]) -> Bool {
  var cursor = 0
  while cursor < index {
    if arguments[cursor] == "--note-root" || arguments[cursor] == "--config" {
      cursor += 2
    } else {
      return false
    }
  }
  return cursor == index
}

if let aiIndex = arguments.firstIndex(of: "ai"), isCommandToken(at: aiIndex, in: arguments),
  !arguments.contains("--help"), !arguments.contains("-h") {
  var aiArguments = arguments
  aiArguments.remove(at: aiIndex)
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
