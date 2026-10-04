import Foundation
import XCTest
@testable import AppCore

final class SearchEngineCommandTests: NoteTestCase {
  func testParseRequiresKnownSubcommandAndAcceptsJSONOutput() throws {
    XCTAssertThrowsError(try SearchEngineCommand.parse(
      arguments: [], noteRoot: "/tmp/notes", configuration: KaibaConfiguration()
    )) { error in
      XCTAssertEqual(String(describing: error), "search-engine requires a subcommand: status|sync|reindex")
    }
    XCTAssertThrowsError(try SearchEngineCommand.parse(
      arguments: ["bogus"], noteRoot: "/tmp/notes", configuration: KaibaConfiguration()
    ))
    let options = try SearchEngineCommand.parse(
      arguments: ["status", "--output", "json"],
      noteRoot: "/tmp/notes",
      configuration: KaibaConfiguration()
    )
    XCTAssertTrue(options.json)
    XCTAssertThrowsError(try SearchEngineCommand.parse(
      arguments: ["sync", "--extra"], noteRoot: "/tmp/notes", configuration: KaibaConfiguration()
    )) { error in
      XCTAssertEqual(String(describing: error), "unknown search-engine argument: --extra")
    }
  }

  func testNoEngineAndInvalidConfigurationExitTwo() async throws {
    let noEngineOptions = try options(arguments: ["status"], function: #function)
    let noEngine = await SearchEngineCommand.run(noEngineOptions, environment: [:], engine: nil)
    XCTAssertEqual(noEngine.1, 2)
    XCTAssertTrue(noEngine.0.contains("search engine is not configured"))

    var invalidConfiguration = KaibaConfiguration()
    invalidConfiguration.searchEngine = KaibaSearchEngineConfiguration(
      kind: "opensearch", url: "http://127.0.0.1:9200"
    )
    let invalidOptions = SearchEngineCommand.Options(
      noteRoot: noteRoot(function: #function),
      configuration: invalidConfiguration,
      subcommand: .status,
      json: false
    )
    let invalid = await SearchEngineCommand.run(invalidOptions, environment: [:])
    XCTAssertEqual(invalid.1, 2)
    XCTAssertTrue(invalid.0.contains("searchEngine.kind"))
    XCTAssertFalse(invalid.0.contains("http"))
  }

  func testStatusResolvesStoreSettingsAndInvalidStoreSettingsExitTwoWithFieldOnly() async throws {
    let root = noteRoot(function: #function)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root))
    _ = try await service.updateSearchEngineSettings(SearchEngineSettingsInput(
      kind: "elasticsearch", url: "http://127.0.0.1:9200"
    ))
    let options = SearchEngineCommand.Options(
      noteRoot: root, configuration: KaibaConfiguration(), subcommand: .status, json: false
    )
    let result = await SearchEngineCommand.run(options, environment: [:])
    XCTAssertEqual(result.1, 0)
    XCTAssertTrue(result.0.contains("kind elasticsearch"))

    try service.setAppSetting(
      key: NoteService.searchEngineSettingsKey,
      valueJSON: #"{"kind":"elasticsearch","url":"bad target"}"#,
      allowReserved: true
    )
    let invalid = await SearchEngineCommand.run(options, environment: [:])
    XCTAssertEqual(invalid.1, 2)
    XCTAssertEqual(invalid.0, "Error: invalid search engine settings: searchEngine.url")
    XCTAssertFalse(invalid.0.contains("bad target"))
  }

  func testStatusReportsKindFromEnabledConfigSection() async throws {
    let configuration = KaibaConfiguration(searchEngine: KaibaSearchEngineConfiguration(
      kind: "elasticsearch", url: "http://127.0.0.1:9200"
    ))
    let options = SearchEngineCommand.Options(
      noteRoot: noteRoot(function: #function), configuration: configuration, subcommand: .status, json: false
    )
    let result = await SearchEngineCommand.run(options, environment: [:])
    XCTAssertEqual(result.1, 0)
    XCTAssertTrue(result.0.contains("kind elasticsearch"))
  }

  func testSyncIsIdempotentAndReindexEnqueuesEveryNote() async throws {
    let syncOptions = try options(arguments: ["sync"], function: #function)
    let service = try makeCommandService(function: #function)
    _ = try service.createNote(bodyMarkdown: "first note")
    _ = try service.createNote(bodyMarkdown: "second note")
    let engine = FakeSearchEngine()

    let first = await SearchEngineCommand.run(syncOptions, environment: [:], engine: engine)
    XCTAssertEqual(first.1, 0)
    XCTAssertTrue(first.0.contains("pushed 2"))
    XCTAssertEqual(engine.documents.count, 2)
    XCTAssertEqual(engine.ensureIndexCount, 1)

    let second = await SearchEngineCommand.run(syncOptions, environment: [:], engine: engine)
    XCTAssertEqual(second.1, 0)
    XCTAssertTrue(second.0.contains("pushed 0"))
    XCTAssertTrue(second.0.contains("activated false"))

    let reindexOptions = try options(arguments: ["reindex"], function: #function)
    let reindex = await SearchEngineCommand.run(reindexOptions, environment: [:], engine: engine)
    XCTAssertEqual(reindex.1, 0)
    XCTAssertTrue(reindex.0.contains("enqueued 2"))
    XCTAssertTrue(reindex.0.contains("pushed 2"))
  }

  func testSyncReportsEngineAndPerNoteFailuresAsOperationalErrors() async throws {
    let options = try options(arguments: ["sync"], function: #function)
    let engineFailure = FakeSearchEngine()
    engineFailure.failure = .unavailable("search engine unavailable")
    let ensureFailure = await SearchEngineCommand.run(options, environment: [:], engine: engineFailure)
    XCTAssertEqual(ensureFailure.1, 1)
    XCTAssertTrue(ensureFailure.0.contains("search engine unavailable"))

    let service = try makeCommandService(function: #function)
    let note = try service.createNote(bodyMarkdown: "will fail")
    let applyFailure = FakeSearchEngine()
    applyFailure.failingNoteIds = [note.noteId]
    let failed = await SearchEngineCommand.run(options, environment: [:], engine: applyFailure)
    XCTAssertEqual(failed.1, 1)
    XCTAssertTrue(failed.0.contains("failed 1"))
  }

  func testUnavailableStatusSucceedsAndJSONOmitsURL() async throws {
    var configuration = KaibaConfiguration()
    configuration.searchEngine = KaibaSearchEngineConfiguration(
      kind: "elasticsearch", url: "http://127.0.0.1:9200", apiKeyEnvironmentVariable: "SEARCH_KEY"
    )
    let options = SearchEngineCommand.Options(
      noteRoot: noteRoot(function: #function), configuration: configuration, subcommand: .status, json: true
    )
    let engine = FakeSearchEngine()
    engine.failure = .unavailable("offline")

    let result = await SearchEngineCommand.run(
      options,
      environment: ["SEARCH_KEY": "super-secret"],
      engine: engine
    )

    XCTAssertEqual(result.1, 0)
    XCTAssertFalse(result.0.contains("http"))
    XCTAssertFalse(result.0.contains("super-secret"))
    let json = try JSONValue(parsing: result.0)
    XCTAssertEqual(json["available"]?.asBool, false)
    XCTAssertNotNil(json["indexIdentity"])
    XCTAssertNotNil(json["pending"])
    XCTAssertNotNil(json["failing"])
    XCTAssertNotNil(json["due"])
  }

  func testUsageDocumentsSearchEngineCommands() throws {
    let usage = try AppCommand(arguments: ["--help"]).run()
    XCTAssertTrue(usage.contains("search-engine status [--output json|text]"))
    XCTAssertTrue(usage.contains("search-engine sync [--output json|text]"))
    XCTAssertTrue(usage.contains("search-engine reindex [--output json|text]"))
  }

  private func options(arguments: [String], function: String) throws -> SearchEngineCommand.Options {
    try SearchEngineCommand.parse(
      arguments: arguments,
      noteRoot: noteRoot(function: function),
      configuration: KaibaConfiguration(searchEngine: KaibaSearchEngineConfiguration(
        kind: "elasticsearch", url: "http://127.0.0.1:9200"
      ))
    )
  }

  private func noteRoot(function: String) -> String {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/AppCoreTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .path
  }

  private func makeCommandService(function: String) throws -> NoteService {
    let root = noteRoot(function: function)
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    return try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root))
  }
}
