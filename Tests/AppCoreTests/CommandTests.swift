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

// MARK: - Tag entity page CLI
//
// `design-docs/specs/note-capture-and-entity-pages.md` E7. These drive the
// real `AppCommand.run()` over a temporary note root, so argument parsing,
// name-or-id resolution and rendering are all exercised end to end.

private func makeCommandTempRoot(function: String = #function) throws -> String {
  let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("AppCoreTests-command", isDirectory: true)
    .appendingPathComponent("\(function)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root.path
}

private func runCommand(_ arguments: [String], root: String) throws -> String {
  try AppCommand(arguments: ["--note-root", root] + arguments, environment: [:]).run()
}

private func createdNoteId(_ output: String) throws -> String {
  let object = try JSONValue(parsing: output)
  return try #require(object["noteId"]?.asString)
}

@Test func commandUsageDocumentsTheTagEntityPageAndPromotion() throws {
  let usage = try AppCommand(arguments: ["--help"]).run()
  #expect(usage.contains("tag        <tag-name-or-id> [--output json|text]"))
  #expect(usage.contains("tag promote   --tag <name-or-id> --note <note-id>"))
  #expect(usage.contains("tag unpromote --tag <name-or-id>"))
}

@Test func commandTagShowsCanonicalNoteAndCoOccurringTags() throws {
  let root = try makeCommandTempRoot()
  let described = try createdNoteId(try runCommand(
    ["add", "--title", "What Swift is", "--body", "# Swift\nA language.",
     "--tag", "swift", "--tag", "language", "--output", "json"],
    root: root
  ))
  _ = try runCommand(
    ["add", "--body", "# Second\nMore.", "--tag", "swift", "--tag", "language",
     "--output", "json"],
    root: root
  )

  let unbound = try runCommand(["tag", "swift"], root: root)
  #expect(unbound.contains("Tag swift ("))
  #expect(unbound.contains("notes=2"))
  #expect(unbound.contains("canonical note: (none)"))
  #expect(unbound.contains("#language (2)"))

  let promoted = try runCommand(
    ["tag", "promote", "--tag", "swift", "--note", described],
    root: root
  )
  #expect(promoted.contains("Promoted \(described) as the canonical note for swift ("))

  let bound = try runCommand(["tag", "swift"], root: root)
  #expect(bound.contains("canonical note: \(described)  What Swift is"))
}

@Test func commandTagShowAcceptsATagIdAndRendersJSON() throws {
  let root = try makeCommandTempRoot()
  let note = try createdNoteId(try runCommand(
    ["add", "--title", "Ruby", "--body", "# Ruby\nA language.", "--tag", "ruby",
     "--output", "json"],
    root: root
  ))
  let listed = try runCommand(["tags"], root: root)
  #expect(listed.contains("ruby"))

  // Resolve the id the way an operator would, then address the tag by it.
  let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root))
  let tagId = try #require(try service.listTags().first { $0.name == "ruby" }).tagId
  _ = try runCommand(["tag", "promote", "--tag", tagId.rawValue, "--note", note], root: root)

  let json = try JSONValue(parsing: try runCommand(
    ["tag", tagId.rawValue, "--output", "json"],
    root: root
  ))
  #expect(json["tag"]?["name"]?.asString == "ruby")
  #expect(json["noteCount"]?.asInt == 1)
  #expect(json["canonicalNote"]?["noteId"]?.asString == note)
  #expect(json["coOccurringTags"]?.asArray?.isEmpty == true)
  // A classless tag drops the member rather than writing null.
  #expect(json["tagClass"] == nil)

  // `topic` is one of the store's seeded system classes.
  _ = try runCommand(["tag-define", "elixir", "--class", "topic"], root: root)
  let classed = try JSONValue(parsing: try runCommand(
    ["tag", "elixir", "--output", "json"],
    root: root
  ))
  #expect(classed["tagClass"]?["classId"]?.asString == "topic")
  #expect(classed["tagClass"]?["label"]?.asString == "Topic")
  #expect(classed["tagClass"]?["isSystem"]?.asBool == true)
  #expect(classed["noteCount"]?.asInt == 0)
  #expect(classed["canonicalNote"] == nil)
}

