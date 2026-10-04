import Foundation

import AppCore
import AppGraphQL
import XCTest

private struct GraphQLSearchEngineFixture: SearchEngine {
  var hits: [SearchEngineHit] = []
  var failure: SearchEngineError?
  var indexIdentity: String { "fixture" }

  func health() async throws -> SearchEngineHealth { .init(isAvailable: true, detail: "ok") }
  func ensureIndex() async throws {}
  func apply(_ operations: [SearchIndexOperation]) async throws -> [SearchIndexOperationResult] { [] }
  func search(_ query: SearchEngineQuery) async throws -> [SearchEngineHit] {
    if let failure { throw failure }
    return hits
  }
  func relatedNotes(_ query: SearchEngineRelatedQuery) async throws -> [SearchEngineHit] {
    if let failure { throw failure }
    return hits
  }
}

final class SearchEngineGraphQLTests: XCTestCase {
  func testCapabilityAndDisabledEngineStatus() async throws {
    let service = try makeService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let capability = await run(executor, "query { searchEngineCapability { result { accepted status } enabled } }")
    XCTAssertEqual(try bool(capability, ["searchEngineCapability", "enabled"]), false)
    XCTAssertEqual(try string(capability, ["searchEngineCapability", "result", "status"]), "ok")
    let disabled = await run(executor, "query { engineSearchNotes(query: \"x\") { result { accepted status diagnostics } } }")
    XCTAssertEqual(try string(disabled, ["engineSearchNotes", "result", "status"]), "feature-disabled")
    XCTAssertEqual(try stringArray(disabled, ["engineSearchNotes", "result", "diagnostics"]), ["search engine is not configured"])
  }

  func testCapabilityAndEngineHits() async throws {
    var service = try makeService()
    let first = try service.service.createNote(bodyMarkdown: "# First\n\nbody")
    let second = try service.service.createNote(bodyMarkdown: "# Second\n\nbody")
    service.service.searchEngine = GraphQLSearchEngineFixture(hits: [
      .init(noteId: first.noteId, score: 4, highlight: "first match"),
      .init(noteId: second.noteId, score: 3, highlight: "second match")
    ])
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let capability = await run(executor, "query { searchEngineCapability { enabled } }")
    XCTAssertEqual(try bool(capability, ["searchEngineCapability", "enabled"]), true)
    let response = await run(executor, "query { engineSearchNotes(query: \"body\") { result { status } value { note { noteId } snippet score } } }")
    let values = try array(response, ["engineSearchNotes", "value"])
    XCTAssertEqual(values.count, 2)
    XCTAssertEqual(try string(values[0], ["note", "noteId"]), first.noteId.rawValue)
    XCTAssertEqual(try string(values[0], ["snippet"]), "first match")
    XCTAssertEqual(try double(values[0], ["score"]), 4)
    let related = await run(executor, "query { relatedNotes(noteId: \"\(second.noteId.rawValue)\") { value { note { noteId } snippet } } }")
    let relatedValues = try array(related, ["relatedNotes", "value"])
    XCTAssertEqual(relatedValues.count, 1)
    XCTAssertEqual(try string(relatedValues[0], ["note", "noteId"]), first.noteId.rawValue)
  }

  func testEngineFailureIsSanitizedAndRelatedNotFoundKeepsMapping() async throws {
    var service = try makeService()
    service.service.searchEngine = GraphQLSearchEngineFixture(failure: .unavailable("secret-host"))
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let unavailable = await run(executor, "query { engineSearchNotes(query: \"x\") { result { status diagnostics } } }")
    XCTAssertEqual(try string(unavailable, ["engineSearchNotes", "result", "status"]), "search-engine-unavailable")
    let diagnostics = try stringArray(unavailable, ["engineSearchNotes", "result", "diagnostics"])
    XCTAssertEqual(diagnostics, ["search engine unavailable"])
    XCTAssertFalse(diagnostics.joined().contains("secret-host"))
    let missing = await run(executor, "query { relatedNotes(noteId: \"missing\") { result { status } } }")
    XCTAssertEqual(try string(missing, ["relatedNotes", "result", "status"]), "not_found")
  }

