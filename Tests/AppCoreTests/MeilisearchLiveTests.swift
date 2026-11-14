import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AppCore

final class MeilisearchLiveTests: XCTestCase {
  func testLiveIndexSearchJapaneseRelatedAndDelete() async throws {
    let url = try liveURL()
    let prefix = livePrefix()
    let engine = try makeEngine(url: url, prefix: prefix)
    defer { deleteIndex(url: url, prefix: prefix) }

    try await engine.ensureIndex()
    try await engine.ensureIndex()
    let english = liveDocument(noteId: "english", body: "weather forecast sunny skies")
    let japanese = liveDocument(noteId: "japanese", body: "\u{6771}\u{4EAC}\u{306E}\u{5929}\u{6C17}")
    let related = liveDocument(noteId: "related", body: "weather forecast rain tomorrow")
    let applied = try await engine.apply([.upsert(english), .upsert(japanese), .upsert(related)])
    XCTAssertEqual(applied.map(\.outcome), [.succeeded, .succeeded, .succeeded])

    let filter = liveFilter()
    let englishHits = try await engine.search(SearchEngineQuery(text: "weather", filter: filter, from: 0, size: 10))
    XCTAssertTrue(englishHits.contains { $0.noteId == NoteID("english") })
    let japaneseHits = try await engine.search(SearchEngineQuery(text: "\u{6771}\u{4EAC}", filter: filter, from: 0, size: 10))
    XCTAssertTrue(japaneseHits.contains { $0.noteId == NoteID("japanese") })

    var relatedFilter = filter
    relatedFilter.excludedNoteIds = [NoteID("english")]
    let relatedHits = try await engine.relatedNotes(SearchEngineRelatedQuery(
      likeText: "weather forecast sunny skies", filter: relatedFilter, size: 10
    ))
    XCTAssertFalse(relatedHits.contains { $0.noteId == NoteID("english") })
    XCTAssertTrue(relatedHits.contains { $0.noteId == NoteID("related") })

    let deleted = try await engine.apply([.delete(NoteID("english"))])
    XCTAssertEqual(deleted.map(\.outcome), [.succeeded])
    let afterDelete = try await engine.search(SearchEngineQuery(text: "weather", filter: filter, from: 0, size: 10))
    XCTAssertFalse(afterDelete.contains { $0.noteId == NoteID("english") })
  }

  func testLiveOntologyExpansionAndFacets() async throws {
    let url = try liveURL()
    let prefix = livePrefix()
    let engine = try makeEngine(url: url, prefix: prefix)
    defer { deleteIndex(url: url, prefix: prefix) }

    try await engine.ensureIndex()
    let parent = SearchIndexPathTag(tagId: TagID("parent"), name: "parent", tagClass: "topic", isDirect: false)
    let child = SearchIndexPathTag(tagId: TagID("child"), name: "child", tagClass: "person", isDirect: true)
    let descendant = liveDocument(noteId: "descendant", body: "alpha", pathTags: [parent, child])
    let other = liveDocument(
      noteId: "other", body: "parent alpha",
      pathTags: [SearchIndexPathTag(tagId: TagID("other-tag"), name: "other", tagClass: "topic", isDirect: true)]
    )
    let expansionTag = SearchIndexPathTag(tagId: TagID("expansion"), name: "expansion", tagClass: "topic", isDirect: true)
    let tagOnly = liveDocument(noteId: "tag-only", body: "unrelated material", pathTags: [expansionTag])
    let textOnly = liveDocument(noteId: "text-only", body: "needle text match")
    let operations = try await engine.apply([.upsert(descendant), .upsert(other), .upsert(tagOnly), .upsert(textOnly)])
    XCTAssertEqual(operations.map(\.outcome), Array(repeating: .succeeded, count: 4))

    let hierarchy = try await engine.search(SearchEngineQuery(
      text: "alpha", filter: liveFilter(hierarchyTagIds: [TagID("parent")]), from: 0, size: 10
    ))
    XCTAssertTrue(hierarchy.contains { $0.noteId == NoteID("descendant") })
    XCTAssertFalse(hierarchy.contains { $0.noteId == NoteID("other") })

    let classFilter = SearchEngineFilter(
      libraryIds: [LibraryID("live-library")], ownerUserId: nil, notebookId: nil,
      tagIds: [], excludesLongTermMemory: false, excludedNoteIds: [],
      tagClassFilters: [SearchEngineTagClassFilter(tagClass: "person")]
    )
    let classHits = try await engine.search(SearchEngineQuery(text: "alpha", filter: classFilter, from: 0, size: 10))
    XCTAssertEqual(classHits.map(\.noteId), [NoteID("descendant")])

    let expanded = try await engine.search(SearchEngineQuery(
      text: "needle", filter: liveFilter(), from: 0, size: 10, expansionTagIds: [TagID("expansion")]
    ))
    let expandedIds = expanded.map(\.noteId)
    XCTAssertLessThan(try XCTUnwrap(expandedIds.firstIndex(of: NoteID("tag-only"))),
                      try XCTUnwrap(expandedIds.firstIndex(of: NoteID("text-only"))))

    let faceted = try await engine.searchPage(SearchEngineQuery(
      text: "alpha", filter: liveFilter(), from: 0, size: 10, facets: SearchEngineFacetRequest()
    ))
    XCTAssertTrue(faceted.facets?.tagClasses.contains { $0.value == "person" && $0.count == 1 } == true)
  }

