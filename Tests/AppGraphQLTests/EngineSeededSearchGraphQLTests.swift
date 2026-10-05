import Foundation

import AppCore
import AppGraphQL
import XCTest

private final class SeededSearchRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func record() { lock.withLock { count += 1 } }
  var searchCount: Int { lock.withLock { count } }
}

private struct SeededSearchEngine: SearchEngine {
  var hits: [SearchEngineHit] = []
  var failure: SearchEngineError?
  var recorder: SeededSearchRecorder
  var indexIdentity: String { "graphql-seeded-fixture" }

  func health() async throws -> SearchEngineHealth { .init(isAvailable: true, detail: "ok") }
  func ensureIndex() async throws {}
  func apply(_ operations: [SearchIndexOperation]) async throws -> [SearchIndexOperationResult] { [] }
  func search(_ query: SearchEngineQuery) async throws -> [SearchEngineHit] {
    recorder.record()
    if let failure { throw failure }
    return hits
  }
  func searchPage(_ query: SearchEngineQuery) async throws -> SearchEngineSearchPage {
    SearchEngineSearchPage(hits: try await search(query), facets: nil)
  }
  func relatedNotes(_ query: SearchEngineRelatedQuery) async throws -> [SearchEngineHit] { hits }
}

final class EngineSeededSearchGraphQLTests: XCTestCase {
  func testIncludeLinkedUsesEngineAndReturnsProvenance() async throws {
    let graphService = try makeService()
    let note = try graphService.service.createNote(bodyMarkdown: "# Engine result\n\nunrelated content")
    let recorder = SeededSearchRecorder()
    graphService.service.searchEngine = SeededSearchEngine(
      hits: [.init(noteId: note.noteId, score: 3, highlight: nil, reasons: [.init(kind: .tagMatch, tagNames: ["topic:x"])])],
      recorder: recorder
    )
    let response = await run(graphService, """
    query { searchNotes(query: "zebra capybara", includeLinked: true) {
      result { accepted status }
      value { note { noteId } provenance { sources reasons } }
    } }
    """)
    XCTAssertEqual(recorder.searchCount, 1)
    let result = try XCTUnwrap(array(response, ["searchNotes", "value"]).first)
    XCTAssertEqual(try string(result, ["note", "noteId"]), note.noteId.rawValue)
    XCTAssertEqual(try stringArray(result, ["provenance", "sources"]), ["search-engine"])
    XCTAssertEqual(try stringArray(result, ["provenance", "reasons"]), ["tag-match"])
  }

  func testSearchWithoutIncludeLinkedSkipsEngineAndKeepsFtsResults() async throws {
    let graphService = try makeService()
    let note = try graphService.service.createNote(bodyMarkdown: "# FTS result\n\nneedle text")
    let query = "query { searchNotes(query: \"needle\") { value { note { noteId } snippet rank } } }"
    let withoutEngine = await run(graphService, query)
    let recorder = SeededSearchRecorder()
    graphService.service.searchEngine = SeededSearchEngine(
      hits: [.init(noteId: note.noteId, score: 100, highlight: nil)],
      recorder: recorder
    )
    let withEngine = await run(graphService, query)
    XCTAssertEqual(withEngine, withoutEngine)
    XCTAssertEqual(recorder.searchCount, 0)
  }

  func testFTSProvenanceIsDerivedWhenSelected() async throws {
    let graphService = try makeService()
    _ = try graphService.service.createNote(bodyMarkdown: "# FTS result\n\nneedle text")
    let response = await run(graphService, """
    query { searchNotes(query: "needle") {
      value { isLinkedNeighbor provenance { sources reasons } }
    } }
    """)
    let result = try XCTUnwrap(array(response, ["searchNotes", "value"]).first)
    XCTAssertEqual(try bool(result, ["isLinkedNeighbor"]), false)
    XCTAssertEqual(try stringArray(result, ["provenance", "sources"]), ["full-text"])
    XCTAssertEqual(try stringArray(result, ["provenance", "reasons"]), [])
  }

  func testEngineFailureFallsBackToFtsResults() async throws {
    let graphService = try makeService()
    _ = try graphService.service.createNote(bodyMarkdown: "# FTS result\n\nneedle text")
    let query = "query { searchNotes(query: \"needle\", includeLinked: true) { value { note { noteId } snippet rank provenance { sources reasons } } } }"
    let withoutEngine = await run(graphService, query)
    let recorder = SeededSearchRecorder()
    graphService.service.searchEngine = SeededSearchEngine(failure: .unavailable("fixture"), recorder: recorder)
    let afterFailure = await run(graphService, query)
    XCTAssertEqual(afterFailure, withoutEngine)
    XCTAssertEqual(recorder.searchCount, 1)
  }

  private func makeService(function: String = #function) throws -> GraphQLNoteGraphQLService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/EngineSeededSearchGraphQLTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return GraphQLNoteGraphQLService(service: try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path)))
  }

  private func run(_ service: GraphQLNoteGraphQLService, _ query: String) async -> JSONObject {
    await NoteGraphQLDocumentExecutor(service: service).execute(GraphQLDocumentRequest(query: query)).body
  }

  private func array(_ body: JSONObject, _ path: [String]) throws -> [JSONValue] {
    guard case let .array(values) = try value(.object(body), ["data"] + path) else { throw TestFailure.invalidPath(path) }
    return values
  }

  private func string(_ item: JSONValue, _ path: [String]) throws -> String {
    guard case let .string(value) = try value(item, path) else { throw TestFailure.invalidPath(path) }
    return value
  }

  private func stringArray(_ item: JSONValue, _ path: [String]) throws -> [String] {
    guard case let .array(values) = try value(item, path) else { throw TestFailure.invalidPath(path) }
    return try values.map { value in
      guard case let .string(string) = value else { throw TestFailure.invalidPath(path) }
      return string
    }
  }

  private func bool(_ item: JSONValue, _ path: [String]) throws -> Bool {
    guard case let .bool(value) = try value(item, path) else { throw TestFailure.invalidPath(path) }
    return value
  }

  private func value(_ initial: JSONValue, _ path: [String]) throws -> JSONValue {
    var current: JSONValue? = initial
    for key in path {
      guard case let .object(object)? = current else { throw TestFailure.invalidPath(path) }
      current = object[key]
    }
    guard let current else { throw TestFailure.invalidPath(path) }
    return current
  }

  private enum TestFailure: Error { case invalidPath([String]) }
}
