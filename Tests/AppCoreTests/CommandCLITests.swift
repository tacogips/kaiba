import Foundation
import Testing

@testable import AppCore

private func makeTempRoot(function: String = #function) throws -> String {
  let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("AppCoreTests-cli", isDirectory: true)
    .appendingPathComponent("\(function)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root.path
}

private func run(_ arguments: [String], root: String) throws -> String {
  try AppCommand(arguments: ["--note-root", root] + arguments, environment: [:]).run()
}

private func noteId(fromJSON output: String) throws -> String {
  let object = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
  return try #require(object?["noteId"] as? String)
}

@Test func cliNoteRootResolutionPrecedence() throws {
  let command = AppCommand(arguments: [], environment: ["KAIBA_NOTE_ROOT": "/env/root"])
  #expect(command.resolveNoteRoot(override: "/cli/root") == "/cli/root")
  #expect(command.resolveNoteRoot(override: nil) == "/env/root")
  let fallback = AppCommand(arguments: [], environment: [:])
  #expect(fallback.resolveNoteRoot(override: nil).hasSuffix("/.kaiba"))
}

@Test func cliRejectsUnknownCommand() throws {
  do {
    _ = try AppCommand(arguments: ["bogus"], environment: [:]).run()
    Issue.record("Expected an unknown command error")
  } catch AppCommand.Error.unknownCommand(let command) {
    #expect(command == "bogus")
  }
}

@Test func cliAddShowListRoundTrip() throws {
  let root = try makeTempRoot()
  let created = try run(
    ["add", "--body", "# Round Trip\nBody text.", "--tag", "idea", "--output", "json"],
    root: root
  )
  let id = try noteId(fromJSON: created)

  let shown = try run(["show", id], root: root)
  #expect(shown.contains("# Round Trip"))
  #expect(shown.contains("#idea"))

  let listed = try run(["list"], root: root)
  #expect(listed.contains(id))
  #expect(listed.contains("Round Trip"))
}

@Test func cliEditAppendsAndSearchFinds() throws {
  let root = try makeTempRoot()
  let id = try noteId(fromJSON: try run(
    ["add", "--body", "# Searchable\nOriginal content.", "--output", "json"],
    root: root
  ))
  _ = try run(["edit", id, "--body", "Appended trailer.", "--append"], root: root)

  let shown = try run(["show", id], root: root)
  #expect(shown.contains("Original content."))
  #expect(shown.contains("Appended trailer."))

  let found = try run(["search", "Appended"], root: root)
  #expect(found.contains(id))
}

@Test func cliTagAddRemoveAndHierarchyFilter() throws {
  let root = try makeTempRoot()
  _ = try run(["tag-define", "parent-topic"], root: root)
  _ = try run(["tag-define", "child-topic", "--parent", "parent-topic"], root: root)
  let id = try noteId(fromJSON: try run(
    ["add", "--body", "# Tagged\nBody.", "--tag", "child-topic", "--output", "json"],
    root: root
  ))

  let filtered = try run(["list", "--tag", "parent-topic"], root: root)
  #expect(filtered.contains(id))

  _ = try run(["tag", id, "--remove", "child-topic"], root: root)
  let afterRemoval = try run(["list", "--tag", "parent-topic"], root: root)
  #expect(!afterRemoval.contains(id))
}

@Test func cliReadOnlyBlocksEditAndDelete() throws {
  let root = try makeTempRoot()
  let id = try noteId(fromJSON: try run(
    ["add", "--body", "# Locked\nBody.", "--output", "json"],
    root: root
  ))
  _ = try run(["readonly", id, "--on"], root: root)

  #expect(throws: NoteServiceError.readOnly(id)) {
    _ = try run(["edit", id, "--body", "x"], root: root)
  }
  #expect(throws: NoteServiceError.readOnly(id)) {
    _ = try run(["delete", id], root: root)
  }

  _ = try run(["readonly", id, "--off"], root: root)
  _ = try run(["delete", id], root: root)
  #expect(!(try run(["list"], root: root)).contains(id))
}

@Test func cliAttachCommentLinkAppearInShow() throws {
  let root = try makeTempRoot()
  let first = try noteId(fromJSON: try run(
    ["add", "--body", "# First\nBody.", "--output", "json"],
    root: root
  ))
  let second = try noteId(fromJSON: try run(
    ["add", "--body", "# Second\nBody.", "--output", "json"],
    root: root
  ))

  let attachmentPath = (root as NSString).appendingPathComponent("attachment.txt")
  try Data("attached-bytes".utf8).write(to: URL(fileURLWithPath: attachmentPath))
  _ = try run(["attach", first, attachmentPath], root: root)
  _ = try run(["comment", first, "--body", "note to self"], root: root)
  _ = try run(["link", first, second, "--kind", "related"], root: root)

  let shown = try run(["show", first], root: root)
  #expect(shown.contains("attachment.txt"))
  #expect(shown.contains("note to self"))
  #expect(shown.contains(second))
}

@Test func cliNotebookLifecycle() throws {
  let root = try makeTempRoot()
  let created = try run(
    ["notebook", "create", "--title", "Lifecycle", "--kind", "notebook-kind:user-memo"],
    root: root
  )
  let notebookId = try #require(
    created.split(separator: " ").first { $0.hasPrefix("notebook-") }.map(String.init)?
      .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
  )

  _ = try run(["notebook", "progress", notebookId, "done"], root: root)
  let shown = try run(["notebook", "show", notebookId], root: root)
  #expect(shown.contains("Lifecycle"))
  #expect(shown.contains("[done]"))
  #expect(shown.contains("notebook-kind:user-memo"))

  _ = try run(["notebook", "delete", notebookId], root: root)
  #expect(!(try run(["notebook", "list"], root: root)).contains(notebookId))
}

@Test func cliFileExportWritesContent() throws {
  let root = try makeTempRoot()
  let id = try noteId(fromJSON: try run(
    ["add", "--body", "# Files\nBody.", "--output", "json"],
    root: root
  ))
  let sourcePath = (root as NSString).appendingPathComponent("source.bin")
  try Data("binary-content".utf8).write(to: URL(fileURLWithPath: sourcePath))
  let attached = try run(["attach", id, sourcePath], root: root)
  let fileId = try #require(
    attached.split(separator: " ").first { $0.hasPrefix("file-") }.map(String.init)
  )

  let exportPath = (root as NSString).appendingPathComponent("export.bin")
  _ = try run(["file", fileId, "--out", exportPath], root: root)
  #expect(try Data(contentsOf: URL(fileURLWithPath: exportPath)) == Data("binary-content".utf8))
}

@Test func cliRejectsConflictingBodySources() throws {
  let root = try makeTempRoot()
  do {
    _ = try run(["add", "--body", "a", "--body-file", "/nonexistent"], root: root)
    Issue.record("Expected an invalid usage error")
  } catch AppCommand.Error.invalidUsage(let message) {
    #expect(message.contains("only one of"))
  }
}
