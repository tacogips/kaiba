import Foundation
@testable import AppCore
import XCTest

final class AgentSearchNotesFusionTests: NoteTestCase {
  private func call(_ input: JSONObject) -> AgentToolCall {
    AgentToolCall(id: "fusion-test", name: "search_notes", input: .object(input))
  }

  private func payload(_ result: AgentToolResult, file: StaticString = #filePath, line: UInt = #line) throws -> JSONObject {
    XCTAssertFalse(result.isError, "unexpected tool error: \(result.content)", file: file, line: line)
    return try XCTUnwrap(JSONValue(parsing: result.content).asObject, file: file, line: line)
  }

  private func expectedPayload(query: String, results: [NoteSearchResult]) -> JSONObject {
    [
      "query": .string(query),
      "results": .array(results.map { result in
        .object([
          "note_id": .id(result.note.noteId),
          "notebook_id": .id(result.note.notebookId),
          "title": result.note.title.map(JSONValue.string) ?? .null,
          "snippet": .string(result.snippet),
          "updated_at": .string(result.note.updatedAt),
          "term_coverage": .number(result.termCoverage),
          "is_linked_neighbor": .bool(result.isLinkedNeighbor),
          "tags": KaibaAgentToolbox.tagNames(result.note.tags)
        ])
      }),
      "retrieval": .string("full-text")
    ]
  }

  func testIncludeLinkedUsesEngineSeedAndGraphNeighbor() async throws {
    let service = try makeService(function: #function)
    let seed = try service.createNote(bodyMarkdown: "# Engine seed\nunindexed seed body")
    let neighbor = try service.createNote(bodyMarkdown: "# Linked note\nneighbor body")
    _ = try service.linkNotes(from: seed.noteId, to: neighbor.noteId)
    let engine = FakeSearchEngine()
    engine.scriptedHits = [SearchEngineHit(noteId: seed.noteId, score: 1, highlight: "engine excerpt")]
    let enabled = service
    enabled.searchEngine = engine
    let tools = KaibaAgentToolbox(service: enabled)

    let result = try payload(await tools.execute(call([
      "query": .string("uniqueenginequery"), "include_linked": .bool(true)
    ])))
    let values = try XCTUnwrap(result["results"]?.asArray)
    let direct = try XCTUnwrap(values.first { $0["note_id"]?.asString == seed.noteId.rawValue })
    let linked = try XCTUnwrap(values.first { $0["note_id"]?.asString == neighbor.noteId.rawValue })

    XCTAssertEqual(result["retrieval"]?.asString, "search-engine")
    XCTAssertEqual(direct["provenance"]?["sources"]?.asArray?.compactMap(\.asString), ["search-engine"])
    XCTAssertEqual(linked["is_linked_neighbor"]?.asBool, true)
    XCTAssertEqual(linked["provenance"]?["sources"]?.asArray?.compactMap(\.asString), ["graph-neighbor"])
    XCTAssertFalse(engine.recordedSearches.isEmpty)
  }

  func testEngineWithoutLinkedExpansionAddsOnlyProvenance() async throws {
    let service = try makeService(function: #function)
    let note = try service.createNote(bodyMarkdown: "# Engine result\nsearchable body")
    let engine = FakeSearchEngine()
    engine.scriptedHits = [SearchEngineHit(noteId: note.noteId, score: 1, highlight: "engine excerpt")]
    let enabled = service
    enabled.searchEngine = engine
    let tools = KaibaAgentToolbox(service: enabled)

    let result = try payload(await tools.execute(call(["query": .string("uniqueenginequery")])))
    let hit = try XCTUnwrap(result["results"]?.asArray?.first)
    let originalKeys: Set<String> = [
      "note_id", "notebook_id", "title", "snippet", "updated_at", "term_coverage", "is_linked_neighbor", "tags"
    ]

    XCTAssertEqual(result["retrieval"]?.asString, "search-engine")
    XCTAssertEqual(Set(try XCTUnwrap(hit.asObject).keys), originalKeys.union(["provenance"]))
    XCTAssertEqual(hit["provenance"]?["sources"]?.asArray?.compactMap(\.asString), ["search-engine"])
    XCTAssertNotNil(hit["provenance"]?["reasons"]?.asArray)
  }

  func testNoEnginePreservesFullTextOutputWithoutProvenance() async throws {
    let service = try makeService(function: #function)
    let direct = try service.createNote(bodyMarkdown: "# Direct\nneedle evidence")
    let neighbor = try service.createNote(bodyMarkdown: "# Neighbor\nrelated evidence")
    _ = try service.linkNotes(from: direct.noteId, to: neighbor.noteId)
    let expectedResults = try service.searchNotes(query: "needle", includeLinked: true, depth: 1, limit: 10)
    let tools = KaibaAgentToolbox(service: service)

    let result = try payload(await tools.execute(call([
      "query": .string("needle"), "include_linked": .bool(true)
    ])))

    XCTAssertEqual(result, expectedPayload(query: "needle", results: expectedResults))
    XCTAssertTrue((result["results"]?.asArray ?? []).allSatisfy { $0["provenance"] == nil })
  }

  func testEngineErrorPreservesFullTextOutputWithoutProvenance() async throws {
    let service = try makeService(function: #function)
    let direct = try service.createNote(bodyMarkdown: "# Direct\nneedle evidence")
    let neighbor = try service.createNote(bodyMarkdown: "# Neighbor\nrelated evidence")
    _ = try service.linkNotes(from: direct.noteId, to: neighbor.noteId)
    let engine = FakeSearchEngine()
    engine.failure = .unavailable("offline")
    let enabled = service
    enabled.searchEngine = engine
    let expectedResults = try service.searchNotes(query: "needle", includeLinked: true, depth: 1, limit: 10)
    let tools = KaibaAgentToolbox(service: enabled)

    let result = try payload(await tools.execute(call([
      "query": .string("needle"), "include_linked": .bool(true)
    ])))

    XCTAssertEqual(result, expectedPayload(query: "needle", results: expectedResults))
    XCTAssertTrue((result["results"]?.asArray ?? []).allSatisfy { $0["provenance"] == nil })
  }
}
