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

private func noteId(fromJSON output: String) throws -> NoteID {
  let object = try JSONValue(parsing: output)
  return NoteID(try #require(object["noteId"]?.asString))
}

@Test func cliNoteRootResolutionPrecedence() throws {
  let command = AppCommand(arguments: [], environment: ["KAIBA_NOTE_ROOT": "/env/root"])
  #expect(command.resolveNoteRoot(override: "/cli/root") == "/cli/root")
  #expect(command.resolveNoteRoot(override: nil) == "/env/root")
  let fallback = AppCommand(arguments: [], environment: [:])
  #expect(fallback.resolveNoteRoot(override: nil).hasSuffix("/.kaiba"))
}

@Test func cliConfigPathResolutionIsKaibaSpecific() {
  let command = AppCommand(arguments: [], environment: ["KAIBA_CONFIG_PATH": "/env/kaiba.json"])
  #expect(command.resolveConfigPath(override: "/cli/kaiba.json") == "/cli/kaiba.json")
  #expect(command.resolveConfigPath(override: nil) == "/env/kaiba.json")
  let fallback = AppCommand(arguments: [], environment: [:])
  #expect(fallback.resolveConfigPath(override: nil).hasSuffix("/.config/kaiba/config.json"))
}

@Test func localDatabasePathIsInsideKaibaNoteRoot() {
  #expect(
    SQLiteNoteDatabaseDriver.defaultDatabasePath(noteRoot: "/data/kaiba")
      == "/data/kaiba/note-store.sqlite"
  )
}

@Test func configLoaderDefaultsToSQLiteAndDecodesTursoWithoutSecrets() throws {
  let missing = try makeTempRoot().appending("/missing.json")
  #expect(try KaibaConfigurationLoader.load(at: missing, required: false) == KaibaConfiguration())

  let path = try makeTempRoot().appending("/kaiba.json")
  let configuration = KaibaConfiguration(database: .turso(TursoHTTPConfiguration(
    url: "libsql://kaiba-example.turso.io",
    authTokenEnvironmentVariable: "KAIBA_TURSO_TOKEN"
  )))
  let data = try JSONEncoder().encode(configuration)
  try data.write(to: URL(fileURLWithPath: path))
  #expect(try KaibaConfigurationLoader.load(at: path, required: true) == configuration)
  #expect(!(String(data: data, encoding: .utf8) ?? "").contains("secret-token"))
}

@Test func configBuildsEnvironmentBackedS3Profile() throws {
  let configuration = KaibaConfiguration(storageProfiles: [KaibaS3ProfileConfiguration(
    name: "gateway",
    endpoint: "http://127.0.0.1:8443",
    region: "us-east-1",
    bucket: "kaiba-files",
    accessKeyIdEnvironmentVariable: "KAIBA_S3_ACCESS",
    secretAccessKeyEnvironmentVariable: "KAIBA_S3_SECRET",
    keyPrefix: "attachments"
  )])
  let profiles = try KaibaConfigurationLoader.makeS3Profiles(
    configuration: configuration,
    environment: ["KAIBA_S3_ACCESS": "client", "KAIBA_S3_SECRET": "secret"]
  )
  let profile = try #require(profiles.first)
  #expect(profile.name == "gateway")
  #expect(profile.bucket == "kaiba-files")
  #expect(profile.keyPrefix == "attachments")
  #expect(profile.accessKeyId == "client")
  #expect(profile.secretAccessKey == "secret")
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

  let shown = try run(["show", id.rawValue], root: root)
  #expect(shown.contains("# Round Trip"))
  #expect(shown.contains("#idea"))

  let listed = try run(["list"], root: root)
  #expect(listed.contains(id.rawValue))
  #expect(listed.contains("Round Trip"))
}

@Test func cliEditAppendsAndSearchFinds() throws {
  let root = try makeTempRoot()
  let id = try noteId(fromJSON: try run(
    ["add", "--body", "# Searchable\nOriginal content.", "--output", "json"],
    root: root
  ))
  _ = try run(["edit", id.rawValue, "--body", "Appended trailer.", "--append"], root: root)

  let shown = try run(["show", id.rawValue], root: root)
  #expect(shown.contains("Original content."))
  #expect(shown.contains("Appended trailer."))

  let found = try run(["search", "Appended"], root: root)
  #expect(found.contains(id.rawValue))
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
  #expect(filtered.contains(id.rawValue))

  _ = try run(["tag", id.rawValue, "--remove", "child-topic"], root: root)
  let afterRemoval = try run(["list", "--tag", "parent-topic"], root: root)
  #expect(!afterRemoval.contains(id.rawValue))
}

