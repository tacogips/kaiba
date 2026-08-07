import AppCore
import Foundation

var arguments = Array(CommandLine.arguments.dropFirst())

// `kaiba serve` is the long-running async path; everything else stays on the
// synchronous AppCommand router.
if let serveIndex = arguments.firstIndex(of: "serve"),
  !arguments.contains("--help"), !arguments.contains("-h") {
  var serveArguments = arguments
  serveArguments.remove(at: serveIndex)
  var noteRootOverride: String?
  if let rootIndex = serveArguments.firstIndex(of: "--note-root") {
    guard rootIndex + 1 < serveArguments.count else {
      FileHandle.standardError.write(Data("Error: missing value for --note-root\n".utf8))
      exit(2)
    }
    noteRootOverride = serveArguments[rootIndex + 1]
    serveArguments.removeSubrange(rootIndex...(rootIndex + 1))
  }
  let noteRoot = AppCommand(arguments: []).resolveNoteRoot(override: noteRootOverride)
  do {
    let options = try ServeCommand.parse(arguments: serveArguments, noteRoot: noteRoot)
    try await ServeCommand.run(options)
    exit(0)
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
