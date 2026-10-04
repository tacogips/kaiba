import Foundation
import Testing
@testable import AppCore

private func searchDocument(
  _ id: String,
  library: String = "library-a",
  text: String = "Cedar notebook content",
  tagIds: [TagID] = [],
  owner: UserID? = nil,
  notebook: String = "notebook-a",
  longTermMemory: Bool = false
) -> SearchIndexDocument {
  SearchIndexDocument(
    noteId: NoteID(id),
    notebookId: NotebookID(notebook),
    libraryId: LibraryID(library),
    ownerUserId: owner,
    title: text,
    body: "",
    tagIds: tagIds,
    tagNames: [],
    context: "",
    isLongTermMemory: longTermMemory,
    createdAt: "2026-01-01T00:00:00Z",
    updatedAt: "2026-01-01T00:00:00Z"
  )
}

private let unrestrictedSearchFilter = SearchEngineFilter(
  libraryIds: nil,
  ownerUserId: nil,
  notebookId: nil,
  tagIds: [],
  excludesLongTermMemory: false,
  excludedNoteIds: []
)

@Test func fakeSearchEngineAppliesUpsertDeleteAndReportsOrderedResults() async throws {
  let engine = FakeSearchEngine()
  let first = searchDocument("note-a")
  let missing = NoteID("note-missing")
  let results = try await engine.apply([.upsert(first), .delete(missing)])

  #expect(results == [
    SearchIndexOperationResult(noteId: first.noteId, outcome: .succeeded),
    SearchIndexOperationResult(noteId: missing, outcome: .succeeded)
  ])
  #expect(engine.documents == [first.noteId: first])
  #expect(try await engine.upsert(searchDocument("note-b")).outcome == .succeeded)
  #expect(try await engine.delete(noteId: first.noteId).outcome == .succeeded)
  #expect(engine.appliedBatches.count == 3)
  #expect(engine.appliedBatches[1].count == 1)
  #expect(engine.appliedBatches[2] == [.delete(first.noteId)])
}

@Test func fakeSearchEngineHonorsFilterSemanticsAndSorts() async throws {
  let engine = FakeSearchEngine()
  let documents = [
    searchDocument("note-c", library: "library-b", tagIds: [TagID("tag-c")]),
    searchDocument("note-a", library: "library-a", tagIds: [TagID("tag-a")]),
    searchDocument("note-b", library: "library-a", tagIds: [TagID("tag-b")], longTermMemory: true)
  ]
  _ = try await engine.apply(documents.map(SearchIndexOperation.upsert))

  let none = SearchEngineFilter(
    libraryIds: [], ownerUserId: nil, notebookId: nil, tagIds: [],
    excludesLongTermMemory: false, excludedNoteIds: []
  )
  let allLibraries = SearchEngineQuery(text: "CEDAR", filter: unrestrictedSearchFilter, from: 0, size: 10)
  let noLibraries = SearchEngineQuery(text: "cedar", filter: none, from: 0, size: 10)
  #expect(try await engine.search(allLibraries).map(\.noteId) == [NoteID("note-a"), NoteID("note-b"), NoteID("note-c")])
  #expect(try await engine.search(noLibraries).isEmpty)

  let scoped = SearchEngineFilter(
    libraryIds: [LibraryID("library-a")], ownerUserId: nil, notebookId: nil,
    tagIds: [TagID("tag-c"), TagID("tag-a")], excludesLongTermMemory: true,
    excludedNoteIds: [NoteID("note-a")]
  )
  let scopedQuery = SearchEngineQuery(text: "cedar", filter: scoped, from: 0, size: 10)
  #expect(try await engine.search(scopedQuery).isEmpty)
}

@Test func fakeSearchEngineReturnsScriptedHitsVerbatimAndExposesFailureKnobs() async throws {
  let engine = FakeSearchEngine()
  let hit = SearchEngineHit(noteId: NoteID("outside-scope"), score: 7, highlight: "scripted")
  engine.scriptedHits = [hit]
  let restrictive = SearchEngineQuery(
    text: "absent",
    filter: SearchEngineFilter(
      libraryIds: [], ownerUserId: nil, notebookId: nil, tagIds: [],
      excludesLongTermMemory: true, excludedNoteIds: [hit.noteId]
    ),
    from: 99,
    size: 0
  )
  #expect(try await engine.search(restrictive) == [hit])
  #expect(try await engine.relatedNotes(SearchEngineRelatedQuery(
    likeText: "", filter: restrictive.filter, size: 0
  )) == [hit])

  engine.failure = .unavailable("offline")
  await #expect(throws: SearchEngineError.unavailable("offline")) { try await engine.health() }
  engine.failure = nil
  engine.failingNoteIds = [NoteID("fail")]
  let failedDocument = searchDocument("fail")
  let result = try await engine.apply([.upsert(failedDocument)])
  #expect(result == [SearchIndexOperationResult(noteId: failedDocument.noteId, outcome: .failed("fake failure"))])
  #expect(engine.documents[failedDocument.noteId] == nil)
}

@Test func fakeSearchEngineRelatedMatchesSharedTokensAndHonorsExclusions() async throws {
  let engine = FakeSearchEngine()
  _ = try await engine.apply([
    .upsert(searchDocument("note-a", text: "Cedar trees grow")),
    .upsert(searchDocument("note-b", text: "cedar trees")),
    .upsert(searchDocument("note-c", text: "oak leaves"))
  ])
  var filter = unrestrictedSearchFilter
  filter.excludedNoteIds = [NoteID("note-a")]
  let hits = try await engine.relatedNotes(SearchEngineRelatedQuery(likeText: "CEDAR trees", filter: filter, size: 10))
  #expect(hits.map(\.noteId) == [NoteID("note-b")])
}

@Test func searchEngineErrorDescriptionsAreFixedAndSanitized() {
  let cases: [(SearchEngineError, String)] = [
    (.notConfigured, "search engine is not configured"),
    (.unavailable("offline"), "search engine unavailable: offline"),
    (.rejected(status: 503, reason: "busy"), "search engine rejected the request (HTTP 503): busy"),
    (.invalidResponse("bad json"), "search engine returned an invalid response: bad json")
  ]
  for (error, expected) in cases {
    #expect(error.description == expected)
    #expect(!error.description.contains("Authorization"))
    #expect(!error.description.contains("@"))
  }
}