@Test func cliReadOnlyBlocksEditAndDelete() throws {
  let root = try makeTempRoot()
  let id = try noteId(fromJSON: try run(
    ["add", "--body", "# Locked\nBody.", "--output", "json"],
    root: root
  ))
  _ = try run(["readonly", id.rawValue, "--on"], root: root)

  #expect(throws: NoteServiceError.readOnly(id.rawValue)) {
    _ = try run(["edit", id.rawValue, "--body", "x"], root: root)
  }
  #expect(throws: NoteServiceError.readOnly(id.rawValue)) {
    _ = try run(["delete", id.rawValue], root: root)
  }

  _ = try run(["readonly", id.rawValue, "--off"], root: root)
  _ = try run(["delete", id.rawValue], root: root)
  #expect(!(try run(["list"], root: root)).contains(id.rawValue))
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
  _ = try run(["attach", first.rawValue, attachmentPath], root: root)
  _ = try run(["comment", first.rawValue, "--body", "note to self"], root: root)
  _ = try run(["link", first.rawValue, second.rawValue, "--kind", "related"], root: root)

  let shown = try run(["show", first.rawValue], root: root)
  #expect(shown.contains("attachment.txt"))
  #expect(shown.contains("note to self"))
  #expect(shown.contains(second.rawValue))
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

  let shown = try run(["notebook", "show", notebookId], root: root)
  #expect(shown.contains("Lifecycle"))
  #expect(shown.contains("notebook-kind:user-memo"))

  _ = try run(["notebook", "delete", notebookId], root: root)
  #expect(!(try run(["notebook", "list"], root: root)).contains(notebookId))
}

@Test func cliNotebookListTagFilterResolvesNamesThroughTheHierarchy() throws {
  let root = try makeTempRoot()
  let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root))
  let work = try service.defineTag(name: "Work", classId: TagClassID("folder"))
  let launch = try service.defineTag(
    name: "Launch",
    classId: TagClassID("folder"),
    parentTagId: work.tagId
  )
  let archive = try service.defineTag(name: "Archive", classId: TagClassID("folder"))
  _ = try service.defineTag(name: "Shared", classId: TagClassID("folder"), parentTagId: work.tagId)
  _ = try service.defineTag(name: "Shared", classId: TagClassID("folder"), parentTagId: archive.tagId)
  let launchPlan = try service.createNotebook(title: "Launch plan")
  try service.applyNotebookTags(
    notebookId: launchPlan.notebookId,
    tags: [launch.name],
    provenance: .human
  )
  let archived = try service.createNotebook(title: "Archived")
  try service.applyNotebookTags(
    notebookId: archived.notebookId,
    tags: [archive.name],
    provenance: .human
  )
  let untagged = try service.createNotebook(title: "Untagged")

  // A folder name reaches its descendants.
  let filtered = try run(["notebook", "list", "--tag", "Work"], root: root)
  #expect(filtered.contains(launchPlan.notebookId.rawValue))
  #expect(!filtered.contains(archived.notebookId.rawValue))
  #expect(!filtered.contains(untagged.notebookId.rawValue))

  // Repeated --tag values form one OR group.
  let either = try run(["notebook", "list", "--tag", "Launch", "--tag", "Archive"], root: root)
  #expect(either.contains(launchPlan.notebookId.rawValue))
  #expect(either.contains(archived.notebookId.rawValue))
  #expect(!either.contains(untagged.notebookId.rawValue))

  // An unknown name matches nothing, in both output modes.
  #expect(try run(["notebook", "list", "--tag", "missing"], root: root) == "No notebooks.")
  let missingJSON = try run(["notebook", "list", "--tag", "missing", "--output", "json"], root: root)
  #expect(try JSONValue(parsing: missingJSON) == .array([]))

  // An ambiguous name is rejected rather than resolved to either folder.
  do {
    _ = try run(["notebook", "list", "--tag", "Shared"], root: root)
    Issue.record("expected the ambiguous tag name to be rejected")
  } catch let error as NoteServiceError {
    #expect(error == .invalidInput("tag name is ambiguous: Shared"))
  }
}

