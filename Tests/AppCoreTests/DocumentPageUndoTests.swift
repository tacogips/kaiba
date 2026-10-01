import Foundation
@testable import AppCore
import XCTest

final class DocumentPageUndoTests: NoteTestCase {
  private let pageMeta = #"{"documentPage":{"pageNumber":1,"ocrState":"complete","analysis":{"writingMode":"unknown","binding":"unknown"},"originFileId":"file-1"}}"#
  private let pendingPageMeta = #"{"documentPage":{"pageNumber":2,"ocrState":"pending","analysis":{"writingMode":"unknown","binding":"unknown"},"originFileId":"file-2"}}"#

  func testUndoDeleteRestoresPageSearchTextAndSearchability() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let ingest = try service.createNotebookWithNotes(
      title: "Imported pages",
      pages: [NotePageDraft(bodyMarkdown: "", readOnly: false, metaJSON: pageMeta, searchText: "Orbital chart text")]
    )
    let page = try XCTUnwrap(ingest.notes.first)

    try service.deleteNote(noteId: page.noteId)
    _ = try XCTUnwrap(try service.undoLastAction())

    XCTAssertEqual(try service.getNote(page.noteId).bodyMarkdown, "")
    XCTAssertEqual(try storedSearchText(page.noteId, using: driver), "Orbital chart text")
    XCTAssertEqual(try service.searchNotes(query: "Orbital").first?.note.noteId, page.noteId)
  }

  func testDeleteNotebookContainingPageNoteRemainsNonUndoable() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let ingest = try service.createNotebookWithNotes(
      title: "Imported pages",
      pages: [NotePageDraft(bodyMarkdown: "", readOnly: false, metaJSON: pageMeta, searchText: "Orbital chart text")]
    )
    let page = try XCTUnwrap(ingest.notes.first)

    try service.deleteNotebook(notebookId: ingest.notebook.notebookId)

    let deletion = try XCTUnwrap(try service.actionHistory().first)
    XCTAssertEqual(deletion.action, "notebook-deleted")
    XCTAssertFalse(deletion.undoable)
    XCTAssertNil(try service.undoState().undoTarget)
    XCTAssertThrowsError(try service.getNote(page.noteId))
  }

  func testUndoDeleteRestoresNormalNoteWithNullSearchText() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let note = try service.createNote(bodyMarkdown: "ordinary markdown")

    try service.deleteNote(noteId: note.noteId)
    _ = try XCTUnwrap(try service.undoLastAction())

    XCTAssertEqual(try service.getNote(note.noteId).bodyMarkdown, "ordinary markdown")
    XCTAssertNil(try storedSearchText(note.noteId, using: driver))
  }

  func testRestoreLegacyPageSnapshotMigratesBodyIntoSearchText() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let notebook = try service.createNotebook(title: "Legacy import")
    let noteId = NoteID.generate()
    let now = NoteStoreClock.system.now()
    let snapshot = JSONValue.object([
      "note": .object([
        "noteId": .string(noteId.rawValue),
        "notebookId": .string(notebook.notebookId.rawValue),
        "noteNumber": .integer(1),
        "title": .null,
        "titleSource": .string(NoteTitleSource.derived.rawValue),
        "bodyMarkdown": .string("Legacy OCR words"),
        "readOnly": .bool(false),
        "createdBy": .string(NoteStoreSchema.defaultUserId.rawValue),
        "updatedBy": .string(NoteStoreSchema.defaultUserId.rawValue),
        "createdAt": .string(now),
        "updatedAt": .string(now),
        "metaJSON": .string(pageMeta)
      ]),
      "tags": .array([]),
      "links": .array([]),
      "comments": .array([]),
      "files": .array([]),
      "canonicalTagIds": .array([])
    ])

    try driver.withDatabase { database in
      try database.transaction { db in
        let restored = try service.restoreNoteSnapshot(snapshot, in: db)
        try refreshFTS(noteId: restored.noteId, previous: nil, in: db)
      }
    }

    XCTAssertEqual(try service.getNote(noteId).bodyMarkdown, "")
    XCTAssertEqual(try storedSearchText(noteId, using: driver), "Legacy OCR words")
    XCTAssertEqual(try service.searchNotes(query: "Legacy").first?.note.noteId, noteId)
  }

  func testUndoDeletePreservesPendingPageEmptySearchText() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let ingest = try service.createNotebookWithNotes(
      title: "Pending import",
      pages: [NotePageDraft(bodyMarkdown: "", readOnly: false, metaJSON: pendingPageMeta, searchText: "")]
    )
    let page = try XCTUnwrap(ingest.notes.first)

    try service.deleteNote(noteId: page.noteId)
    _ = try XCTUnwrap(try service.undoLastAction())

    XCTAssertEqual(try storedSearchText(page.noteId, using: service.driver), "")
  }

  func testUndoPageBodyEditConflictsWithoutMovingActionCursor() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let ingest = try service.createNotebookWithNotes(
      title: "Editable import",
      pages: [NotePageDraft(bodyMarkdown: "", readOnly: false, metaJSON: pageMeta, searchText: "Recognized page text")]
    )
    let page = try XCTUnwrap(ingest.notes.first)
    try driver.withDatabase { database in
      try database.execute("UPDATE notes SET meta_json = NULL WHERE note_id = ?", bindings: [.id(page.noteId)])
    }
    _ = try service.updateNoteBody(noteId: page.noteId, bodyMarkdown: "Edited OCR body")
    try driver.withDatabase { database in
      try database.execute("UPDATE notes SET meta_json = jsonb(?) WHERE note_id = ?", bindings: [.text(pageMeta), .id(page.noteId)])
    }
    let cursorBefore = try XCTUnwrap(try service.undoState().undoTarget?.seq)

    for _ in 0..<2 {
      XCTAssertThrowsError(try service.undoLastAction()) { error in
        guard case NoteServiceError.conflict(let message) = error else {
          return XCTFail("expected conflict, got \(error)")
        }
        XCTAssertTrue(message.contains("document page text is managed by OCR"))
      }
      XCTAssertEqual(try service.undoState().undoTarget?.seq, cursorBefore)
    }
    XCTAssertEqual(try service.getNote(page.noteId).bodyMarkdown, "Edited OCR body")
    XCTAssertEqual(try storedSearchText(page.noteId, using: driver), "Recognized page text")
  }

  func testUndoNormalNoteBodyEditStillWorks() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let note = try service.createNote(bodyMarkdown: "before edit")
    _ = try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "after edit")

    _ = try XCTUnwrap(try service.undoLastAction())

    XCTAssertEqual(try service.getNote(note.noteId).bodyMarkdown, "before edit")
  }

  private func storedSearchText(_ noteId: NoteID, using driver: NoteDatabaseDriving) throws -> String? {
    try driver.withDatabase { database in
      try database.query(
        "SELECT search_text FROM notes WHERE note_id = ? LIMIT 1",
        bindings: [.id(noteId)]
      ).first?["search_text"]
    }
  }
}