@Test func commandTagUnpromoteClearsTheBindingAndIsANoOpWhenUnbound() throws {
  let root = try makeCommandTempRoot()
  let note = try createdNoteId(try runCommand(
    ["add", "--title", "Kaiba", "--body", "# Kaiba\nNotes.", "--tag", "kaiba",
     "--output", "json"],
    root: root
  ))

  let noOp = try runCommand(["tag", "unpromote", "--tag", "kaiba"], root: root)
  #expect(noOp.contains("had no canonical note"))

  _ = try runCommand(["tag", "promote", "--tag", "kaiba", "--note", note], root: root)
  let cleared = try runCommand(["tag", "unpromote", "--tag", "kaiba"], root: root)
  #expect(cleared.contains("Cleared the canonical note \(note) for kaiba ("))
  #expect(try runCommand(["tag", "kaiba"], root: root).contains("canonical note: (none)"))
}

@Test func commandTagStillAssignsAndRemovesTagsOnANote() throws {
  let root = try makeCommandTempRoot()
  let note = try createdNoteId(try runCommand(
    ["add", "--body", "# Plain\nBody.", "--output", "json"],
    root: root
  ))

  let added = try runCommand(["tag", note, "--add", "idea"], root: root)
  #expect(added.contains("Tags on \(note): #idea"))

  let removed = try runCommand(["tag", note, "--remove", "idea"], root: root)
  #expect(removed.contains("Tags on \(note): (none)"))
}

@Test func commandTagRefusesAnUnknownTagReference() throws {
  let root = try makeCommandTempRoot()
  _ = try runCommand(["add", "--body", "# Any\nBody.", "--output", "json"], root: root)
  do {
    _ = try runCommand(["tag", "no-such-tag"], root: root)
    Issue.record("Expected an unknown tag to be refused")
  } catch AppCommand.Error.invalidUsage(let message) {
    #expect(message == "tag not found: no-such-tag")
  }
}

@Test func commandTagRefusesAnAmbiguousTagNameWithTheCandidateIds() throws {
  let root = try makeCommandTempRoot()
  _ = try runCommand(["tag-define", "left", "--class", "folder"], root: root)
  _ = try runCommand(["tag-define", "right", "--class", "folder"], root: root)
  _ = try runCommand(
    ["tag-define", "shared", "--class", "folder", "--parent", "left"],
    root: root
  )
  _ = try runCommand(
    ["tag-define", "shared", "--class", "folder", "--parent", "right"],
    root: root
  )

  do {
    _ = try runCommand(["tag", "shared"], root: root)
    Issue.record("Expected an ambiguous tag name to be refused")
  } catch AppCommand.Error.invalidUsage(let message) {
    #expect(message.hasPrefix("tag name is ambiguous: shared; pass one of these ids instead: "))
  }
}

@Test func commandTagPromoteSurfacesTheServiceRefusalVerbatim() throws {
  let root = try makeCommandTempRoot()
  let note = try createdNoteId(try runCommand(
    ["add", "--body", "# Body\nText.", "--output", "json"],
    root: root
  ))
  _ = try runCommand(["tag-define", "archive", "--class", "folder"], root: root)

  // A folder-class tag is not a subject, and the refusal is the service's own
  // message reaching the operator unaltered: the command layer re-derives no
  // rule of its own (E2, and TASK-003's R1 carried forward).
  #expect(throws: NoteServiceError.invalidInput(
    "folder tags cannot carry a canonical note: archive"
  )) {
    _ = try runCommand(["tag", "promote", "--tag", "archive", "--note", note], root: root)
  }

  _ = try runCommand(["tag-define", "topic"], root: root)
  #expect(throws: NoteServiceError.notFound("note not found: note-does-not-exist")) {
    _ = try runCommand(
      ["tag", "promote", "--tag", "topic", "--note", "note-does-not-exist"],
      root: root
    )
  }
}

@Test func commandTagPromoteAndUnpromoteRequireTheirOptions() throws {
  let root = try makeCommandTempRoot()
  #expect(throws: AppCommand.Error.invalidUsage(
    "tag promote requires --tag <name-or-id> and --note <note-id>"
  )) {
    _ = try runCommand(["tag", "promote", "--tag", "solo"], root: root)
  }
  #expect(throws: AppCommand.Error.invalidUsage(
    "tag unpromote requires --tag <name-or-id>"
  )) {
    _ = try runCommand(["tag", "unpromote"], root: root)
  }
}

@Test func commandTagWithoutAnArgumentExplainsBothShapes() throws {
  let root = try makeCommandTempRoot()
  do {
    _ = try runCommand(["tag"], root: root)
    Issue.record("Expected bare `tag` to be refused")
  } catch AppCommand.Error.invalidUsage(let message) {
    #expect(message.contains("--add/--remove"))
    #expect(message.contains("<tag-name-or-id>"))
  }
}