@Test func cliFileExportWritesContent() throws {
  let root = try makeTempRoot()
  let id = try noteId(fromJSON: try run(
    ["add", "--body", "# Files\nBody.", "--output", "json"],
    root: root
  ))
  let sourcePath = (root as NSString).appendingPathComponent("source.bin")
  try Data("binary-content".utf8).write(to: URL(fileURLWithPath: sourcePath))
  let attached = try run(["attach", id.rawValue, sourcePath], root: root)
  let fileId = try #require(
    attached.split(separator: " ").first { $0.hasPrefix("file-") }.map(String.init)
  )

  let exportPath = (root as NSString).appendingPathComponent("export.bin")
  _ = try run(["file", fileId, "--out", exportPath], root: root)
  #expect(try Data(contentsOf: URL(fileURLWithPath: exportPath)) == Data("binary-content".utf8))
}

@Test func cliClientIssueListRevokeRoundTrip() throws {
  let root = try makeTempRoot()
  let issued = try run(["client", "issue", "--name", "test-consumer", "--output", "json"], root: root)
  let object = try JSONValue(parsing: issued)
  let apiKey = try #require(object["apiKey"]?.asString)
  let clientId = try #require(object["clientId"]?.asString)
  #expect(apiKey.count >= 40)

  let listed = try run(["client", "list"], root: root)
  #expect(listed.contains(clientId))
  #expect(listed.contains("test-consumer"))
  #expect(!listed.contains(apiKey))

  let service = try AppCommand(arguments: [], environment: [:]).makeService(root: root)
  #expect(try service.authenticateAPIClient(bearerToken: apiKey)?.clientId == APIClientID(clientId))

  _ = try run(["client", "revoke", clientId], root: root)
  #expect(try service.authenticateAPIClient(bearerToken: apiKey) == nil)
  #expect(!(try run(["client", "list"], root: root)).contains(clientId))
  #expect((try run(["client", "list", "--all"], root: root)).contains("[revoked"))
}

@Test func cliUserAdminGrantRevokeRoundTrip() throws {
  let root = try makeTempRoot()

  // The seeded default user is the admin every store starts with.
  #expect((try run(["user", "list"], root: root)).contains("[admin]"))

  let added = try run(
    ["user", "add", "--email", "alice@example.com", "--name", "Alice", "--output", "json"],
    root: root
  )
  let alice = try JSONValue(parsing: added)
  let aliceId = try #require(alice["userId"]?.asString)
  #expect(alice["isAdmin"] == .bool(false))

  let granted = try run(["user", "grant-admin", aliceId, "--output", "json"], root: root)
  #expect(try JSONValue(parsing: granted)["isAdmin"] == .bool(true))
  #expect((try run(["user", "list"], root: root)).contains("\(aliceId)  Alice"))

  let revoked = try run(["user", "revoke-admin", aliceId, "--output", "json"], root: root)
  #expect(try JSONValue(parsing: revoked)["isAdmin"] == .bool(false))

  // The store keeps at least one admin: the seeded one cannot step down while
  // it is the only one left.
  #expect(throws: NoteServiceError.invalidInput(
    "the last admin cannot be demoted; promote another user first"
  )) {
    _ = try run(["user", "revoke-admin", NoteStoreSchema.defaultUserId.rawValue], root: root)
  }
}

@Test func cliJWTScopedNonAdminCannotManageAccounts() throws {
  let root = try makeTempRoot()
  let service = try AppCommand(arguments: [], environment: [:]).makeService(root: root)
  let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
  let bob = try service.createUser(email: "bob@example.com", displayName: "Bob")
  let ordinaryToken = try service.issueAuthToken(userId: alice.userId)
  let agentToken = try service.issueAgentToken(userId: alice.userId, ttlSeconds: 300).token

  for token in [ordinaryToken, agentToken] {
    do {
      let issued = try JSONValue(parsing: run([
        "--jwt", token,
        "auth", "token", "issue", "--user", NoteStoreSchema.defaultUserId.rawValue, "--output", "json"
      ], root: root))
      Issue.record("A scoped JWT minted an administrator token")
      let administratorToken = try #require(issued["token"]?.asString)
      _ = try run([
        "--jwt", administratorToken,
        "user", "add", "--email", "escalated@example.com", "--admin"
      ], root: root)
      Issue.record("A JWT-minted administrator token created an administrator")
    } catch let error as NoteServiceError {
      #expect(error == .notFound("control-plane resource not found"))
    }
    #expect(throws: NoteServiceError.notFound("control-plane resource not found")) {
      _ = try run([
        "--jwt", token,
        "user", "add", "--email", "attacker@example.com", "--admin"
      ], root: root)
    }
    #expect(throws: NoteServiceError.notFound("control-plane resource not found")) {
      _ = try run(["--jwt", token, "user", "grant-admin", bob.userId.rawValue], root: root)
    }
    #expect(throws: NoteServiceError.notFound("control-plane resource not found")) {
      _ = try run(["--jwt", token, "user", "disable", bob.userId.rawValue], root: root)
    }
  }

  #expect(try service.user(email: "attacker@example.com") == nil)
  #expect(try service.user(id: bob.userId)?.isAdmin == false)
  #expect(try service.user(id: bob.userId)?.isEnabled == true)
}

