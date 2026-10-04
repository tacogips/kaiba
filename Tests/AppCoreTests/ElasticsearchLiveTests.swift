import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AppCore

final class ElasticsearchLiveTests: XCTestCase {
  private final class ReloadFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func record(_ error: Error) {
      lock.withLock { stored.append(String(describing: error)) }
    }

    var messages: [String] { lock.withLock { stored } }
  }

  func testLiveIndexSearchRelatedAndDelete() async throws {
    let configuredURL = ProcessInfo.processInfo.environment["KAIBA_ELASTICSEARCH_URL"]
    try XCTSkipUnless(configuredURL != nil)
    let url = try XCTUnwrap(configuredURL)
    let prefix = "kaiba-test-\(String(UUID().uuidString.lowercased().prefix(8)))"
    let configuration = KaibaSearchEngineConfiguration(kind: "elasticsearch", url: url, indexPrefix: prefix)
    let engine = try XCTUnwrap(SearchEngineFactory.make(configuration: configuration, environment: ProcessInfo.processInfo.environment))
    let indexName = "\(prefix)-notes-v2"
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

  func testLiveOntologySearch() async throws {
    let configuredURL = ProcessInfo.processInfo.environment["KAIBA_ELASTICSEARCH_URL"]
    try XCTSkipUnless(configuredURL != nil)
    let url = try XCTUnwrap(configuredURL)
    let prefix = "kaiba-test-ontology-\(String(UUID().uuidString.lowercased().prefix(8)))"
    let engine = try XCTUnwrap(SearchEngineFactory.make(
      configuration: KaibaSearchEngineConfiguration(kind: "elasticsearch", url: url, indexPrefix: prefix),
      environment: ProcessInfo.processInfo.environment
    ))
    let indexName = "\(prefix)-notes-v2"
    defer { deleteIndex(url: url, indexName: indexName) }

    try await engine.ensureIndex()
    let parent = SearchIndexPathTag(tagId: TagID("parent"), name: "parent", tagClass: "topic", isDirect: false)
    let child = SearchIndexPathTag(tagId: TagID("child"), name: "child", tagClass: "person", isDirect: true)
    let d1 = liveDocument(noteId: "ontology-d1", body: "alpha", pathTags: [parent, child])
    let d2 = liveDocument(
      noteId: "ontology-d2", body: "parent alpha",
      pathTags: [SearchIndexPathTag(tagId: TagID("other"), name: "other", tagClass: "topic", isDirect: true)]
    )
    let d3 = liveDocument(noteId: "ontology-d3", body: "zzz")
    let operations = try await engine.apply([.upsert(d1), .upsert(d2), .upsert(d3)])
    XCTAssertEqual(operations.map(\.outcome), [.succeeded, .succeeded, .succeeded])
    try await refresh(url: url, indexName: indexName)

    let filter = SearchEngineFilter(
      libraryIds: [LibraryID("live-library")], ownerUserId: nil, notebookId: nil,
      tagIds: [], excludesLongTermMemory: false, excludedNoteIds: [], hierarchyTagIds: [TagID("parent")]
    )
    let hierarchyHits = try await engine.search(SearchEngineQuery(text: "alpha", filter: filter, from: 0, size: 10))
    XCTAssertTrue(hierarchyHits.contains { $0.noteId == NoteID("ontology-d1") })
    XCTAssertFalse(hierarchyHits.contains { $0.noteId == NoteID("ontology-d2") })

    var classFilter = filter
    classFilter.hierarchyTagIds = []
    classFilter.tagClassFilters = [SearchEngineTagClassFilter(tagClass: "person")]
    let classHits = try await engine.search(SearchEngineQuery(text: "alpha", filter: classFilter, from: 0, size: 10))
    XCTAssertEqual(classHits.map(\.noteId), [NoteID("ontology-d1")])

    let expansion = try await engine.search(SearchEngineQuery(
      text: "parent", filter: SearchEngineFilter(
        libraryIds: [LibraryID("live-library")], ownerUserId: nil, notebookId: nil,
        tagIds: [], excludesLongTermMemory: false, excludedNoteIds: []
      ), from: 0, size: 10, expansionTagIds: [TagID("parent")]
    ))
    XCTAssertTrue(expansion.contains { $0.noteId == NoteID("ontology-d1") })
    XCTAssertTrue(expansion.contains { $0.noteId == NoteID("ontology-d2") })

    let faceted = try await engine.searchPage(SearchEngineQuery(
      text: "alpha", filter: SearchEngineFilter(
        libraryIds: [LibraryID("live-library")], ownerUserId: nil, notebookId: nil,
        tagIds: [], excludesLongTermMemory: false, excludedNoteIds: []
      ), from: 0, size: 10, facets: SearchEngineFacetRequest()
    ))
    XCTAssertTrue(faceted.facets?.tagClasses.contains {
      $0.value == "person" && $0.count == 1
    } == true)
  }

  func testLiveRelatedReasons() async throws {
    let configuredURL = ProcessInfo.processInfo.environment["KAIBA_ELASTICSEARCH_URL"]
    try XCTSkipUnless(configuredURL != nil)
    let url = try XCTUnwrap(configuredURL)
    let prefix = "kaiba-test-related-\(String(UUID().uuidString.lowercased().prefix(8)))"
    let engine = try XCTUnwrap(SearchEngineFactory.make(
      configuration: KaibaSearchEngineConfiguration(kind: "elasticsearch", url: url, indexPrefix: prefix),
      environment: ProcessInfo.processInfo.environment
    ))
    let indexName = "\(prefix)-notes-v2"
    defer { deleteIndex(url: url, indexName: indexName) }

    try await engine.ensureIndex()
    let shared = SearchIndexPathTag(tagId: TagID("shared-person"), name: "Alice", tagClass: "person", isDirect: true)
    let source = liveDocument(noteId: "related-source", body: "unique common astronomy text", pathTags: [shared])
    let linked = liveDocument(noteId: "related-linked", body: "unrelated", outgoing: [NoteID("related-source")])
    let sharedTag = liveDocument(noteId: "related-shared", body: "unrelated", pathTags: [shared])
    let textOnly = liveDocument(noteId: "related-text", body: "unique common astronomy text")
    _ = try await engine.apply([.upsert(source), .upsert(linked), .upsert(sharedTag), .upsert(textOnly)])
    try await refresh(url: url, indexName: indexName)

    let filter = SearchEngineFilter(
      libraryIds: [LibraryID("live-library")], ownerUserId: nil, notebookId: nil,
      tagIds: [], excludesLongTermMemory: false, excludedNoteIds: [NoteID("related-source")]
    )
    let results = try await engine.relatedNotes(SearchEngineRelatedQuery(
      likeText: "unique common astronomy text", filter: filter, size: 10,
      signals: SearchEngineRelatedSignals(
        sourceNoteId: NoteID("related-source"), sharedTagIds: [TagID("shared-person")],
        nearTagIds: [], ancestorTagIds: [],
        entityTags: [SearchEngineClassTag(tagClass: "person", tagId: TagID("shared-person"))]
      )
    ))
    XCTAssertFalse(results.contains { $0.noteId == NoteID("related-source") })
    XCTAssertTrue(try XCTUnwrap(results.first { $0.noteId == NoteID("related-linked") })
      .reasons.contains { $0.kind == .linked })
    let sharedReasons = try XCTUnwrap(results.first { $0.noteId == NoteID("related-shared") }).reasons
    XCTAssertTrue(sharedReasons.contains { $0.kind == .sharedTag })
    XCTAssertTrue(sharedReasons.contains { $0.kind == .sharedEntity })
    XCTAssertTrue(try XCTUnwrap(results.first { $0.noteId == NoteID("related-text") })
      .reasons.contains { $0.kind == .textSimilarity })
  }

  func testLiveSettingsHotSwap() async throws {
    let configuredURL = ProcessInfo.processInfo.environment["KAIBA_ELASTICSEARCH_URL"]
    try XCTSkipUnless(configuredURL != nil)
    let url = try XCTUnwrap(configuredURL)
    let unique = String(UUID().uuidString.lowercased().prefix(8))
    let prefixA = "kaiba-test-settings-a-\(unique)"
    let prefixB = "kaiba-test-settings-b-\(unique)"
    defer {
      deleteIndex(url: url, indexName: "\(prefixA)-notes-v2")
      deleteIndex(url: url, indexName: "\(prefixB)-notes-v2")
    }

    let service = try makeService(function: #function)
    let slot = service.searchEngineSlot
    let reloadFailures = ReloadFailures()
    slot.setEnvironment(ProcessInfo.processInfo.environment)
    slot.setReloadHandler {
      do {
        guard let engine = try service.makeResolvedSearchEngine(
          configuration: nil, environment: ProcessInfo.processInfo.environment
        ) else {
          slot.replace(nil)
          return SearchEngineReloadOutcome(active: false, indexIdentity: nil)
        }
        slot.replace(engine)
        try await engine.ensureIndex()
        _ = try service.activateSearchEngineSync(indexIdentity: engine.indexIdentity)
        _ = try await SearchIndexSynchronizer(service: service).drainUntilIdle(engine: engine)
        return SearchEngineReloadOutcome(active: true, indexIdentity: engine.indexIdentity)
      } catch {
        reloadFailures.record(error)
        return SearchEngineReloadOutcome(active: false, indexIdentity: nil)
      }
    }
    _ = try service.createNote(bodyMarkdown: "p21 hot swap integration needle alpha")
    _ = try service.createNote(bodyMarkdown: "p21 hot swap integration needle beta")

    let first = try await service.updateSearchEngineSettings(SearchEngineSettingsInput(
      kind: "elasticsearch", url: url, indexPrefix: prefixA, authMode: "none"
    ))
    XCTAssertTrue(first.active)
    XCTAssertEqual(first.indexPrefix, prefixA)
    let second = try await service.updateSearchEngineSettings(SearchEngineSettingsInput(
      kind: "elasticsearch", url: url, indexPrefix: prefixB, authMode: "none"
    ))
    XCTAssertTrue(second.active)
    XCTAssertEqual(second.indexPrefix, prefixB)
    XCTAssertTrue(reloadFailures.messages.isEmpty, reloadFailures.messages.joined(separator: "; "))
    try await refresh(url: url, indexName: "\(prefixB)-notes-v2")

    let engine = try XCTUnwrap(service.searchEngine)
    let hits = try await engine.search(SearchEngineQuery(
      text: "integration", filter: SearchEngineFilter(
        libraryIds: nil, ownerUserId: nil, notebookId: nil, tagIds: [],
        excludesLongTermMemory: false, excludedNoteIds: []
      ), from: 0, size: 10
    ))
    XCTAssertEqual(hits.count, 2)

    let disabled = try await service.updateSearchEngineSettings(SearchEngineSettingsInput(kind: "none"))
    XCTAssertFalse(disabled.active)
    XCTAssertNil(service.searchEngine)
    do {
      _ = try await service.engineSearchNotes(query: "integration")
      XCTFail("disabled settings should make engine search unavailable")
    } catch {
      XCTAssertEqual(error as? SearchEngineError, .notConfigured)
    }
    XCTAssertTrue(reloadFailures.messages.isEmpty, reloadFailures.messages.joined(separator: "; "))
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
