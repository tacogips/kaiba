import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AppCore

final class MeilisearchSearchEngineTests: XCTestCase {
  func testHealthAvailable() async throws {
    let engine = makeEngine { _, _ in (#"{"status":"available"}"#, 200) }
    let health = try await engine.health()
    XCTAssertTrue(health.isAvailable)
    XCTAssertEqual(health.detail, "available")
  }

  func testHealthOtherStatusIsUnavailable() async throws {
    let engine = makeEngine { _, _ in (#"{"status":"degraded"}"#, 200) }
    let health = try await engine.health()
    XCTAssertFalse(health.isAvailable)
  }

  func testHealthServerFailureThrowsUnavailable() async {
    let engine = makeEngine { _, _ in (#"{}"#, 503) }
    do {
      _ = try await engine.health()
      XCTFail("expected unavailable")
    } catch let error as SearchEngineError {
      XCTAssertEqual(error, .unavailable("HTTP 503"))
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  func testEnsureIndexCreatesWaitsAndAppliesSettings() async throws {
    let transport = RecordingMeilisearchTransport { request, _ in
      switch (request.httpMethod, request.url!.path) {
      case ("GET", "/indexes/kaiba-notes-v1"): return (#"{}"#, 404)
      case ("POST", "/indexes"): return (#"{"taskUid":1}"#, 202)
      case ("GET", "/tasks/1"): return (#"{"status":"succeeded"}"#, 200)
      case ("PATCH", "/indexes/kaiba-notes-v1/settings"): return (#"{"taskUid":2}"#, 202)
      case ("GET", "/tasks/2"): return (#"{"status":"succeeded"}"#, 200)
      default: return (#"{}"#, 500)
      }
    }
    try await engine(transport).ensureIndex()
    let requests = transport.requests
    XCTAssertEqual(requests.map { "\($0.httpMethod ?? "") \($0.url!.path)" }, [
      "GET /indexes/kaiba-notes-v1", "POST /indexes", "GET /tasks/1", "PATCH /indexes/kaiba-notes-v1/settings", "GET /tasks/2"
    ])
    let body = try XCTUnwrap(requests[3].httpBody).jsonObject()
    XCTAssertEqual(body["pagination"] as? [String: Int], ["maxTotalHits": 2000])
    XCTAssertEqual(body["sortableAttributes"] as? [String], ["updated_at"])
    XCTAssertEqual(body["filterableAttributes"] as? [String], [
      "note_id", "notebook_id", "library_id", "owner_user_id", "tag_ids", "path_tag_ids", "tag_classes",
      "class_tag_keys", "outgoing_link_note_ids", "incoming_link_note_ids", "long_term_memory"
    ])
    let settingsText = try XCTUnwrap(String(data: requests[3].httpBody!, encoding: .utf8))
    XCTAssertTrue(settingsText.contains("jpn"))
  }

  func testEnsureExistingStillPatchesSettings() async throws {
    let transport = RecordingMeilisearchTransport { request, _ in
      if request.url!.path.hasSuffix("/settings") { return (#"{"taskUid":2}"#, 202) }
      if request.url!.path == "/tasks/2" { return (#"{"status":"succeeded"}"#, 200) }
      return (#"{}"#, 200)
    }
    try await engine(transport).ensureIndex()
    XCTAssertFalse(transport.requests.contains { $0.httpMethod == "POST" && $0.url!.path == "/indexes" })
    XCTAssertTrue(transport.requests.contains { $0.httpMethod == "PATCH" })
  }

  func testCreateIndexAlreadyExistsTaskContinuesSettings() async throws {
    let transport = RecordingMeilisearchTransport { request, _ in
      switch request.url!.path {
      case "/indexes/kaiba-notes-v1": return (#"{}"#, 404)
      case "/indexes": return (#"{"taskUid":1}"#, 202)
      case "/tasks/1": return (#"{"status":"failed","error":{"code":"index_already_exists","message":"exists"}}"#, 200)
      case "/indexes/kaiba-notes-v1/settings": return (#"{"taskUid":2}"#, 202)
      case "/tasks/2": return (#"{"status":"succeeded"}"#, 200)
      default: return (#"{}"#, 500)
      }
    }
    try await engine(transport).ensureIndex()
    XCTAssertTrue(transport.requests.contains { $0.httpMethod == "PATCH" })
  }

  func testApplyEmptyDoesNotSend() async throws {
    let transport = RecordingMeilisearchTransport { _, _ in (#"{}"#, 200) }
    let result = try await engine(transport).apply([])
    XCTAssertTrue(result.isEmpty)
    XCTAssertTrue(transport.requests.isEmpty)
  }

  func testApplyMixedOperationsPreservesInputOrder() async throws {
    let transport = RecordingMeilisearchTransport { request, _ in
      if request.url!.path.contains("documents") { return (#"{"taskUid":1}"#, 202) }
      return (#"{"status":"succeeded"}"#, 200)
    }
    let a = document("a")
    let b = document("b")
    let operations: [SearchIndexOperation] = [.upsert(a), .delete(NoteID("gone")), .upsert(b)]
    let result = try await engine(transport).apply(operations)
    XCTAssertEqual(result.map(\.noteId), operations.map(\.noteId))
    XCTAssertTrue(result.allSatisfy { $0.outcome == .succeeded })
    XCTAssertEqual(transport.requests.filter { $0.url!.path.hasSuffix("/documents") }.count, 1)
    XCTAssertEqual(transport.requests.filter { $0.url!.path.hasSuffix("delete-batch") }.count, 1)
  }

  func testInvalidUpsertBatchRetriesOneDocumentAtATime() async throws {
    let transport = RecordingMeilisearchTransport { request, index in
      if request.url!.path == "/tasks/1" {
        return (#"{"status":"failed","error":{"code":"invalid_document_id","message":"bad"}}"#, 200)
      }
      if request.url!.path.contains("documents") { return ("{\"taskUid\":\(index)}", 202) }
      return (#"{"status":"succeeded"}"#, 200)
    }
    let result = try await engine(transport).apply([.upsert(document("a")), .upsert(document("b"))])
    XCTAssertTrue(result.allSatisfy { $0.outcome == .succeeded })
    XCTAssertEqual(transport.requests.filter {
      $0.url!.path.hasSuffix("/documents") && URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.name == "primaryKey"
    }.count, 3)
  }

  func testTaskPendingTimesOutWithinBound() async throws {
    let transport = RecordingMeilisearchTransport { request, _ in
      if request.url!.path.contains("documents") { return (#"{"taskUid":7}"#, 202) }
      return (#"{"status":"processing"}"#, 200)
    }
    let engine = MeilisearchSearchEngine(baseURL: URL(string: "http://localhost:7700")!, indexPrefix: "test",
      requestTimeoutSeconds: 1, transport: transport, taskWaitTimeout: 0.2, initialTaskPollInterval: 0.01)
    let start = Date()
    do {
      _ = try await engine.apply([.upsert(document("a"))])
      XCTFail("expected timeout")
    } catch let error as SearchEngineError {
      XCTAssertEqual(error, .unavailable("task pending"))
    }
    XCTAssertLessThan(Date().timeIntervalSince(start), 2)
  }

  func testUnauthorizedMapsToRejected() async {
    let engine = makeEngine { _, _ in (#"{"message":"bad","code":"invalid_api_key"}"#, 401) }
    do {
      _ = try await engine.health()
      XCTFail("expected rejection")
    } catch let error as SearchEngineError {
      if case .rejected(status: 401, reason: _) = error {} else { XCTFail("unexpected: \(error)") }
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  func testFilterExpressionExactOrderAndClassFilters() {
    let filter = SearchEngineFilter(libraryIds: [LibraryID("lib")], ownerUserId: UserID("owner"),
      notebookId: NotebookID("book"), tagIds: [TagID("tag")], excludesLongTermMemory: true,
      excludedNoteIds: [NoteID("gone")], hierarchyTagIds: [TagID("parent")],
      tagClassFilters: [SearchEngineTagClassFilter(tagClass: "kind"), SearchEngineTagClassFilter(tagClass: "entity", tagId: TagID("x"))])
    XCTAssertEqual(MeilisearchRequestBodies.filterExpression(filter), [
      "library_id IN [\"lib\"]", "owner_user_id = \"owner\"", "notebook_id = \"book\"", "tag_ids IN [\"tag\"]",
      "path_tag_ids IN [\"parent\"]", "tag_classes = \"kind\"", "class_tag_keys = \"entity:x\"",
      "long_term_memory = false", "NOT note_id IN [\"gone\"]"
    ])
  }

  func testFilterValuesEscapeBackslashBeforeQuote() {
    let filter = SearchEngineFilter(libraryIds: [LibraryID("a\\\"b")], ownerUserId: nil, notebookId: nil,
      tagIds: [], excludesLongTermMemory: false, excludedNoteIds: [])
    XCTAssertEqual(MeilisearchRequestBodies.filterExpression(filter).first, "library_id IN [\"a\\\\\\\"b\"]")
  }

  func testPlainSearchBuildsJapaneseQueryAndHighlightOptions() async throws {
    let transport = RecordingMeilisearchTransport { _, _ in (#"{"hits":[]}"#, 200) }
    let query = SearchEngineQuery(text: "日本語", filter: emptyFilter(), from: 2, size: 4)
    _ = try await engine(transport).searchPage(query)
    let request = try XCTUnwrap(transport.requests.first)
    let body = try XCTUnwrap(request.httpBody).jsonObject()
    XCTAssertEqual(body["q"] as? String, "日本語")
    XCTAssertEqual(body["offset"] as? Int, 2)
    XCTAssertEqual(body["limit"] as? Int, 4)
    XCTAssertEqual(body["locales"] as? [String], ["jpn"])
    XCTAssertEqual(body["attributesToCrop"] as? [String], ["body", "title"])
  }

  func testExpansionUsesThreeMultiSearchQueriesAndFusionReasons() async throws {
    let transport = RecordingMeilisearchTransport { request, _ in
      if request.url!.path == "/multi-search" {
        return (#"{"results":[{"hits":[{"note_id":"X","_rankingScore":0.8,"_formatted":{"body":"x"},"_matchesPosition":{"body":[]}}]},"# +
          #"{"hits":[{"note_id":"T","_rankingScore":0.2}]},{"hits":[{"note_id":"T","_rankingScore":0.2}]}]}"#, 200)
      }
      return (#"{}"#, 500)
    }
    let query = SearchEngineQuery(text: "word", filter: emptyFilter(), from: 0, size: 5, expansionTagIds: [TagID("tag")])
    let page = try await engine(transport).searchPage(query)
    let requestBody = try XCTUnwrap(transport.requests.first?.httpBody).jsonObject()
    XCTAssertEqual((requestBody["queries"] as? [[String: Any]])?.count, 3)
    XCTAssertEqual(page.hits.map(\.noteId), [NoteID("T"), NoteID("X")])
    XCTAssertEqual(page.hits[0].reasons.map(\.kind), [.tagMatch, .tagHierarchyMatch])
    XCTAssertEqual(page.hits[1].reasons.map(\.kind), [.textMatch])
    XCTAssertEqual(page.hits[1].highlight, "x")
  }

  func testExpansionSlicesFusedOffsetPage() async throws {
    let transport = RecordingMeilisearchTransport { _, _ in
      (#"{"results":[{"hits":[{"note_id":"a","_rankingScore":1},{"note_id":"b","_rankingScore":1}]},{"hits":[]},{"hits":[]}]}"#, 200)
    }
    let page = try await engine(transport).searchPage(SearchEngineQuery(text: "x", filter: emptyFilter(), from: 1, size: 1, expansionTagIds: [TagID("t")]))
    XCTAssertEqual(page.hits.map(\.noteId), [NoteID("b")])
  }

  func testRelatedSearchComposesFiveSignalsWithReasonsAndExcludesSource() async throws {
    let transport = RecordingMeilisearchTransport { request, _ in
      if request.url!.path == "/multi-search" {
        return (#"{"results":[{"hits":[{"note_id":"text","_rankingScore":1}]},{"hits":[{"note_id":"tag","_rankingScore":1}]},{"hits":[]},{"hits":[]},{"hits":[{"note_id":"linked","_rankingScore":1}]}]}"#, 200)
      }
      return (#"{}"#, 500)
    }
    let signals = SearchEngineRelatedSignals(sourceNoteId: NoteID("source"), sharedTagIds: [TagID("t")],
      nearTagIds: [TagID("near")], ancestorTagIds: [TagID("ancestor")],
      entityTags: [SearchEngineClassTag(tagClass: "kind", tagId: TagID("entity"))])
    let query = SearchEngineRelatedQuery(likeText: "related", filter: emptyFilter(), size: 5, signals: signals)
    let hits = try await engine(transport).relatedNotes(query)
    let body = try XCTUnwrap(transport.requests.first?.httpBody).jsonObject()
    let queries = try XCTUnwrap(body["queries"] as? [[String: Any]])
    XCTAssertEqual(queries.count, 5)
    XCTAssertTrue(queries.allSatisfy { String(describing: $0["filter"] ?? "").contains("NOT note_id IN [\\\"source\\\"]") })
    XCTAssertEqual(hits.map(\.noteId), [NoteID("linked"), NoteID("tag"), NoteID("text")])
    XCTAssertEqual(hits.first?.reasons.map(\.kind), [.linked])
  }

  func testRelatedNilSignalsRunsOnlyTextList() async throws {
    let transport = RecordingMeilisearchTransport { _, _ in (#"{"results":[{"hits":[{"note_id":"n","_rankingScore":0.5}]}]}"#, 200) }
    let hits = try await engine(transport).relatedNotes(SearchEngineRelatedQuery(likeText: "one", filter: emptyFilter(), size: 2))
    XCTAssertEqual(hits.map(\.noteId), [NoteID("n")])
    let requestBody = try XCTUnwrap(transport.requests.first?.httpBody).jsonObject()
    XCTAssertEqual((requestBody["queries"] as? [[String: Any]])?.count, 1)
  }

  func testRelatedAddsPerTermTextSubqueriesForPartialOverlap() async throws {
    let transport = RecordingMeilisearchTransport { _, _ in
      (#"{"results":[{"hits":[]},{"hits":[{"note_id":"n","_rankingScore":0.5}]},{"hits":[]}]}"#, 200)
    }
    let hits = try await engine(transport).relatedNotes(SearchEngineRelatedQuery(likeText: "one two", filter: emptyFilter(), size: 2))
    let queries = try XCTUnwrap(try XCTUnwrap(transport.requests.first?.httpBody).jsonObject()["queries"] as? [[String: Any]])
    XCTAssertEqual(queries.map { $0["q"] as? String }, ["one two", "one", "two"])
    XCTAssertEqual(hits.map(\.noteId), [NoteID("n")])
    XCTAssertEqual(hits.first?.reasons.map(\.kind), [.textSimilarity])
  }

  func testMultiTermSearchAddsPerTermSubqueriesAndRanksCoverage() async throws {
    let transport = RecordingMeilisearchTransport { request, _ in
      if request.url!.path == "/multi-search" {
        return (#"{"results":[{"hits":[]},{"hits":[{"note_id":"A","_rankingScore":0.9,"_formatted":{"body":"a"},"_matchesPosition":{"body":[]}},"# +
          #"{"note_id":"B","_rankingScore":0.8,"_formatted":{"body":"b"},"_matchesPosition":{"body":[]}}]},{"hits":[{"note_id":"B","_rankingScore":0.7}]}]}"#, 200)
      }
      return (#"{}"#, 500)
    }
    let page = try await engine(transport).searchPage(SearchEngineQuery(text: "alpha beta alpha", filter: emptyFilter(), from: 0, size: 5))
    let queries = try XCTUnwrap(try XCTUnwrap(transport.requests.first?.httpBody).jsonObject()["queries"] as? [[String: Any]])
    XCTAssertEqual(queries.map { $0["q"] as? String }, ["alpha beta alpha", "alpha", "beta"])
    XCTAssertEqual(page.hits.map(\.noteId), [NoteID("B"), NoteID("A")])
    XCTAssertEqual(page.hits[0].reasons.map(\.kind), [.textMatch])
    XCTAssertEqual(page.hits[0].highlight, "b")
  }

  func testMultiTermFacetsCountEverySubqueryMatch() async throws {
    let transport = RecordingMeilisearchTransport { request, _ in
      if request.url!.path == "/multi-search" {
        return (#"{"results":[{"hits":[{"note_id":"A","_rankingScore":0.9}],"facetDistribution":{"tag_classes":{"person":1}}},"# +
          #"{"hits":[{"note_id":"A","_rankingScore":0.9}]},{"hits":[{"note_id":"B","_rankingScore":0.7}]}]}"#, 200)
      }
      return (#"{"hits":[],"facetDistribution":{"tag_classes":{"person":2},"tag_ids":{"t1":2}}}"#, 200)
    }
    let query = SearchEngineQuery(text: "alpha beta", filter: emptyFilter(), from: 0, size: 5,
      facets: SearchEngineFacetRequest(tagClassLimit: 5, tagLimit: 5))
    let page = try await engine(transport).searchPage(query)
    XCTAssertEqual(transport.requests.count, 2)
    let facetBody = try XCTUnwrap(transport.requests.last?.httpBody).jsonObject()
    XCTAssertEqual(facetBody["limit"] as? Int, 0)
    XCTAssertTrue(String(describing: facetBody["filter"] ?? "").contains(#"note_id IN [\"A\", \"B\"]"#))
    XCTAssertEqual(page.facets?.tagClasses.map(\.count), [2])
    XCTAssertEqual(page.facets?.tags.map(\.value), ["t1"])
  }

  func testRelaxedTermsSkipSingleTermAndCap() {
    XCTAssertEqual(MeilisearchRequestBodies.relaxedTerms("日本語"), [])
    XCTAssertEqual(MeilisearchRequestBodies.relaxedTerms("a b A c d e f g"), ["a", "b", "c", "d", "e"])
  }

  func testFacetsSortAndTruncate() throws {
    let data = Data(#"{"facetDistribution":{"tag_classes":{"z":2,"a":2,"b":1},"tag_ids":{"t3":1,"t1":4,"t2":2}}}"#.utf8)
    let facets = try MeilisearchResponses.facets(data, request: SearchEngineFacetRequest(tagClassLimit: 2, tagLimit: 2))
    XCTAssertEqual(facets.tagClasses.map(\.value), ["a", "z"])
    XCTAssertEqual(facets.tags.map(\.value), ["t1", "t2"])
  }

  func testSafeNoteIdKeepsOriginal() { XCTAssertEqual(MeilisearchRequestBodies.documentId(NoteID("note-1_abc")), "note-1_abc") }

  func testUnsafeNoteIdIsSha256Mapped() {
    let mapped = MeilisearchRequestBodies.documentId(NoteID("note with space"))
    XCTAssertEqual(mapped.count, 66)
    XCTAssertTrue(mapped.hasPrefix("x-"))
    XCTAssertTrue(mapped.dropFirst(2).allSatisfy { $0.isHexDigit && !$0.isUppercase })
  }

  func testDeleteUsesMappedId() async throws {
    let transport = RecordingMeilisearchTransport { request, _ in
      if request.url!.path.contains("delete-batch") { return (#"{"taskUid":4}"#, 202) }
      return (#"{"status":"succeeded"}"#, 200)
    }
    _ = try await engine(transport).apply([.delete(NoteID("unsafe id"))])
    let body = try XCTUnwrap(transport.requests.first?.httpBody)
    XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String], [MeilisearchRequestBodies.documentId(NoteID("unsafe id"))])
  }

  func testApiKeyBearerHeader() async throws {
    let transport = RecordingMeilisearchTransport { _, _ in (#"{"status":"available"}"#, 200) }
    _ = try await MeilisearchSearchEngine(baseURL: URL(string: "http://localhost:7700")!, indexPrefix: "k", apiKey: "secret",
      transport: transport).health()
    XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
  }

  func testNoAuthHeaderForNone() async throws {
    let transport = RecordingMeilisearchTransport { _, _ in (#"{"status":"available"}"#, 200) }
    _ = try await engine(transport).health()
    XCTAssertNil(transport.requests.first?.value(forHTTPHeaderField: "Authorization"))
  }

  func testErrorBodySecretIsRedacted() async {
    let transport = RecordingMeilisearchTransport { _, _ in (#"{"message":"secret leaked","code":"bad_key"}"#, 401) }
    let engine = MeilisearchSearchEngine(baseURL: URL(string: "http://localhost:7700")!, indexPrefix: "k", apiKey: "secret", transport: transport)
    do {
      _ = try await engine.health()
      XCTFail("expected rejection")
    } catch {
      XCTAssertFalse(String(describing: error).contains("secret"))
    }
  }

  private func engine(_ transport: RecordingMeilisearchTransport) -> MeilisearchSearchEngine {
    MeilisearchSearchEngine(baseURL: URL(string: "http://localhost:7700")!, indexPrefix: "kaiba", transport: transport)
  }

  private func makeEngine(_ script: @escaping (URLRequest, Int) -> (String, Int)) -> MeilisearchSearchEngine {
    engine(RecordingMeilisearchTransport(script))
  }

  private func document(_ id: String) -> SearchIndexDocument {
    SearchIndexDocument(noteId: NoteID(id), notebookId: NotebookID("book"), libraryId: LibraryID("lib"), ownerUserId: nil,
      title: "title", body: "body", tagIds: [], tagNames: [], context: "", isLongTermMemory: false,
      createdAt: "2026-01-01", updatedAt: "2026-01-01")
  }

  private func emptyFilter() -> SearchEngineFilter {
    SearchEngineFilter(libraryIds: nil, ownerUserId: nil, notebookId: nil, tagIds: [], excludesLongTermMemory: false, excludedNoteIds: [])
  }
}

private final class RecordingMeilisearchTransport: SearchEngineHTTPTransport, @unchecked Sendable {
  private let lock = NSLock()
  private let script: (URLRequest, Int) -> (String, Int)
  private var captured: [URLRequest] = []
  var requests: [URLRequest] { lock.withLock { captured } }

  init(_ script: @escaping (URLRequest, Int) -> (String, Int)) { self.script = script }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let index = lock.withLock { () -> Int in captured.append(request); return captured.count }
    let (body, status) = script(request, index)
    return (Data(body.utf8), try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)))
  }
}

private extension Data {
  func jsonObject() throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: self) as? [String: Any]) }
}
