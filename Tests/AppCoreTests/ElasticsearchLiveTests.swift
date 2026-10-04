import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AppCore

final class ElasticsearchLiveTests: XCTestCase {
  func testLiveIndexSearchRelatedAndDelete() async throws {
    let configuredURL = ProcessInfo.processInfo.environment["KAIBA_ELASTICSEARCH_URL"]
    try XCTSkipUnless(configuredURL != nil)
    let url = try XCTUnwrap(configuredURL)
    let prefix = "kaiba-test-\(String(UUID().uuidString.lowercased().prefix(8)))"
    let configuration = KaibaSearchEngineConfiguration(kind: "elasticsearch", url: url, indexPrefix: prefix)
    let engine = try XCTUnwrap(SearchEngineFactory.make(configuration: configuration, environment: ProcessInfo.processInfo.environment))
    let indexName = "\(prefix)-notes-v1"
    defer { deleteIndex(url: url, indexName: indexName) }

    try await engine.ensureIndex()
    try await engine.ensureIndex()
    let english = liveDocument(noteId: "english", body: "weather forecast sunny skies")
    let japanese = liveDocument(noteId: "japanese", body: "\u{6771}\u{4EAC}\u{306E}\u{5929}\u{6C17}")
    let related = liveDocument(noteId: "related", body: "weather forecast rain tomorrow")
    let results = try await engine.apply([.upsert(english), .upsert(japanese), .upsert(related)])
    XCTAssertEqual(results.map(\.outcome), [.succeeded, .succeeded, .succeeded])
    try await refresh(url: url, indexName: indexName)

    let scope = SearchEngineFilter(
      libraryIds: [LibraryID("live-library")], ownerUserId: nil, notebookId: nil,
      tagIds: [], excludesLongTermMemory: false, excludedNoteIds: []
    )
    let englishHits = try await engine.search(SearchEngineQuery(text: "weather", filter: scope, from: 0, size: 10))
    XCTAssertTrue(englishHits.contains { $0.noteId == NoteID("english") })
    let japaneseHits = try await engine.search(SearchEngineQuery(text: "\u{6771}\u{4EAC}", filter: scope, from: 0, size: 10))
    XCTAssertTrue(japaneseHits.contains { $0.noteId == NoteID("japanese") })

    var relatedScope = scope
    relatedScope.excludedNoteIds = [NoteID("english")]
    let relatedHits = try await engine.relatedNotes(SearchEngineRelatedQuery(
      likeText: "weather forecast sunny skies", filter: relatedScope, size: 10
    ))
    XCTAssertFalse(relatedHits.contains { $0.noteId == NoteID("english") })
    XCTAssertTrue(relatedHits.contains { $0.noteId == NoteID("related") })

    _ = try await engine.apply([.delete(NoteID("english"))])
    try await refresh(url: url, indexName: indexName)
    let afterDelete = try await engine.search(SearchEngineQuery(text: "weather", filter: scope, from: 0, size: 10))
    XCTAssertFalse(afterDelete.contains { $0.noteId == NoteID("english") })
  }

  private func liveDocument(noteId: String, body: String) -> SearchIndexDocument {
    SearchIndexDocument(
      noteId: NoteID(noteId), notebookId: NotebookID("live-notebook"), libraryId: LibraryID("live-library"),
      ownerUserId: nil, title: "Integration test", body: body, tagIds: [], tagNames: [], context: "",
      isLongTermMemory: false, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"
    )
  }

  private func refresh(url: String, indexName: String) async throws {
    var request = URLRequest(url: try XCTUnwrap(URL(string: url)).appendingPathComponent("\(indexName)/_refresh"))
    request.httpMethod = "POST"
    let (_, response) = try await URLSession.shared.data(for: request)
    XCTAssertTrue((response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false)
  }

  private func deleteIndex(url: String, indexName: String) {
    guard let base = URL(string: url) else { return }
    var request = URLRequest(url: base.appendingPathComponent(indexName))
    request.httpMethod = "DELETE"
    let semaphore = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { _, _, _ in semaphore.signal() }.resume()
    _ = semaphore.wait(timeout: .now() + 5)
  }
}