  func testLiveRelatedSignalsHaveReasonsAndExcludeSource() async throws {
    let url = try liveURL()
    let prefix = livePrefix()
    let engine = try makeEngine(url: url, prefix: prefix)
    defer { deleteIndex(url: url, prefix: prefix) }

    try await engine.ensureIndex()
    let person = SearchIndexPathTag(tagId: TagID("shared-person"), name: "Alice", tagClass: "person", isDirect: true)
    let source = liveDocument(noteId: "source", body: "unique common astronomy text", pathTags: [person])
    let linked = liveDocument(noteId: "linked", body: "unrelated", outgoing: [NoteID("source")])
    let shared = liveDocument(noteId: "shared", body: "unrelated", pathTags: [person])
    let textOnly = liveDocument(noteId: "text", body: "unique common astronomy text")
    _ = try await engine.apply([.upsert(source), .upsert(linked), .upsert(shared), .upsert(textOnly)])

    let hits = try await engine.relatedNotes(SearchEngineRelatedQuery(
      likeText: "unique common astronomy text",
      filter: liveFilter(excludedNoteIds: [NoteID("source")]),
      size: 10,
      signals: SearchEngineRelatedSignals(
        sourceNoteId: NoteID("source"), sharedTagIds: [TagID("shared-person")], nearTagIds: [], ancestorTagIds: [],
        entityTags: [SearchEngineClassTag(tagClass: "person", tagId: TagID("shared-person"))]
      )
    ))
    XCTAssertFalse(hits.contains { $0.noteId == NoteID("source") })
    XCTAssertTrue(try XCTUnwrap(hits.first { $0.noteId == NoteID("linked") }).reasons.contains { $0.kind == .linked })
    XCTAssertTrue(try XCTUnwrap(hits.first { $0.noteId == NoteID("shared") }).reasons.contains { $0.kind == .sharedTag })
    XCTAssertTrue(try XCTUnwrap(hits.first { $0.noteId == NoteID("text") }).reasons.contains { $0.kind == .textSimilarity })
  }