@Test func cliJWTScopedNonAdminCannotManageAPIClientsOrForeignLibraries() throws {
  let root = try makeTempRoot()
  let service = try AppCommand(arguments: [], environment: [:]).makeService(root: root)
  let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
  let ordinaryToken = try service.issueAuthToken(userId: alice.userId)
  let agentToken = try service.issueAgentToken(userId: alice.userId, ttlSeconds: 300).token
  _ = try service.createLibrary(name: "secret", authRequired: true)

  for token in [ordinaryToken, agentToken] {
    #expect(throws: NoteServiceError.notFound("control-plane resource not found")) {
      _ = try run([
        "--jwt", token, "client", "issue", "--name", "escalation",
        "--user", NoteStoreSchema.defaultUserId.rawValue
      ], root: root)
    }
    #expect(throws: NoteServiceError.notFound("control-plane resource not found")) {
      _ = try run(["--jwt", token, "client", "list"], root: root)
    }
    #expect(throws: NoteServiceError.notFound("library not found: secret")) {
      _ = try run([
        "--jwt", token, "library", "grant", "secret", "--user", alice.userId.rawValue, "--role", "owner"
      ], root: root)
    }
    #expect(throws: NoteServiceError.notFound("library not found: secret")) {
      _ = try run(["--jwt", token, "library", "update", "secret", "--auth", "none"], root: root)
    }
  }
}

@Test func cliJWTScopedNonAdminCannotMoveIntoAnUnreachableLibrary() throws {
  let root = try makeTempRoot()
  let service = try AppCommand(arguments: [], environment: [:]).makeService(root: root)
  let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
  let notebook = try service.scoped(to: alice.userId).createNotebook(title: "Alice notebook")
  let token = try service.issueAuthToken(userId: alice.userId)
  _ = try service.createLibrary(name: "hidden-cli-move-destination", authRequired: true)

  for destination in ["hidden-cli-move-destination", "missing-cli-move-destination"] {
    #expect(throws: NoteServiceError.notFound("library not found")) {
      _ = try run([
        "--jwt", token,
        "library", "move", notebook.notebookId.rawValue, "--to", destination
      ], root: root)
    }
  }

  #expect(try service.getNotebook(notebook.notebookId).libraryId == NoteStoreSchema.defaultLibraryId)
  #expect(try service.scoped(to: alice.userId).getNotebook(notebook.notebookId).libraryId
    == NoteStoreSchema.defaultLibraryId)
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

@Test func cliDbCheckAndOptimizeRoundTrip() throws {
  let root = try makeTempRoot()
  _ = try run(["add", "--body", "# Maintained\nchecked body"], root: root)

  let checked = try run(["db", "check"], root: root)
  #expect(checked.contains("integrity ok"))
  #expect(checked.contains("foreign-keys ok"))
  #expect(checked.contains("search-index ok"))
  #expect(checked.contains("store is healthy"))

  let checkedJSON = try JSONValue(parsing: try run(["db", "check", "--output", "json"], root: root))
  #expect(checkedJSON["healthy"] == .bool(true))
  #expect(checkedJSON["schemaVersion"] == .integer(Int64(NoteStoreSchema.currentVersion)))

  let optimized = try run(["db", "optimize", "--vacuum"], root: root)
  #expect(optimized.contains("size "))
  #expect(!optimized.contains("run with --vacuum"))

  do {
    _ = try run(["db", "shrink"], root: root)
    Issue.record("Expected an invalid usage error")
  } catch AppCommand.Error.invalidUsage(let message) {
    #expect(message.contains("unknown db subcommand"))
  }
}
