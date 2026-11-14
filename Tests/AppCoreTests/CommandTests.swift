import Foundation
import Testing
@testable import AppCore

@Test func packageVersionMatchesVersionFile() throws {
  let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let versionFile = repositoryRoot.appendingPathComponent("VERSION")
  let declaredVersion = try String(contentsOf: versionFile, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)

  #expect(Version.current == declaredVersion)
}

@Test func commandReportsVersion() throws {
  let command = AppCommand(arguments: ["--version"])
  #expect(try command.run() == Version.current)
}

@Test func commandReportsUsage() throws {
  let command = AppCommand(arguments: ["--help"])
  #expect(try command.run().contains("Usage: kaiba"))
}

@Test func commandRejectsUnknownFlags() throws {
  let command = AppCommand(arguments: ["--unknown"])
  do {
    _ = try command.run()
    Issue.record("Expected an unknown argument error")
  } catch AppCommand.Error.unknownArgument(let argument) {
    #expect(argument == "--unknown")
  } catch {
    Issue.record("Unexpected error: \(error)")
  }
}
