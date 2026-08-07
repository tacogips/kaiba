import AppCore
import Foundation

var arguments = Array(CommandLine.arguments.dropFirst())

func extractNoteRoot(from arguments: inout [String]) -> String {
  var noteRootOverride: String?
  if let rootIndex = arguments.firstIndex(of: "--note-root") {
    guard rootIndex + 1 < arguments.count else {
      FileHandle.standardError.write(Data("Error: missing value for --note-root\n".utf8))
      exit(2)
    }
    noteRootOverride = arguments[rootIndex + 1]
    arguments.removeSubrange(rootIndex...(rootIndex + 1))
  }
  return AppCommand(arguments: []).resolveNoteRoot(override: noteRootOverride)
}

// `kaiba serve` and `kaiba graphql` are async paths; everything else stays on
// the synchronous AppCommand router.
if let serveIndex = arguments.firstIndex(of: "serve"),
  !arguments.contains("--help"), !arguments.contains("-h") {
  var serveArguments = arguments
  serveArguments.remove(at: serveIndex)
  let noteRoot = extractNoteRoot(from: &serveArguments)
  do {
    let options = try ServeCommand.parse(arguments: serveArguments, noteRoot: noteRoot)
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
  let noteRoot = extractNoteRoot(from: &graphqlArguments)
  do {
    let options = try GraphQLCommand.parse(arguments: graphqlArguments, noteRoot: noteRoot)
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
