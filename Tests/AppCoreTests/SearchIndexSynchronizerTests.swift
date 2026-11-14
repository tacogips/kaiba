import Foundation
import XCTest
@testable import AppCore

final class SearchIndexSynchronizerTests: NoteTestCase {
  func testDrainBuildsFTSDerivedDocumentWithSortedTagsAndScopeMetadata() async throws {
    let service = try makeService()
    let firstTag = try service.defineTag(name: "zeta")
    let secondTag = try service.defineTag(name: "alpha")
    let note = try service.createNote(
      title: "Search title",
      bodyMarkdown: "# Search title\n\nBody text",
      tags: [NoteTagInput(name: firstTag.name), NoteTagInput(name: secondTag.name)]
    )
    let secondNote = try service.createNote(bodyMarkdown: "Second body")
    let engine = FakeSearchEngine()
    _ = try service.activateSearchEngineSync(indexIdentity: engine.indexIdentity)
    let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
    let synchronizer = SearchIndexSynchronizer(service: service, now: { fixedDate })

    let report = try await synchronizer.drainOnce(engine: engine)

    let document = try XCTUnwrap(engine.documents[note.noteId])
    XCTAssertEqual(document.title, note.title)
    XCTAssertEqual(
      document.body,
      try service.retrievalText(for: note)
    )
    XCTAssertEqual(document.tagNames, ["alpha", "zeta"])
    XCTAssertEqual(document.tagIds, [firstTag.tagId, secondTag.tagId].sorted())
    XCTAssertEqual(document.context, try service.driver.withDatabase {
      try ftsContextPayload(noteId: note.noteId, in: $0)
    })
    let notebook = try service.getNotebook(note.notebookId)
    XCTAssertEqual(document.libraryId, notebook.libraryId)
    XCTAssertEqual(document.ownerUserId, notebook.ownerUserId)
    XCTAssertEqual(document.createdAt, note.createdAt)
    XCTAssertEqual(document.updatedAt, note.updatedAt)
    XCTAssertNotNil(engine.documents[secondNote.noteId])
    XCTAssertEqual(report, SearchIndexDrainReport(pushed: 2, failed: 0, remaining: 0, remainingDue: 0))
  }