  func testLimitsAndEmptyQueryAreRejected() async throws {
    let service = try makeService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let overLimit = await run(executor, "query { engineSearchNotes(query: \"x\", limit: 201) { result { status } } }")
    XCTAssertTrue(errorMessage(overLimit).contains("limit must be between 0 and 200"))
    let overOffset = await run(executor, "query { engineSearchNotes(query: \"x\", offset: 1001) { result { status } } }")
    XCTAssertTrue(errorMessage(overOffset).contains("offset must be between 0 and 1000 for engineSearchNotes"))
    let relatedLimit = await run(executor, "query { relatedNotes(noteId: \"x\", limit: 21) { result { status } } }")
    XCTAssertTrue(errorMessage(relatedLimit).contains("limit must be between 0 and 20 for graph fields"))
    var configured = service
    configured.service.searchEngine = GraphQLSearchEngineFixture()
    let empty = await run(NoteGraphQLDocumentExecutor(service: configured), "query { engineSearchNotes(query: \"\") { result { status } } }")
    XCTAssertEqual(try string(empty, ["engineSearchNotes", "result", "status"]), "invalid_request")
  }

  func testSearchNotesOutputIsUnchangedWhenEngineIsAttached() async throws {
    var service = try makeService()
    _ = try service.service.createNote(bodyMarkdown: "# Search parity\n\nsearch parity words")
    let query = "query { searchNotes(query: \"parity\") { result { status } value { note { noteId } snippet rank } } }"
    let withoutEngine = await run(NoteGraphQLDocumentExecutor(service: service), query)
    service.service.searchEngine = GraphQLSearchEngineFixture()
    let withEngine = await run(NoteGraphQLDocumentExecutor(service: service), query)
    XCTAssertEqual(withEngine, withoutEngine)
  }

  private func makeService(function: String = #function) throws -> GraphQLNoteGraphQLService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/SearchEngineGraphQLTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return GraphQLNoteGraphQLService(service: try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path)))
  }

  private func run(_ executor: NoteGraphQLDocumentExecutor, _ query: String) async -> JSONObject {
    let response = await executor.execute(GraphQLDocumentRequest(query: query))
    return response.body
  }

  private func value(_ body: JSONObject, _ path: [String]) throws -> JSONValue {
    try value(.object(body), path)
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

  private func object(_ value: JSONValue, _ path: [String]) throws -> JSONObject {
    guard case let .object(result) = value else { throw TestFailure.invalidPath(path) }
    return result
  }

  private func array(_ body: JSONObject, _ path: [String]) throws -> [JSONValue] {
    guard case let .array(values) = try value(body, ["data"] + path) else { throw TestFailure.invalidPath(path) }
    return values
  }

  private func string(_ body: JSONObject, _ path: [String]) throws -> String {
    guard case let .string(value) = try value(body, ["data"] + path) else { throw TestFailure.invalidPath(path) }
    return value
  }

  private func string(_ item: JSONValue, _ path: [String]) throws -> String {
    guard case let .string(result) = try value(item, path) else { throw TestFailure.invalidPath(path) }
    return result
  }

  private func bool(_ body: JSONObject, _ path: [String]) throws -> Bool {
    guard case let .bool(value) = try value(body, ["data"] + path) else { throw TestFailure.invalidPath(path) }
    return value
  }

  private func double(_ item: JSONValue, _ path: [String]) throws -> Double {
    switch try value(item, path) {
    case let .number(result): return result
    case let .integer(result): return Double(result)
    default: throw TestFailure.invalidPath(path)
    }
  }

  private func stringArray(_ body: JSONObject, _ path: [String]) throws -> [String] {
    guard case let .array(values) = try value(body, ["data"] + path) else { throw TestFailure.invalidPath(path) }
    return values.compactMap { if case let .string(value) = $0 { value } else { nil } }
  }

  private func errorMessage(_ body: JSONObject) -> String {
    guard case let .array(errors)? = body["errors"], case let .object(first)? = errors.first,
          case let .string(message)? = first["message"] else { return "" }
    return message
  }

  private enum TestFailure: Error { case invalidPath([String]) }
}
