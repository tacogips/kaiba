import Foundation
import XCTest
@testable import AppCore

private struct LegacySearchEngine: SearchEngine {
  var indexIdentity: String { "legacy:v1" }

  func health() async throws -> SearchEngineHealth {
    SearchEngineHealth(isAvailable: true, detail: "legacy")
  }

  func ensureIndex() async throws {}

  func apply(_ operations: [SearchIndexOperation]) async throws -> [SearchIndexOperationResult] {
    operations.map { SearchIndexOperationResult(noteId: $0.noteId, outcome: .succeeded) }
  }

  func search(_ query: SearchEngineQuery) async throws -> [SearchEngineHit] {
    [SearchEngineHit(noteId: NoteID("legacy-note"), score: 1, highlight: nil)]
  }

  func relatedNotes(_ query: SearchEngineRelatedQuery) async throws -> [SearchEngineHit] { [] }
}

final class SearchEngineDeltaContractTests: NoteTestCase {
  func testLegacyDefaultsAndSearchPageProtocolFallback() async throws {
    let document = SearchIndexDocument(
      noteId: NoteID("legacy-note"), notebookId: NotebookID("notebook"), libraryId: LibraryID("library"),
      ownerUserId: nil, title: "title", body: "body", tagIds: [], tagNames: [], context: "",
      isLongTermMemory: false, createdAt: "created", updatedAt: "updated"
    )
    XCTAssertTrue(document.tagApplications.isEmpty)
    XCTAssertTrue(document.pathTags.isEmpty)
    XCTAssertTrue(document.outgoingLinkNoteIds.isEmpty)
    XCTAssertTrue(document.incomingLinkNoteIds.isEmpty)

    let filter = SearchEngineFilter(
      libraryIds: nil, ownerUserId: nil, notebookId: nil, tagIds: [],
      excludesLongTermMemory: false, excludedNoteIds: []
    )
    XCTAssertTrue(filter.hierarchyTagIds.isEmpty)
    XCTAssertTrue(filter.tagClassFilters.isEmpty)
    let query = SearchEngineQuery(text: "text", filter: filter, from: 0, size: 10)
    XCTAssertTrue(query.expansionTagIds.isEmpty)
    XCTAssertNil(query.facets)

    let page = try await LegacySearchEngine().searchPage(query)
    XCTAssertEqual(page.hits.map(\.noteId), [NoteID("legacy-note")])
    XCTAssertNil(page.facets)
    XCTAssertEqual(SearchEngineFacetRequest().tagClassLimit, 10)
    XCTAssertEqual(SearchEngineFacetRequest().tagLimit, 15)
  }

  func testSearchEngineSlotIsSharedByScopedCopiesAndIsolatedAcrossServices() throws {
    let first = try makeService(function: "testSearchEngineSlotFirst")
    let scoped = first.scoped(to: NoteStoreSchema.defaultUserId)
    first.searchEngine = FakeSearchEngine()
    XCTAssertTrue(scoped.isSearchEngineEnabled)

    let second = try makeService(function: "testSearchEngineSlotSecond")
    XCTAssertNil(second.searchEngine)
  }

  func testSearchEngineSlotReloadCopiesHandlerBeforeAwaiting() async {
    let slot = SearchEngineSlot()
    let noHandlerResult = await slot.reload()
    XCTAssertNil(noHandlerResult)
    let expected = SearchEngineReloadOutcome(active: true, indexIdentity: "x")
    slot.setReloadHandler { expected }
    let handlerResult = await slot.reload()
    XCTAssertEqual(handlerResult, expected)
  }

  func testSettingsInputDescriptionsRedactSecretAndReasonKindsArePinned() {
    let input = SearchEngineSettingsInput(kind: "elasticsearch", secret: "s3cr3t")
    XCTAssertFalse(String(describing: input).contains("s3cr3t"))
    XCTAssertFalse(String(reflecting: input).contains("s3cr3t"))
    XCTAssertTrue(String(describing: input).contains("[redacted]"))

    let reasonKinds: [SearchEngineHitReasonKind] = [
      .textMatch, .tagMatch, .tagHierarchyMatch, .textSimilarity,
      .sharedTag, .relatedTag, .sharedEntity, .linked
    ]
    XCTAssertEqual(
      reasonKinds.map(\.rawValue),
      ["text-match", "tag-match", "tag-hierarchy-match", "text-similarity", "shared-tag", "related-tag", "shared-entity", "linked"]
    )
  }