  func testMissingNoteIsPushedAsDelete() async throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "delete me")
    let engine = FakeSearchEngine()
    _ = try service.activateSearchEngineSync(indexIdentity: engine.indexIdentity)
    try service.deleteNote(noteId: note.noteId)

    let report = try await SearchIndexSynchronizer(service: service).drainOnce(engine: engine)

    XCTAssertEqual(engine.appliedBatches.flatMap { $0 }, [.delete(note.noteId)])
    XCTAssertNil(engine.documents[note.noteId])
    XCTAssertEqual(report.pushed, 1)
    XCTAssertEqual(report.remaining, 0)
  }

  func testEngineFailureDoesNotFailNoteWriteAndRetriesAfterBackoff() async throws {
    let service = try makeService()
    let engine = FakeSearchEngine()
    _ = try service.activateSearchEngineSync(indexIdentity: engine.indexIdentity)
    engine.failure = .unavailable("down")
    let first = try service.createNote(bodyMarkdown: "first write")
    let second = try service.createNote(bodyMarkdown: "second write")
    XCTAssertEqual(try service.getNote(first.noteId).bodyMarkdown, "first write")

    let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
    let synchronizer = SearchIndexSynchronizer(service: service, now: { fixedDate })
    let failed = try await synchronizer.drainOnce(engine: engine)
    XCTAssertEqual(failed.failed, 2)
    XCTAssertEqual(failed.remaining, 2)
    XCTAssertEqual(failed.remainingDue, 0)
    XCTAssertTrue(try lastErrors(service).allSatisfy { $0.contains("search engine unavailable") })

    engine.failure = nil
    let retryDate = fixedDate.addingTimeInterval(6)
    let recovered = try await SearchIndexSynchronizer(service: service, now: { retryDate })
      .drainOnce(engine: engine)
    XCTAssertEqual(recovered.pushed, 2)
    XCTAssertEqual(recovered.remaining, 0)
    XCTAssertNotNil(engine.documents[second.noteId])
  }

  func testPerNoteFailureOnlyRetainsThatOutboxRow() async throws {
    let service = try makeService()
    let first = try service.createNote(bodyMarkdown: "first")
    let second = try service.createNote(bodyMarkdown: "second")
    let engine = FakeSearchEngine()
    _ = try service.activateSearchEngineSync(indexIdentity: engine.indexIdentity)
    engine.failingNoteIds = [second.noteId]

    let report = try await SearchIndexSynchronizer(service: service).drainOnce(engine: engine)

    XCTAssertEqual(report.pushed, 1)
    XCTAssertEqual(report.failed, 1)
    XCTAssertEqual(report.remaining, 1)
    XCTAssertEqual(report.remainingDue, 0)
    XCTAssertNotNil(engine.documents[first.noteId])
    XCTAssertNil(engine.documents[second.noteId])
    XCTAssertEqual(try outboxNoteIds(service), [second.noteId])
  }

  func testGenerationRaceKeepsRowAndNextDrainPushesNewBody() async throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "before")
    let engine = FakeSearchEngine()
    _ = try service.activateSearchEngineSync(indexIdentity: engine.indexIdentity)
    engine.onApply = { _ in
      do {
        _ = try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "after")
      } catch {
        XCTFail("concurrent note update failed: \(error)")
      }
    }
    let synchronizer = SearchIndexSynchronizer(service: service)

    let raced = try await synchronizer.drainOnce(engine: engine)
    XCTAssertEqual(raced.pushed, 1)
    XCTAssertEqual(raced.remaining, 1)
    XCTAssertEqual(raced.remainingDue, 1)
    engine.onApply = nil
    let settled = try await synchronizer.drainOnce(engine: engine)

    XCTAssertEqual(settled.remaining, 0)
    XCTAssertEqual(engine.documents[note.noteId]?.body, "after")
  }

  func testDrainUntilIdleBatchesAndStopsAfterZeroProgress() async throws {
    let service = try makeService()
    let notebook = try service.createNotebook(title: "Batch notes")
    for index in 0..<250 {
      _ = try service.createNote(notebookId: notebook.notebookId, bodyMarkdown: "note \(index)")
    }
    let engine = FakeSearchEngine()
    _ = try service.activateSearchEngineSync(indexIdentity: engine.indexIdentity)
    let synchronizer = SearchIndexSynchronizer(service: service)

    let drained = try await synchronizer.drainUntilIdle(engine: engine, batchSize: 100)
    XCTAssertEqual(drained.pushed, 250)
    XCTAssertEqual(drained.remaining, 0)
    XCTAssertEqual(engine.appliedBatches.count, 3)

    let pending = try service.createNote(notebookId: notebook.notebookId, bodyMarkdown: "will fail")
    engine.failure = .unavailable("offline")
    let before = engine.appliedBatches.count
    let stopped = try await synchronizer.drainUntilIdle(engine: engine, batchSize: 100)
    XCTAssertEqual(stopped.pushed, 0)
    XCTAssertEqual(stopped.failed, 1)
    XCTAssertEqual(stopped.remaining, 1)
    XCTAssertEqual(engine.appliedBatches.count, before)
    XCTAssertEqual(try outboxNoteIds(service), [pending.noteId])
  }

  func testLongTermMemoryDocumentIsMarkedAndInactiveStoreDoesNoEngineWork() async throws {
    let service = try makeService()
    let memoryNotebookId = try XCTUnwrap(service.driver.withDatabase { database in
      try database.query(
        "SELECT notebook_id FROM notebook_tags WHERE tag_id = ? LIMIT 1",
        bindings: [.id(NoteStoreSchema.longTermMemoryNotebookKindTagId)]
      ).first?.identifier("notebook_id", as: NotebookID.self)
    })
    let memoryNote = try service.createNote(notebookId: memoryNotebookId, bodyMarkdown: "remember this")
    let activeEngine = FakeSearchEngine()
    _ = try service.activateSearchEngineSync(indexIdentity: activeEngine.indexIdentity)
    let activeReport = try await SearchIndexSynchronizer(service: service).drainOnce(engine: activeEngine)
    XCTAssertTrue(try XCTUnwrap(activeEngine.documents[memoryNote.noteId]).isLongTermMemory)
    XCTAssertEqual(activeReport.pushed, 1)

    let inactiveService = try makeService()
    _ = try inactiveService.createNote(bodyMarkdown: "not activated")
    let inactiveEngine = FakeSearchEngine()
    let inactiveReport = try await SearchIndexSynchronizer(service: inactiveService)
      .drainUntilIdle(engine: inactiveEngine)
    XCTAssertEqual(inactiveReport, SearchIndexDrainReport(pushed: 0, failed: 0, remaining: 0, remainingDue: 0))
    XCTAssertTrue(inactiveEngine.appliedBatches.isEmpty)
  }

  private func outboxNoteIds(_ service: NoteService) throws -> [NoteID] {
    try service.driver.withDatabase { database in
      try database.query("SELECT note_id FROM search_index_outbox ORDER BY note_id")
        .compactMap { $0.identifier("note_id", as: NoteID.self) }
    }
  }

  private func lastErrors(_ service: NoteService) throws -> [String] {
    try service.driver.withDatabase { database in
      try database.query("SELECT last_error FROM search_index_outbox")
        .compactMap { $0["last_error"] }
    }
  }
}
