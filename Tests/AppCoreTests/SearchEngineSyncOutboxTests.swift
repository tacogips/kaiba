import Foundation
@testable import AppCore
import XCTest

final class SearchEngineSyncOutboxTests: NoteTestCase {
  func testNeverActivatedWritesDoNotCreateOutboxRows() throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "before activation")
    _ = try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "updated")
    let tag = try service.defineTag(name: "never-activated")
    _ = try service.applyTags(
      noteId: note.noteId,
      tags: [NoteTagInput(name: tag.name)],
      provenance: .human
    )
    try service.deleteNote(noteId: note.noteId)

    XCTAssertFalse(try service.searchIndexOutboxStatus().isActivated)
    XCTAssertEqual(try outboxRows(service).count, 0)
  }

  func testActivationBackfillAndIdentityChangeBumpGenerations() throws {
    let service = try makeService()
    let first = try service.createNote(bodyMarkdown: "first")
    let second = try service.createNote(bodyMarkdown: "second")
    _ = try service.createNote(bodyMarkdown: "third")

    XCTAssertEqual(try service.enqueueAllNotesForSearchEngineSync(), 0)
    XCTAssertTrue(try service.activateSearchEngineSync(indexIdentity: "x:v1"))
    XCTAssertEqual(try outboxRows(service).count, 3)
    let firstGenerations = try generations(service)
    XCTAssertFalse(try service.activateSearchEngineSync(indexIdentity: "x:v1"))
    XCTAssertEqual(try generations(service), firstGenerations)
    XCTAssertTrue(try service.activateSearchEngineSync(indexIdentity: "x:v2"))
    XCTAssertEqual(try generations(service), firstGenerations.mapValues { $0 + 1 })
    XCTAssertEqual(try service.enqueueAllNotesForSearchEngineSync(), 3)
    XCTAssertEqual(Set(try outboxRows(service)), Set([first.noteId, second.noteId] + (try service.listNotes()).map(\.noteId)))
  }

  func testNoteWriteDeleteAndNotebookMoveHooksAreGatedAndCoalesced() throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "initial")
    _ = try service.activateSearchEngineSync(indexIdentity: "x:v1")
    let initialGeneration = try XCTUnwrap(try generations(service)[note.noteId])

    _ = try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "changed")
    XCTAssertEqual(try generations(service)[note.noteId], initialGeneration + 1)
    let destination = try service.createLibrary(name: "outbox-move")
    _ = try service.moveNotebook(note.notebookId, toLibrary: destination.name)
    XCTAssertEqual(try generations(service)[note.noteId], initialGeneration + 2)
    try service.deleteNote(noteId: note.noteId)
    XCTAssertNotNil(try generations(service)[note.noteId], "delete intent must outlive the note")
    XCTAssertFalse(try service.listNotes(notebookId: note.notebookId).contains { $0.noteId == note.noteId })
  }

  func testTagMemoRehomeEnqueuesItsNotes() throws {
    let service = try makeService()
    let tag = try service.defineTag(name: "outbox-rehome-tag")
    let source = try service.createNote(bodyMarkdown: "source")
    _ = try service.applyTags(
      noteId: source.noteId,
      tags: [NoteTagInput(name: tag.name)],
      provenance: .human,
      assignedBy: "test"
    )
    let memo = try service.ensureTagMemoNotebook(tagId: tag.tagId)
    let memoNote = try service.createNote(notebookId: memo.notebookId, bodyMarkdown: "memo")
    _ = try service.activateSearchEngineSync(indexIdentity: "x:v1")
    let before = try XCTUnwrap(try generations(service)[memoNote.noteId])
    let destination = try service.createLibrary(name: "outbox-memo-rehome")
    _ = try service.moveNotebook(source.notebookId, toLibrary: destination.name)
    _ = try service.scoped(toLibrary: destination.libraryId).ensureTagMemoNotebook(tagId: tag.tagId)
    XCTAssertEqual(try generations(service)[memoNote.noteId], before + 1)
  }

  func testTagApplyRemoveReparentUndoAndNotebookDeleteEnqueue() throws {
    let service = try makeService()
    let oldParent = try service.defineTag(name: "outbox-old-parent")
    let newParent = try service.defineTag(name: "outbox-new-parent")
    let child = try service.defineTag(name: "outbox-child", parentTagId: oldParent.tagId)
    let note = try service.createNote(
      bodyMarkdown: "tagged note",
      tags: [NoteTagInput(name: child.name)]
    )
    _ = try service.activateSearchEngineSync(indexIdentity: "x:v1")
    var generation = try XCTUnwrap(try generations(service)[note.noteId])

    _ = try service.removeTag(noteId: note.noteId, tagName: child.name, removedBy: .human)
    generation += 1
    XCTAssertEqual(try generations(service)[note.noteId], generation)
    _ = try service.applyTags(
      noteId: note.noteId,
      tags: [NoteTagInput(name: child.name)],
      provenance: .human
    )
    generation += 1
    XCTAssertEqual(try generations(service)[note.noteId], generation)
    _ = try service.defineTag(name: child.name, parentTagId: newParent.tagId)
    generation += 1
    XCTAssertEqual(try generations(service)[note.noteId], generation)
    _ = try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "edited body")
    _ = try XCTUnwrap(try service.undoLastAction())
    generation += 2
    XCTAssertEqual(try generations(service)[note.noteId], generation)

    let sibling = try service.createNote(notebookId: note.notebookId, bodyMarkdown: "sibling")
    try service.deleteNotebook(notebookId: note.notebookId)
    XCTAssertNotNil(try generations(service)[note.noteId])
    XCTAssertNotNil(try generations(service)[sibling.noteId])
  }

  func testExpiredClaimCanBeLeasedAgain() throws {
    let service = try makeService()
    _ = try service.createNote(bodyMarkdown: "leased")
    _ = try service.activateSearchEngineSync(indexIdentity: "x:v1")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    XCTAssertEqual(try service.claimSearchIndexOutbox(limit: 1, claimToken: "lease-1", now: now).count, 1)
    XCTAssertEqual(try service.claimSearchIndexOutbox(limit: 1, claimToken: "lease-2", now: now).count, 0)
    XCTAssertEqual(
      try service.claimSearchIndexOutbox(limit: 1, claimToken: "lease-3", now: now.addingTimeInterval(61)).count,
      1
    )
  }

  func testSettleSuccessWithUnchangedGenerationDeletesRow() throws {
    let service = try makeService()
    _ = try service.createNote(bodyMarkdown: "first successful push")
    _ = try service.createNote(bodyMarkdown: "second successful push")
    _ = try service.activateSearchEngineSync(indexIdentity: "x:v1")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let claimed = try service.claimSearchIndexOutbox(limit: 2, claimToken: "ok-1", now: now)
    XCTAssertEqual(claimed.count, 2)

    try service.settleSearchIndexOutbox(
      succeeded: claimed,
      failed: [],
      claimToken: "ok-1",
      now: now
    )

    XCTAssertTrue(try outboxRows(service).isEmpty)
    XCTAssertEqual(try service.searchIndexOutboxStatus(now: now).pending, 0)
  }

  func testClaimLeaseGenerationRaceAndFailureBackoff() throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "claim")
    _ = try service.activateSearchEngineSync(indexIdentity: "x:v1")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let claimed = try service.claimSearchIndexOutbox(limit: 1, claimToken: "claim-1", now: now)
    XCTAssertEqual(claimed.count, 1)
    XCTAssertEqual(try service.claimSearchIndexOutbox(limit: 1, claimToken: "claim-2", now: now), [])
    try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "raced")
    try service.settleSearchIndexOutbox(succeeded: claimed, failed: [], claimToken: "claim-1", now: now)
    XCTAssertEqual(try generations(service)[note.noteId], claimed[0].generation + 1)
    let reclaimed = try service.claimSearchIndexOutbox(limit: 1, claimToken: "claim-3", now: now)
    try service.settleSearchIndexOutbox(
      succeeded: [],
      failed: [SearchIndexOutboxFailure(row: reclaimed[0], message: String(repeating: "e", count: 600))],
      claimToken: "claim-3",
      now: now
    )
    let status = try service.searchIndexOutboxStatus(now: now)
    XCTAssertEqual(status.failing, 1)
    XCTAssertEqual(status.due, 0)
    XCTAssertEqual(try outboxError(service, noteId: note.noteId)?.count, 500)
    XCTAssertEqual(try service.searchIndexOutboxStatus(now: now.addingTimeInterval(6)).due, 1)
    XCTAssertEqual(
      try service.claimSearchIndexOutbox(limit: 1, claimToken: "claim-4", now: now.addingTimeInterval(61)).count,
      1
    )
    let claimedAgain = try service.claimSearchIndexOutbox(limit: 1, claimToken: "claim-5", now: now.addingTimeInterval(122))
    try service.settleSearchIndexOutbox(
      succeeded: [],
      failed: [SearchIndexOutboxFailure(row: claimedAgain[0], message: "second failure")],
      claimToken: "claim-5",
      now: now.addingTimeInterval(122)
    )
    XCTAssertEqual(
      try service.searchIndexOutboxStatus(now: now.addingTimeInterval(131)).due,
      0,
      "the second failure waits 10 seconds"
    )
    try service.driver.withDatabase { database in
      try database.execute("UPDATE search_index_outbox SET attempts = 20 WHERE note_id = ?", bindings: [.id(note.noteId)])
    }
    let capped = try service.claimSearchIndexOutbox(limit: 1, claimToken: "claim-6", now: now.addingTimeInterval(5000))
    try service.settleSearchIndexOutbox(
      succeeded: [],
      failed: [SearchIndexOutboxFailure(row: capped[0], message: "capped")],
      claimToken: "claim-6",
      now: now.addingTimeInterval(5000)
    )
    XCTAssertEqual(try service.searchIndexOutboxStatus(now: now.addingTimeInterval(8599)).due, 0)
    XCTAssertEqual(try service.searchIndexOutboxStatus(now: now.addingTimeInterval(8601)).due, 1)
  }

  private func outboxRows(_ service: NoteService) throws -> [NoteID] {
    try service.driver.withDatabase { database in
      try database.query("SELECT note_id FROM search_index_outbox ORDER BY note_id")
        .compactMap { $0.identifier("note_id", as: NoteID.self) }
    }
  }

  private func generations(_ service: NoteService) throws -> [NoteID: Int64] {
    try service.driver.withDatabase { database in
      Dictionary(uniqueKeysWithValues: try database.query("SELECT note_id, generation FROM search_index_outbox")
        .compactMap { row in
          guard let noteId = row.identifier("note_id", as: NoteID.self),
                let generation = row["generation"].flatMap(Int64.init) else { return nil }
          return (noteId, generation)
        })
    }
  }

  private func outboxError(_ service: NoteService, noteId: NoteID) throws -> String? {
    try service.driver.withDatabase { database in
      try database.query("SELECT last_error FROM search_index_outbox WHERE note_id = ?", bindings: [.id(noteId)])
        .first?["last_error"]
    }
  }
}