  func testFakeSearchPageRecordsQueriesPreservesReasonsAndReturnsRequestedFacets() async throws {
    let engine = FakeSearchEngine()
    let hit = SearchEngineHit(
      noteId: NoteID("scripted"), score: 1, highlight: nil,
      reasons: [SearchEngineHitReason(kind: .tagMatch)]
    )
    let facets = SearchEngineFacets(
      tagClasses: [SearchEngineFacetBucket(value: "person", count: 2)],
      tags: [SearchEngineFacetBucket(value: "tag-person", count: 2)]
    )
    engine.scriptedHits = [hit]
    engine.scriptedFacets = facets
    let filter = SearchEngineFilter(
      libraryIds: nil, ownerUserId: nil, notebookId: nil, tagIds: [],
      excludesLongTermMemory: false, excludedNoteIds: []
    )
    let withFacets = SearchEngineQuery(text: "unused", filter: filter, from: 0, size: 10, facets: SearchEngineFacetRequest())
    let firstPage = try await engine.searchPage(withFacets)
    XCTAssertEqual(firstPage.hits, [hit])
    XCTAssertEqual(firstPage.facets, facets)
    XCTAssertEqual(engine.recordedSearches, [withFacets])
    XCTAssertEqual(engine.recordedSearchPages, [withFacets])

    engine.scriptedHits = nil
    let withoutFacets = SearchEngineQuery(text: "unused", filter: filter, from: 0, size: 10)
    let secondPage = try await engine.searchPage(withoutFacets)
    XCTAssertTrue(secondPage.hits.isEmpty)
    XCTAssertNil(secondPage.facets)
    XCTAssertEqual(engine.recordedSearches.count, 2)
    XCTAssertEqual(engine.recordedSearchPages.count, 2)

    let failing = FakeSearchEngine()
    failing.failure = .unavailable("offline")
    do {
      _ = try await failing.searchPage(withFacets)
      XCTFail("expected search failure")
    } catch {
      XCTAssertEqual(error as? SearchEngineError, .unavailable("offline"))
    }
    XCTAssertTrue(failing.recordedSearches.isEmpty)
    XCTAssertTrue(failing.recordedSearchPages.isEmpty)
  }

  func testFakeSearchEngineMatchesHierarchyAndClassFiltersInPathTags() async throws {
    let engine = FakeSearchEngine()
    let ancestor = TagID("ancestor")
    let personTag = TagID("person-tag")
    let pathTags = [
      SearchIndexPathTag(tagId: ancestor, name: "People", tagClass: nil, isDirect: false),
      SearchIndexPathTag(tagId: personTag, name: "Ari", tagClass: "person", isDirect: true)
    ]
    let document = SearchIndexDocument(
      noteId: NoteID("tagged"), notebookId: NotebookID("notebook"), libraryId: LibraryID("library"),
      ownerUserId: nil, title: "needle", body: "", tagIds: [], tagNames: [], context: "",
      isLongTermMemory: false, createdAt: "created", updatedAt: "updated", pathTags: pathTags
    )
    _ = try await engine.apply([.upsert(document)])

    func query(hierarchyTagIds: [TagID] = [], tagClassFilters: [SearchEngineTagClassFilter] = []) -> SearchEngineQuery {
      SearchEngineQuery(
        text: "needle",
        filter: SearchEngineFilter(
          libraryIds: nil, ownerUserId: nil, notebookId: nil, tagIds: [],
          excludesLongTermMemory: false, excludedNoteIds: [],
          hierarchyTagIds: hierarchyTagIds, tagClassFilters: tagClassFilters
        ),
        from: 0,
        size: 10
      )
    }

    let ancestorHits = try await engine.search(query(hierarchyTagIds: [ancestor]))
    XCTAssertEqual(ancestorHits.map(\.noteId), [document.noteId])
    let unrelatedHits = try await engine.search(query(hierarchyTagIds: [TagID("other")]))
    XCTAssertTrue(unrelatedHits.isEmpty)
    let personHits = try await engine.search(
      query(tagClassFilters: [SearchEngineTagClassFilter(tagClass: "person", tagId: personTag)])
    )
    XCTAssertEqual(
      personHits.map(\.noteId),
      [document.noteId]
    )
    let eventHits = try await engine.search(query(tagClassFilters: [SearchEngineTagClassFilter(tagClass: "event")]))
    XCTAssertTrue(eventHits.isEmpty)
  }
}
