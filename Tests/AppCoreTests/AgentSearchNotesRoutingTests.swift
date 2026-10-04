import Foundation
@testable import AppCore
import XCTest

final class AgentSearchNotesRoutingTests: NoteTestCase {
  private func call(_ input: JSONObject) -> AgentToolCall {
    AgentToolCall(id: "routing-test", name: "search_notes", input: .object(input))
  }

  private func payload(_ result: AgentToolResult, file: StaticString = #filePath, line: UInt = #line) throws -> JSONObject {
    XCTAssertFalse(result.isError, "unexpected tool error: \(result.content)", file: file, line: line)
    return try XCTUnwrap(JSONValue(parsing: result.content).asObject, file: file, line: line)
  }

  func testNoEngineUsesFullTextAndPreservesSearchResults() async throws {
    let service = try makeService(function: #function)
    let note = try service.createNote(bodyMarkdown: "# Routing note\nalpha beta")
    let expected = try service.searchNotes(query: "alpha")
    let tools = KaibaAgentToolbox(service: service)

    let result = try payload(await tools.execute(call(["query": .string("alpha")])))

    XCTAssertEqual(result["retrieval"]?.asString, "full-text")
    XCTAssertEqual(
      result["results"]?.asArray?.compactMap { $0["note_id"]?.asString },
      expected.map { $0.note.noteId.rawValue }
    )
    XCTAssertEqual(result["results"]?.asArray?.first?["note_id"]?.asString, note.noteId.rawValue)
  }

  func testEngineUsesRetrievalTextForCoverageAndPreservesOutputKeys() async throws {
    let service = try makeService(function: #function)
    let note = try service.createNote(bodyMarkdown: "# Routing note\nalpha beta")
    let engine = FakeSearchEngine()
    engine.scriptedHits = [SearchEngineHit(noteId: note.noteId, score: 1, highlight: "engine snippet")]
    let enabled = service
    enabled.searchEngine = engine
    let tools = KaibaAgentToolbox(service: enabled)

    let result = try payload(await tools.execute(call(["query": .string("alpha gamma")])))
    let hit = try XCTUnwrap(result["results"]?.asArray?.first)

    XCTAssertEqual(result["retrieval"]?.asString, "search-engine")
    XCTAssertEqual(hit["note_id"]?.asString, note.noteId.rawValue)
    XCTAssertEqual(hit["notebook_id"]?.asString, note.notebookId.rawValue)
    XCTAssertEqual(hit["title"]?.asString, "Routing note")
    XCTAssertEqual(hit["snippet"]?.asString, "engine snippet")
    XCTAssertNotNil(hit["updated_at"]?.asString)
    XCTAssertEqual(hit["term_coverage"]?.asDouble, 0.5)
    XCTAssertEqual(hit["is_linked_neighbor"]?.asBool, false)
    XCTAssertNotNil(hit["tags"]?.asArray)
  }

  func testIncludeLinkedKeepsFullTextRouting() async throws {
    let service = try makeService(function: #function)
    _ = try service.createNote(bodyMarkdown: "alpha beta")
    let engine = FakeSearchEngine()
    let enabled = service
    enabled.searchEngine = engine
    let tools = KaibaAgentToolbox(service: enabled)

    let result = try payload(await tools.execute(call([
      "query": .string("alpha"), "include_linked": .bool(true)
    ])))

    XCTAssertEqual(result["retrieval"]?.asString, "full-text")
    XCTAssertTrue(engine.recordedSearches.isEmpty)
  }

  func testSearchEngineErrorFallsBackToFullText() async throws {
    let service = try makeService(function: #function)
    let note = try service.createNote(bodyMarkdown: "alpha beta")
    let engine = FakeSearchEngine()
    engine.failure = .unavailable("test")
    let enabled = service
    enabled.searchEngine = engine
    let tools = KaibaAgentToolbox(service: enabled)

    let result = try payload(await tools.execute(call(["query": .string("alpha")])))

    XCTAssertEqual(result["retrieval"]?.asString, "full-text")
    XCTAssertEqual(result["results"]?.asArray?.first?["note_id"]?.asString, note.noteId.rawValue)
  }

  func testEngineResultsAreRecheckedAgainstStoreReachability() async throws {
    let service = try makeService(function: #function)
    let closed = try service.createLibrary(name: "agent-search-private", authRequired: true)
    let privateNote = try service.scoped(toLibrary: closed.libraryId).createNote(bodyMarkdown: "alpha beta")
    let engine = FakeSearchEngine()
    engine.scriptedHits = [SearchEngineHit(noteId: privateNote.noteId, score: 1, highlight: nil)]
    let anonymous = service.scoped(to: NoteStoreSchema.defaultUserId).unauthenticated()
    anonymous.searchEngine = engine
    let tools = KaibaAgentToolbox(service: anonymous)

    let result = try payload(await tools.execute(call(["query": .string("alpha")])))

    XCTAssertEqual(result["retrieval"]?.asString, "search-engine")
    XCTAssertEqual(result["results"]?.asArray?.count, 0)
  }

  func testInvalidLimitRetainsToolValidationError() async throws {
    let tools = KaibaAgentToolbox(service: try makeService(function: #function))

    let result = await tools.execute(call(["query": .string("alpha"), "limit": .integer(0)]))

    XCTAssertTrue(result.isError)
    XCTAssertTrue(result.content.contains("limit must be an integer in 1...50"), result.content)
  }
}
