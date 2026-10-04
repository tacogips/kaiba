import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AppCore

final class ElasticsearchSearchEngineTests: XCTestCase {
  func testIndexIdentityAndEnsureIndexCreationAndRace() async throws {
    let existing = RecordingElasticsearchTransport([(200, Data())])
    let engine = makeEngine(transport: existing)
    XCTAssertEqual(engine.indexIdentity, "elasticsearch:kaiba-notes-v1")
    try await engine.ensureIndex()
    XCTAssertEqual(existing.requests.count, 1)
    XCTAssertEqual(existing.requests.first?.httpMethod, "HEAD")

    let create = RecordingElasticsearchTransport([
      (404, Data()),
      (200, Data())
    ])
    try await makeEngine(transport: create).ensureIndex()
    XCTAssertEqual(create.requests.map(\.httpMethod), ["HEAD", "PUT"])
    let body = try XCTUnwrap(create.requests.last?.httpBody)
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let mappings = try XCTUnwrap(root["mappings"] as? [String: Any])
    XCTAssertEqual(mappings["dynamic"] as? String, "strict")
    let properties = try XCTUnwrap(mappings["properties"] as? [String: [String: String]])
    XCTAssertEqual(properties["title"]?["analyzer"], "cjk")
    XCTAssertEqual(properties["tag_ids"]?["type"], "keyword")

    let raced = RecordingElasticsearchTransport([
      (404, Data()),
      (400, Data(#"{"error":{"type":"resource_already_exists_exception"}}"#.utf8))
    ])
    try await makeEngine(transport: raced).ensureIndex()
  }

  func testApplyBuildsNDJSONAndMapsDeleteNotFoundToSuccess() async throws {
    let document = sampleDocument()
    let response = Data(#"{"items":[{"index":{"status":201}},{"delete":{"status":404}}]}"#.utf8)
    let transport = RecordingElasticsearchTransport([(200, response)])
    let results = try await makeEngine(transport: transport).apply([.upsert(document), .delete(NoteID("n2"))])
    XCTAssertEqual(results.map(\.outcome), [.succeeded, .succeeded])
    let request = try XCTUnwrap(transport.requests.first)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-ndjson")
    let body = try XCTUnwrap(request.httpBody)
    XCTAssertEqual(body.last, 10)
    let lines = try XCTUnwrap(String(data: body, encoding: .utf8)).split(separator: "\n")
    XCTAssertEqual(lines.count, 3)
    XCTAssertTrue(lines[0].contains("\"index\""))
    XCTAssertTrue(lines[2].contains("\"delete\""))

    let empty = RecordingElasticsearchTransport([])
    let emptyResults = try await makeEngine(transport: empty).apply([])
    XCTAssertTrue(emptyResults.isEmpty)
    XCTAssertTrue(empty.requests.isEmpty)
  }

  func testApplyMapsItemFailureAndHTTPUnavailable() async throws {
    let itemFailure = RecordingElasticsearchTransport([(
      200,
      Data(#"{"items":[{"index":{"status":400,"error":{"type":"mapper_parsing_exception","reason":"bad field"}}}]}"#.utf8)
    )])
    let outcome = try await makeEngine(transport: itemFailure).apply([.upsert(sampleDocument())])
    XCTAssertEqual(outcome, [SearchIndexOperationResult(
      noteId: NoteID("n1"), outcome: .failed("mapper_parsing_exception: bad field")
    )])

    let unavailable = RecordingElasticsearchTransport([(503, Data())])
    do {
      _ = try await makeEngine(transport: unavailable).apply([.upsert(sampleDocument())])
      XCTFail("Expected unavailable error")
    } catch {
      XCTAssertEqual(error as? SearchEngineError, .unavailable("HTTP 503"))
    }
  }

  func testSearchFiltersHighlightsAndEmptyLibraryShortCircuit() async throws {
    let result = Data(#"{"hits":{"hits":[{"_id":"n1","_source":{"note_id":"n1"},"_score":2.5,"highlight":{"body":["body hit"],"title":["title hit"]}}]}}"#.utf8)
    let transport = RecordingElasticsearchTransport([(200, result)])
    let engine = makeEngine(transport: transport)
    let filter = SearchEngineFilter(
      libraryIds: [LibraryID("a"), LibraryID("b")], ownerUserId: UserID("u"),
      notebookId: NotebookID("nb"), tagIds: [TagID("t")],
      excludesLongTermMemory: true, excludedNoteIds: [NoteID("x")]
    )
    let hits = try await engine.search(SearchEngineQuery(text: "hello", filter: filter, from: 3, size: 7))
    XCTAssertEqual(hits.first?.highlight, "body hit")
    XCTAssertEqual(hits.first?.score, 2.5)
    let request = try XCTUnwrap(transport.requests.first)
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    let bodyData = try XCTUnwrap(request.httpBody)
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    XCTAssertEqual(root["from"] as? Int, 3)
    let query = try XCTUnwrap(root["query"] as? [String: Any])
    let bool = try XCTUnwrap(query["bool"] as? [String: Any])
    let must = try XCTUnwrap(bool["must"] as? [[String: Any]])
    let multiMatch = try XCTUnwrap(must.first?["multi_match"] as? [String: Any])
    XCTAssertEqual(multiMatch["fields"] as? [String], ["title^3", "body", "tags^2", "context"])
    let filters = try XCTUnwrap(bool["filter"] as? [[String: Any]])
    XCTAssertTrue(filters.contains { ($0["terms"] as? [String: [String]])?["library_id"] == ["a", "b"] })
    XCTAssertTrue(filters.contains { ($0["term"] as? [String: String])?["owner_user_id"] == "u" })
    XCTAssertTrue(filters.contains { ($0["term"] as? [String: String])?["notebook_id"] == "nb" })
    XCTAssertTrue(filters.contains { ($0["terms"] as? [String: [String]])?["tag_ids"] == ["t"] })
    let excluded = try XCTUnwrap(bool["must_not"] as? [[String: Any]])
    XCTAssertTrue(excluded.contains { ($0["term"] as? [String: Bool])?["long_term_memory"] == true })
    XCTAssertTrue(excluded.contains { ($0["ids"] as? [String: [String]])?["values"] == ["x"] })
    let highlight = try XCTUnwrap(root["highlight"] as? [String: Any])
    XCTAssertEqual(highlight["pre_tags"] as? [String], [""])
    XCTAssertEqual(highlight["post_tags"] as? [String], [""])

    let emptyScopeTransport = RecordingElasticsearchTransport([])
    let emptyScope = SearchEngineFilter(
      libraryIds: [], ownerUserId: nil, notebookId: nil, tagIds: [],
      excludesLongTermMemory: false, excludedNoteIds: []
    )
    let emptyScopeHits = try await makeEngine(transport: emptyScopeTransport).search(
      SearchEngineQuery(text: "x", filter: emptyScope, from: 0, size: 5)
    )
    XCTAssertTrue(emptyScopeHits.isEmpty)
    XCTAssertTrue(emptyScopeTransport.requests.isEmpty)
  }

  func testRelatedQueryAndHealth() async throws {
    let results = Data(#"{"hits":{"hits":[{"_id":"n2","_score":1}]}}"#.utf8)
    let transport = RecordingElasticsearchTransport([(200, results), (200, Data(#"{"status":"yellow"}"#.utf8)), (200, Data(#"{"status":"red"}"#.utf8))])
    let engine = makeEngine(transport: transport)
    let filter = SearchEngineFilter(
      libraryIds: nil, ownerUserId: nil, notebookId: nil, tagIds: [],
      excludesLongTermMemory: false, excludedNoteIds: [NoteID("source")]
    )
    let hits = try await engine.relatedNotes(SearchEngineRelatedQuery(likeText: "some text", filter: filter, size: 8))
    XCTAssertNil(hits.first?.highlight)
    let data = try XCTUnwrap(transport.requests.first?.httpBody)
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let bool = try XCTUnwrap((root["query"] as? [String: Any])?["bool"] as? [String: Any])
    let must = try XCTUnwrap(bool["must"] as? [[String: Any]])
    let moreLike = try XCTUnwrap(must.first?["more_like_this"] as? [String: Any])
    XCTAssertEqual(moreLike["like"] as? String, "some text")
    XCTAssertEqual(moreLike["min_doc_freq"] as? Int, 1)
    XCTAssertTrue((bool["must_not"] as? [[String: Any]])?.contains {
      ($0["ids"] as? [String: [String]])?["values"] == ["source"]
    } == true)
    XCTAssertNil(root["highlight"])
    let yellowHealth = try await engine.health()
    let redHealth = try await engine.health()
    XCTAssertTrue(yellowHealth.isAvailable)
    XCTAssertFalse(redHealth.isAvailable)
  }

  func testAuthorizationAndErrorSanitization() async throws {
    let apiTransport = RecordingElasticsearchTransport([(200, Data(#"{"status":"green"}"#.utf8))])
    let apiEngine = ElasticsearchSearchEngine(
      baseURL: URL(string: "https://example.test")!, indexPrefix: "kaiba",
      authorization: .apiKey("secret-key"), transport: apiTransport
    )
    _ = try await apiEngine.health()
    XCTAssertEqual(apiTransport.requests.first?.value(forHTTPHeaderField: "Authorization"), "ApiKey secret-key")

    let basicTransport = RecordingElasticsearchTransport([(403, Data(#"{"error":{"type":"security_exception","reason":"secret-password"}}"#.utf8))])
    let basicEngine = ElasticsearchSearchEngine(
      baseURL: URL(string: "https://example.test")!, indexPrefix: "kaiba",
      authorization: .basic(username: "user", password: "secret-password"), transport: basicTransport
    )
    do {
      _ = try await basicEngine.health()
      XCTFail("Expected request rejection")
    } catch {
      XCTAssertFalse(String(describing: error).contains("secret-password"))
      XCTAssertFalse(String(describing: error).contains("user:"))
    }
    XCTAssertEqual(basicTransport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Basic dXNlcjpzZWNyZXQtcGFzc3dvcmQ=")
  }

  func testUnauthorizedErrorContainsNoApiKey() async throws {
    let transport = RecordingElasticsearchTransport([(
      401,
      Data(#"{"error":{"type":"secret-key","reason":"secret-key"}}"#.utf8)
    )])
    let engine = ElasticsearchSearchEngine(
      baseURL: URL(string: "https://example.test")!, indexPrefix: "kaiba",
      authorization: .apiKey("secret-key"), transport: transport
    )
    do {
      _ = try await engine.health()
      XCTFail("Expected request rejection")
    } catch {
      XCTAssertEqual(error as? SearchEngineError, .rejected(status: 401, reason: "[redacted]"))
      XCTAssertFalse(String(describing: error).contains("secret-key"))
    }
  }

  func testTransportErrorMapsToUnavailable() async throws {
    let engine = makeEngine(transport: FailingElasticsearchTransport())
    do {
      _ = try await engine.health()
      XCTFail("Expected unavailable error")
    } catch {
      XCTAssertEqual(error as? SearchEngineError, .unavailable("URLError -1009"))
    }
  }

  private func makeEngine(transport: any ElasticsearchHTTPTransport) -> ElasticsearchSearchEngine {
    ElasticsearchSearchEngine(
      baseURL: URL(string: "http://127.0.0.1:9200")!, indexPrefix: "kaiba",
      authorization: .none, transport: transport
    )
  }

  private func sampleDocument() -> SearchIndexDocument {
    SearchIndexDocument(
      noteId: NoteID("n1"), notebookId: NotebookID("nb"), libraryId: LibraryID("lib"),
      ownerUserId: UserID("u"), title: "title", body: "body", tagIds: [TagID("t")],
      tagNames: ["tag"], context: "context", isLongTermMemory: false,
      createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-02T00:00:00Z"
    )
  }
}

private final class RecordingElasticsearchTransport: ElasticsearchHTTPTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var responses: [(Int, Data)]
  private var capturedRequests: [URLRequest] = []

  init(_ responses: [(Int, Data)]) { self.responses = responses }

  var requests: [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return capturedRequests
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let response = takeResponse(for: request)
    let http = try XCTUnwrap(HTTPURLResponse(
      url: request.url!, statusCode: response.0, httpVersion: nil, headerFields: nil
    ))
    return (response.1, http)
  }

  private func takeResponse(for request: URLRequest) -> (Int, Data) {
    lock.lock()
    defer { lock.unlock() }
    capturedRequests.append(request)
    let response = responses.isEmpty ? (500, Data()) : responses.removeFirst()
    return response
  }
}

private struct FailingElasticsearchTransport: ElasticsearchHTTPTransport {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    throw URLError(.notConnectedToInternet)
  }
}
