import Foundation
@testable import AppCore
import XCTest

final class SearchEngineAccessTests: NoteTestCase {
  func testUnauthenticatedResultsRecheckLibraryReachability() async throws {
    let service = try makeService(function: #function)
    let closed = try service.createLibrary(name: "engine-private", authRequired: true)
    let privateNote = try service.scoped(toLibrary: closed.libraryId).createNote(bodyMarkdown: "private")
    let publicNote = try service.createNote(bodyMarkdown: "public")
    let engine = FakeSearchEngine()
    engine.scriptedHits = [
      SearchEngineHit(noteId: privateNote.noteId, score: 2, highlight: nil),
      SearchEngineHit(noteId: publicNote.noteId, score: 1, highlight: nil)
    ]
    var anonymous = service.scoped(to: NoteStoreSchema.defaultUserId).unauthenticated()
    anonymous.searchEngine = engine

    let results = try await anonymous.engineSearchNotes(query: "ignored by scripted engine")
    XCTAssertEqual(results.map(\.note.noteId), [publicNote.noteId])
    XCTAssertEqual(engine.recordedSearches[0].filter.libraryIds, [NoteStoreSchema.defaultLibraryId])
    XCTAssertTrue(engine.recordedSearches[0].filter.excludesLongTermMemory)
  }

  func testOwnerNotebookAndCreatedRangeAreRechecked() async throws {
    let service = try makeService(function: #function)
    let alice = try service.createUser(email: "engine-alice@example.com", displayName: "Alice")
    let aliceService = service.scoped(to: alice.userId)
    let aliceNotebook = try aliceService.createNotebook(title: "Alice engine notebook")
    let bob = try service.createUser(email: "engine-bob@example.com", displayName: "Bob")
    let bobNotebook = try service.scoped(to: bob.userId).createNotebook(title: "Bob engine notebook")
    let aliceNote = try aliceService.createNote(notebookId: aliceNotebook.notebookId, bodyMarkdown: "alice marker")
    let bobNote = try service.scoped(to: bob.userId).createNote(notebookId: bobNotebook.notebookId, bodyMarkdown: "bob marker")
    let engine = FakeSearchEngine()
    engine.scriptedHits = [
      SearchEngineHit(noteId: bobNote.noteId, score: 2, highlight: nil),
      SearchEngineHit(noteId: aliceNote.noteId, score: 1, highlight: nil)
    ]
    var enabled = aliceService
    enabled.searchEngine = engine

    let results = try await enabled.engineSearchNotes(query: "ignored by scripted engine")
    XCTAssertEqual(results.map(\.note.noteId), [aliceNote.noteId])
    XCTAssertEqual(engine.recordedSearches[0].filter.ownerUserId, alice.userId)

    let datedIds = try service.driver.withDatabase { database in
      try scopedNoteIds(
        [aliceNote.noteId, bobNote.noteId],
        scope: NoteSearchScope(createdAfter: "2999-01-01"),
        in: database
      )
    }
    XCTAssertTrue(datedIds.isEmpty)
    let notebookIds = try service.driver.withDatabase { database in
      try scopedNoteIds(
        [aliceNote.noteId, bobNote.noteId],
        scope: NoteSearchScope(notebookId: aliceNotebook.notebookId),
        in: database
      )
    }
    XCTAssertEqual(notebookIds, [aliceNote.noteId])
  }

  func testPendingIngestNoteIsDropped() async throws {
    let service = try makeService(function: #function)
    let claim = try service.claimNotebookIngestRequest(
      idempotencyKey: "search-engine-pending-ingest",
      canonicalRequest: Data("pending engine search".utf8)
    )
    guard case let .execute(identity) = claim else { return XCTFail("expected a new ingest claim") }
    let pending = try service.pendingNotebookIngestScope().createNotebookWithNotes(
      title: "Pending engine notebook",
      metaJSON: try service.pendingNotebookIngestMetadata(callerMetadataJSON: nil, identity: identity),
      pages: [NotePageDraft(bodyMarkdown: "pending marker", readOnly: false)],
      autoActionPolicy: .deferredUntilFinalized
    )
    let pendingNote = try XCTUnwrap(pending.notes.first)
    let engine = FakeSearchEngine()
    engine.scriptedHits = [SearchEngineHit(noteId: pendingNote.noteId, score: 1, highlight: nil)]
    var enabled = service
    enabled.searchEngine = engine

    let results = try await enabled.engineSearchNotes(query: "ignored by scripted engine")
    XCTAssertTrue(results.isEmpty)
    XCTAssertTrue(engine.recordedSearches[0].filter.libraryIds == nil)
  }

  func testLongTermMemoryIsDroppedForScopedAndUnauthenticatedCallers() async throws {
    let service = try makeService(function: #function)
    let memory = try XCTUnwrap(try service.appendLongTermMemoryNotes(
      [LongTermMemoryEntryInput(bodyMarkdown: "private engine memory")],
      idempotencyKey: "search-engine-memory"
    ).notes.first)
    let engine = FakeSearchEngine()
    engine.scriptedHits = [SearchEngineHit(noteId: memory.noteId, score: 1, highlight: nil)]
    var scoped = service.scoped(to: NoteStoreSchema.defaultUserId)
    scoped.searchEngine = engine
    var anonymous = service.scoped(to: NoteStoreSchema.defaultUserId).unauthenticated()
    anonymous.searchEngine = engine

    let scopedResults = try await scoped.engineSearchNotes(query: "ignored")
    let anonymousResults = try await anonymous.engineSearchNotes(query: "ignored")
    XCTAssertTrue(scopedResults.isEmpty)
    XCTAssertTrue(anonymousResults.isEmpty)
    XCTAssertTrue(engine.recordedSearches.allSatisfy { $0.filter.excludesLongTermMemory })
  }

  func testDeletedHitAndEmptyReachabilityDoNotLeakOrCallEngine() async throws {
    let service = try makeService(function: #function)
    let engine = FakeSearchEngine()
    engine.scriptedHits = [SearchEngineHit(noteId: NoteID("deleted-engine-note"), score: 1, highlight: nil)]
    var enabled = service
    enabled.searchEngine = engine
    let deletedResults = try await enabled.engineSearchNotes(query: "ignored")
    XCTAssertTrue(deletedResults.isEmpty)

    let user = try service.createUser(email: "engine-unreachable@example.com", displayName: "Unreachable")
    var unreachable = service.scoped(to: user.userId).scoped(toLibrary: LibraryID("missing-engine-library"))
    unreachable.searchEngine = engine
    let unreachableResults = try await unreachable.engineSearchNotes(query: "ignored")
    XCTAssertTrue(unreachableResults.isEmpty)
    XCTAssertEqual(engine.recordedSearches.count, 1)
  }

  func testRelatedNotesChecksSourceAndRechecksEveryHit() async throws {
    let service = try makeService(function: #function)
    let closed = try service.createLibrary(name: "related-engine-private", authRequired: true)
    let privateNote = try service.scoped(toLibrary: closed.libraryId).createNote(bodyMarkdown: "private related")
    let source = try service.createNote(title: "Readable source", bodyMarkdown: "source body")
    let publicResult = try service.createNote(bodyMarkdown: "public related")
    let engine = FakeSearchEngine()
    engine.scriptedHits = [
      SearchEngineHit(noteId: source.noteId, score: 3, highlight: nil),
      SearchEngineHit(noteId: privateNote.noteId, score: 2, highlight: nil),
      SearchEngineHit(noteId: publicResult.noteId, score: 1, highlight: nil)
    ]
    var anonymous = service.scoped(to: NoteStoreSchema.defaultUserId).unauthenticated()
    anonymous.searchEngine = engine

    do {
      _ = try await anonymous.relatedNotes(noteId: privateNote.noteId)
      XCTFail("expected hidden source to be notFound")
    } catch let error as NoteServiceError {
      guard case .notFound = error else { return XCTFail("expected notFound, got \(error)") }
    }
    let results = try await anonymous.relatedNotes(noteId: source.noteId)
    XCTAssertEqual(results.map(\.note.noteId), [publicResult.noteId])
    XCTAssertEqual(engine.recordedRelated.count, 1)
    XCTAssertEqual(engine.recordedRelated[0].filter.excludedNoteIds, [source.noteId])
  }
}