  func testLiveEngineSeedRetrievalReturnsLinkedNeighbor() async throws {
    let url = try liveURL()
    let prefix = livePrefix()
    defer { deleteIndex(url: url, prefix: prefix) }
    let service = try makeService(function: #function)
    let seed = try service.createNote(bodyMarkdown: "\u{6771}\u{4EAC}\u{306E}\u{5929}\u{6C17} engine seed")
    let neighbor = try service.createNote(bodyMarkdown: "linked neighbor without query")
    _ = try service.linkNotes(from: seed.noteId, to: neighbor.noteId)
    _ = try await service.updateSearchEngineSettings(SearchEngineSettingsInput(
      kind: "meilisearch", url: url, indexPrefix: prefix, authMode: "none"
    ))
    let engine = try XCTUnwrap(service.makeResolvedSearchEngine(configuration: nil, environment: [:]))
    service.searchEngine = engine
    try await engine.ensureIndex()
    _ = try service.activateSearchEngineSync(indexIdentity: engine.indexIdentity)
    let drain = try await SearchIndexSynchronizer(service: service).drainUntilIdle(engine: engine)
    XCTAssertEqual(drain.failed, 0)

    let outcome = try await service.retrieveNotes(query: "\u{6771}\u{4EAC}", includeLinked: true, limit: 10)
    XCTAssertTrue(outcome.usedSearchEngine)
    let seedResult = try XCTUnwrap(outcome.results.first { $0.note.noteId == seed.noteId })
    XCTAssertTrue(try XCTUnwrap(seedResult.provenance).sources.contains(.searchEngine))
    let neighborResult = try XCTUnwrap(outcome.results.first { $0.note.noteId == neighbor.noteId })
    XCTAssertTrue(neighborResult.isLinkedNeighbor)
    XCTAssertTrue(try XCTUnwrap(neighborResult.provenance).sources.contains(.graphNeighbor))
  }

  private func liveURL() throws -> String {
    let value = ProcessInfo.processInfo.environment["KAIBA_MEILISEARCH_URL"]
    try XCTSkipUnless(value != nil)
    return try XCTUnwrap(value)
  }

  private func livePrefix() -> String {
    "kaiba-test-\(String(UUID().uuidString.lowercased().prefix(8)))"
  }

  private func makeEngine(url: String, prefix: String) throws -> any SearchEngine {
    try XCTUnwrap(SearchEngineFactory.make(
      configuration: KaibaSearchEngineConfiguration(kind: "meilisearch", url: url, indexPrefix: prefix),
      environment: ProcessInfo.processInfo.environment
    ))
  }

  private func liveFilter(
    hierarchyTagIds: [TagID] = [],
    excludedNoteIds: [NoteID] = []
  ) -> SearchEngineFilter {
    SearchEngineFilter(
      libraryIds: [LibraryID("live-library")], ownerUserId: nil, notebookId: nil,
      tagIds: [], excludesLongTermMemory: false, excludedNoteIds: excludedNoteIds,
      hierarchyTagIds: hierarchyTagIds
    )
  }

  private func liveDocument(
    noteId: String,
    body: String,
    pathTags: [SearchIndexPathTag] = [],
    outgoing: [NoteID] = []
  ) -> SearchIndexDocument {
    SearchIndexDocument(
      noteId: NoteID(noteId), notebookId: NotebookID("live-notebook"), libraryId: LibraryID("live-library"),
      ownerUserId: nil, title: "Integration test", body: body,
      tagIds: pathTags.filter(\.isDirect).map(\.tagId), tagNames: pathTags.filter(\.isDirect).map(\.name), context: "",
      isLongTermMemory: false, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
      tagApplications: pathTags.filter(\.isDirect).map { SearchIndexTagApplication(tagId: $0.tagId, provenance: "human") },
      pathTags: pathTags, outgoingLinkNoteIds: outgoing
    )
  }

  private func deleteIndex(url: String, prefix: String) {
    guard let base = URL(string: url) else { return }
    var request = URLRequest(url: base.appendingPathComponent("indexes/\(prefix)-notes-v1"))
    request.httpMethod = "DELETE"
    let semaphore = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { _, _, _ in semaphore.signal() }.resume()
    _ = semaphore.wait(timeout: .now() + 5)
  }
}
