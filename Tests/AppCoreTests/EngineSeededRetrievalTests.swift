import Foundation
@testable import AppCore
import XCTest

final class EngineSeededRetrievalTests: NoteTestCase {
  func testNoEngineMatchesSearchNotesWithAndWithoutLinkedExpansion() async throws {
    let service = try makeService(function: #function)
    let direct = try service.createNote(
      bodyMarkdown: "# Retrieval alpha\nneedle planning",
      tags: [NoteTagInput(name: "retrieval-topic", classId: TagClassID("topic"))]
    )
    let neighbor = try service.createNote(bodyMarkdown: "# Retrieval neighbor\nrelated context")
    _ = try service.linkNotes(from: direct.noteId, to: neighbor.noteId)

    for includeLinked in [false, true] {
      let expected = try service.searchNotes(
        query: "needle",
        tagFilter: ["retrieval-topic"],
        classFilter: ["topic"],
        includeLinked: includeLinked,
        limit: 10
      )
      let outcome = try await service.retrieveNotes(
        query: "needle",
        tagFilter: ["retrieval-topic"],
        classFilter: ["topic"],
        includeLinked: includeLinked,
        limit: 10
      )
      XCTAssertEqual(outcome.results, expected)
      XCTAssertFalse(outcome.usedSearchEngine)
    }
  }

  func testNoEngineFallbackPreservesNotebookAndCreatedAtFilters() async throws {
    let service = try makeService(function: #function)
    let notebook = try service.createNotebook(title: "Retrieval scope")
    _ = try service.createNote(notebookId: notebook.notebookId, bodyMarkdown: "needle inside")
    _ = try service.createNote(bodyMarkdown: "needle outside")
    let expected = try service.searchNotes(
      query: "needle",
      notebookId: notebook.notebookId,
      createdAfter: "2000-01-01",
      createdBefore: "2999-12-31",
      limit: 10
    )

    let outcome = try await service.retrieveNotes(
      query: "needle",
      notebookId: notebook.notebookId,
      createdAfter: "2000-01-01",
      createdBefore: "2999-12-31",
      limit: 10
    )

    XCTAssertEqual(outcome.results, expected)
    XCTAssertFalse(outcome.usedSearchEngine)
  }

  func testEngineFailureReturnsExactFtsResults() async throws {
    let service = try makeService(function: #function)
    _ = try service.createNote(bodyMarkdown: "# Fallback\nengine failure needle")
    let engine = FakeSearchEngine()
    engine.failure = .unavailable("offline")
    let enabled = service
    enabled.searchEngine = engine
    let expected = try service.searchNotes(query: "needle", includeLinked: true)

    let outcome = try await enabled.retrieveNotes(query: "needle", includeLinked: true)

    XCTAssertEqual(outcome.results, expected)
    XCTAssertFalse(outcome.usedSearchEngine)
    XCTAssertTrue(engine.recordedSearches.isEmpty)
  }

  func testEmptyQueryZeroLimitAndOversizedWindowSkipEngine() async throws {
    let service = try makeService(function: #function)
    _ = try service.createNote(bodyMarkdown: "# Short circuit\nneedle")
    let engine = FakeSearchEngine()
    let enabled = service
    enabled.searchEngine = engine
    let emptyQuery = try await enabled.retrieveNotes(query: " \n ")
    XCTAssertEqual(emptyQuery.results, try service.searchNotes(query: " \n "))
    XCTAssertFalse(emptyQuery.usedSearchEngine)
    let zeroLimit = try await enabled.retrieveNotes(query: "needle", limit: 0)
    XCTAssertEqual(zeroLimit.results, try service.searchNotes(query: "needle", limit: 0))
    XCTAssertFalse(zeroLimit.usedSearchEngine)
    let oversized = try await enabled.retrieveNotes(query: "needle", limit: 20, offset: 990)
    XCTAssertEqual(oversized.results, try service.searchNotes(query: "needle", limit: 20, offset: 990))
    XCTAssertFalse(oversized.usedSearchEngine)
    XCTAssertTrue(engine.recordedSearches.isEmpty)
  }

  func testFusesEngineAndFullTextWithProvenanceAndHighlight() async throws {
    let service = try makeService(function: #function)
    let note = try service.createNote(bodyMarkdown: "# Shared\nneedle appears in the body")
    let engine = FakeSearchEngine()
    engine.scriptedHits = [SearchEngineHit(
      noteId: note.noteId,
      score: 4,
      highlight: "  engine excerpt  ",
      reasons: [SearchEngineHitReason(kind: .tagMatch, tagNames: ["topic"])]
    )]
    let enabled = service
    enabled.searchEngine = engine

    let outcome = try await enabled.retrieveNotes(query: "needle missingterm")

    let result = try XCTUnwrap(outcome.results.first)
    XCTAssertTrue(outcome.usedSearchEngine)
    XCTAssertEqual(outcome.results.map(\.note.noteId), [note.noteId])
    XCTAssertEqual(result.snippet, "engine excerpt")
    XCTAssertEqual(result.provenance?.sources, [.searchEngine, .fullText])
    XCTAssertEqual(result.provenance?.reasons, [.tagMatch])
    XCTAssertEqual(result.termCoverage, 0.5)
  }

  func testFtsSnippetWinsWhenEngineHighlightIsBlank() async throws {
    let service = try makeService(function: #function)
    let note = try service.createNote(bodyMarkdown: "# Snippet\nneedle inside the searchable text")
    let expected = try XCTUnwrap(try service.searchNotes(query: "needle").first?.snippet)
    let engine = FakeSearchEngine()
    engine.scriptedHits = [SearchEngineHit(noteId: note.noteId, score: 1, highlight: " \n ")]
    let enabled = service
    enabled.searchEngine = engine

    let outcome = try await enabled.retrieveNotes(query: "needle")

    XCTAssertEqual(outcome.results.first?.snippet, expected)
    XCTAssertTrue(outcome.usedSearchEngine)
  }

  func testEngineOnlyHitSeedsLinkedNeighborExpansion() async throws {
    let service = try makeService(function: #function)
    let seed = try service.createNote(bodyMarkdown: "# Engine seed\nbody has unrelated words")
    let neighbor = try service.createNote(bodyMarkdown: "# Linked context\nneighbor content")
    _ = try service.linkNotes(from: seed.noteId, to: neighbor.noteId)
    let engine = FakeSearchEngine()
    engine.scriptedHits = [SearchEngineHit(noteId: seed.noteId, score: 2, highlight: "query match")]
    let enabled = service
    enabled.searchEngine = engine

    let outcome = try await enabled.retrieveNotes(query: "unindexedquery", includeLinked: true, limit: 10)

    let direct = try XCTUnwrap(outcome.results.first { $0.note.noteId == seed.noteId })
    let linked = try XCTUnwrap(outcome.results.first { $0.note.noteId == neighbor.noteId })
    XCTAssertFalse(direct.isLinkedNeighbor)
    XCTAssertEqual(direct.provenance?.sources, [.searchEngine])
    XCTAssertTrue(linked.isLinkedNeighbor)
    XCTAssertEqual(linked.provenance?.sources, [.graphNeighbor])
    XCTAssertTrue(outcome.usedSearchEngine)
  }

  func testStoreRecheckDropsUnreachableDeletedAndDuplicateHits() async throws {
    let service = try makeService(function: #function)
    let hiddenLibrary = try service.createLibrary(name: "retrieval-hidden", authRequired: true)
    let hidden = try service.scoped(toLibrary: hiddenLibrary.libraryId).createNote(bodyMarkdown: "hidden")
    let visible = try service.createNote(bodyMarkdown: "visible")
    let deleted = try service.createNote(bodyMarkdown: "deleted")
    try service.deleteNote(noteId: deleted.noteId)
    let engine = FakeSearchEngine()
    engine.scriptedHits = [
      SearchEngineHit(noteId: hidden.noteId, score: 4, highlight: nil),
      SearchEngineHit(noteId: visible.noteId, score: 3, highlight: nil),
      SearchEngineHit(noteId: visible.noteId, score: 2, highlight: nil),
      SearchEngineHit(noteId: deleted.noteId, score: 1, highlight: nil),
      SearchEngineHit(noteId: NoteID("missing-retrieval-note"), score: 0, highlight: nil)
    ]
    let anonymous = service.scoped(to: NoteStoreSchema.defaultUserId).unauthenticated()
    anonymous.searchEngine = engine

    let outcome = try await anonymous.retrieveNotes(query: "scripted", limit: 10)

    XCTAssertEqual(outcome.results.map(\.note.noteId), [visible.noteId])
    XCTAssertEqual(outcome.results.first?.provenance?.sources, [.searchEngine])
    XCTAssertTrue(outcome.usedSearchEngine)
  }

  func testStoreRecheckAppliesOwnerAndLongTermMemoryScope() async throws {
    let service = try makeService(function: #function)
    let alice = try service.createUser(email: "retrieval-alice@example.com", displayName: "Alice")
    let bob = try service.createUser(email: "retrieval-bob@example.com", displayName: "Bob")
    let aliceNotebook = try service.scoped(to: alice.userId).createNotebook(title: "Alice retrieval")
    let bobNotebook = try service.scoped(to: bob.userId).createNotebook(title: "Bob retrieval")
    let aliceNote = try service.scoped(to: alice.userId).createNote(
      notebookId: aliceNotebook.notebookId,
      bodyMarkdown: "alice"
    )
    let bobNote = try service.scoped(to: bob.userId).createNote(
      notebookId: bobNotebook.notebookId,
      bodyMarkdown: "bob"
    )
    let memory = try XCTUnwrap(try service.appendLongTermMemoryNotes(
      [LongTermMemoryEntryInput(bodyMarkdown: "private memory")],
      idempotencyKey: "engine-seeded-retrieval-memory"
    ).notes.first)
    let engine = FakeSearchEngine()
    engine.scriptedHits = [
      SearchEngineHit(noteId: bobNote.noteId, score: 3, highlight: nil),
      SearchEngineHit(noteId: memory.noteId, score: 2, highlight: nil),
      SearchEngineHit(noteId: aliceNote.noteId, score: 1, highlight: nil)
    ]
    let scoped = service.scoped(to: alice.userId)
    scoped.searchEngine = engine

    let outcome = try await scoped.retrieveNotes(query: "scripted", limit: 10)

    XCTAssertEqual(outcome.results.map(\.note.noteId), [aliceNote.noteId])
    XCTAssertTrue(outcome.usedSearchEngine)

    let ownerNote = try service.scoped(to: NoteStoreSchema.defaultUserId).createNote(bodyMarkdown: "owner")
    engine.scriptedHits = [
      SearchEngineHit(noteId: memory.noteId, score: 2, highlight: nil),
      SearchEngineHit(noteId: ownerNote.noteId, score: 1, highlight: nil)
    ]
    let memoryOwner = service.scoped(to: NoteStoreSchema.defaultUserId)
    memoryOwner.searchEngine = engine
    let ownerOutcome = try await memoryOwner.retrieveNotes(query: "scripted", limit: 10)
    XCTAssertEqual(ownerOutcome.results.map(\.note.noteId), [ownerNote.noteId])
    XCTAssertTrue(ownerOutcome.usedSearchEngine)

    let nilUser = service.unauthenticated()
    nilUser.searchEngine = engine
    let nilUserOutcome = try await nilUser.retrieveNotes(query: "scripted", limit: 10)
    XCTAssertEqual(nilUserOutcome.results.map(\.note.noteId), [ownerNote.noteId])
    XCTAssertTrue(nilUserOutcome.usedSearchEngine)
  }

  func testStoreRecheckDropsPendingNotebookIngestNotes() async throws {
    let service = try makeService(function: #function)
    let claim = try service.claimNotebookIngestRequest(
      idempotencyKey: "engine-seeded-pending-ingest",
      canonicalRequest: Data("pending retrieval".utf8)
    )
    guard case let .execute(identity) = claim else { return XCTFail("expected a new ingest claim") }
    let pending = try service.pendingNotebookIngestScope().createNotebookWithNotes(
      title: "Pending retrieval notebook",
      metaJSON: try service.pendingNotebookIngestMetadata(callerMetadataJSON: nil, identity: identity),
      pages: [NotePageDraft(bodyMarkdown: "pending engine result", readOnly: false)],
      autoActionPolicy: .deferredUntilFinalized
    )
    let pendingNote = try XCTUnwrap(pending.notes.first)
    let engine = FakeSearchEngine()
    engine.scriptedHits = [SearchEngineHit(noteId: pendingNote.noteId, score: 1, highlight: nil)]
    let enabled = service
    enabled.searchEngine = engine

    let outcome = try await enabled.retrieveNotes(query: "scripted", limit: 10)

    XCTAssertTrue(outcome.results.isEmpty)
    XCTAssertTrue(outcome.usedSearchEngine)
  }

  func testStoreRecheckAppliesTagClassAndDateFilters() async throws {
    let service = try makeService(function: #function)
    _ = try service.defineTagClass(classId: TagClassID("status"), label: "Status")
    let tagged = try service.createNote(
      bodyMarkdown: "allowed content",
      tags: [NoteTagInput(name: "retrieval-allowed", classId: TagClassID("topic"))]
    )
    let sameClass = try service.createNote(
      bodyMarkdown: "sibling content",
      tags: [NoteTagInput(name: "retrieval-sibling", classId: TagClassID("topic"))]
    )
    let untagged = try service.createNote(bodyMarkdown: "untagged content")
    let wrongClass = try service.createNote(
      bodyMarkdown: "wrong class content",
      tags: [NoteTagInput(name: "retrieval-other", classId: TagClassID("status"))]
    )
    let engine = FakeSearchEngine()
    engine.scriptedHits = [tagged, sameClass, untagged, wrongClass].map {
      SearchEngineHit(noteId: $0.noteId, score: 1, highlight: nil)
    }
    let enabled = service
    enabled.searchEngine = engine

    let filtered = try await enabled.retrieveNotes(
      query: "scripted",
      tagFilter: ["retrieval-allowed"],
      classFilter: ["topic"],
      limit: 10
    )
    XCTAssertEqual(filtered.results.map(\.note.noteId), [tagged.noteId])
    XCTAssertTrue(filtered.usedSearchEngine)

    let tagOnly = try await enabled.retrieveNotes(
      query: "scripted",
      tagFilter: ["retrieval-allowed"],
      limit: 10
    )
    XCTAssertEqual(tagOnly.results.map(\.note.noteId), [tagged.noteId])
    XCTAssertTrue(tagOnly.usedSearchEngine)

    let classOnly = try await enabled.retrieveNotes(query: "scripted", classFilter: ["topic"], limit: 10)
    XCTAssertEqual(Set(classOnly.results.map(\.note.noteId)), Set([tagged.noteId, sameClass.noteId]))
    XCTAssertTrue(classOnly.usedSearchEngine)

    let dated = try await enabled.retrieveNotes(query: "scripted", createdAfter: "2999-01-01", limit: 10)
    XCTAssertTrue(dated.results.isEmpty)
    XCTAssertTrue(dated.usedSearchEngine)
  }

  func testEngineRequestOverfetchesAndCapsAtTwoHundred() async throws {
    let service = try makeService(function: #function)
    let engine = FakeSearchEngine()
    engine.scriptedHits = []
    let enabled = service
    enabled.searchEngine = engine

    let small = try await enabled.retrieveNotes(query: "size", limit: 10)
    let large = try await enabled.retrieveNotes(query: "size", limit: 200, offset: 100)

    XCTAssertEqual(engine.recordedSearches.map(\.size), [30, 200])
    XCTAssertTrue(small.usedSearchEngine)
    XCTAssertTrue(large.usedSearchEngine)
  }

  func testEmptyReachabilitySkipsEngine() async throws {
    let service = try makeService(function: #function)
    let user = try service.createUser(email: "retrieval-no-library@example.com", displayName: "No library")
    let unreachable = service.scoped(to: user.userId).scoped(toLibrary: LibraryID("missing-retrieval-library"))
    let engine = FakeSearchEngine()
    unreachable.searchEngine = engine

    let outcome = try await unreachable.retrieveNotes(query: "needle")

    XCTAssertFalse(outcome.usedSearchEngine)
    XCTAssertTrue(engine.recordedSearches.isEmpty)
  }
}
