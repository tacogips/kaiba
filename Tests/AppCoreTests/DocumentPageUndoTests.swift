import Foundation
@testable import AppCore
import XCTest

final class DocumentPageUndoTests: NoteTestCase {
  func testUndoDeleteRestoresPageRowTranslationsAndSearchability() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let origin = try insertSyntheticOriginFile(service)
    let ingest = try service.createNotebookWithNotes(
      title: "Imported pages",
      pages: [syntheticPageDraft(originFileId: origin, text: "Orbital chart text", readOnly: false)]
    )
    let page = try XCTUnwrap(ingest.notes.first)
    try insertTranslation(noteId: page.noteId, language: "ja", body: "Kidou zu", using: driver)

    try service.deleteNote(noteId: page.noteId)
    XCTAssertEqual(try pageRowCount(page.noteId, using: driver), 0, "the page row cascades with the note")
    XCTAssertTrue(try service.noteTranslationsIfPresent(page.noteId).isEmpty)
    _ = try XCTUnwrap(try service.undoLastAction())

    let restored = try service.getNote(page.noteId)
    XCTAssertEqual(restored.bodyMarkdown, "")
    XCTAssertEqual(restored.documentPage, page.documentPage)
    XCTAssertEqual(try storedPageText(page.noteId, using: driver), "Orbital chart text")
    XCTAssertEqual(try service.noteTranslations(noteId: page.noteId).map(\.body), ["Kidou zu"])
    XCTAssertEqual(try service.searchNotes(query: "Orbital").first?.note.noteId, page.noteId)
    XCTAssertEqual(try service.searchNotes(query: "Kidou").first?.note.noteId, page.noteId)
  }

  func testDeleteNotebookContainingPageNoteRemainsNonUndoable() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let ingest = try service.createNotebookWithNotes(
      title: "Imported pages",
      pages: [syntheticPageDraft(originFileId: try insertSyntheticOriginFile(service), text: "Orbital chart text", readOnly: false)]
    )
    let page = try XCTUnwrap(ingest.notes.first)

    try service.deleteNotebook(notebookId: ingest.notebook.notebookId)

    let deletion = try XCTUnwrap(try service.actionHistory().first)
    XCTAssertEqual(deletion.action, "notebook-deleted")
    XCTAssertFalse(deletion.undoable)
    XCTAssertNil(try service.undoState().undoTarget)
    XCTAssertThrowsError(try service.getNote(page.noteId))
    XCTAssertEqual(try pageRowCount(page.noteId, using: service.driver), 0)
  }

  func testUndoDeleteRestoresNormalNoteWithoutPageRow() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let note = try service.createNote(bodyMarkdown: "ordinary markdown")

    try service.deleteNote(noteId: note.noteId)
    _ = try XCTUnwrap(try service.undoLastAction())

    XCTAssertEqual(try service.getNote(note.noteId).bodyMarkdown, "ordinary markdown")
    XCTAssertNil(try service.getNote(note.noteId).documentPage)
    XCTAssertNil(try storedPageText(note.noteId, using: driver))
  }

  func testRestoreSnapshotWithoutItsOriginalComesBackAsOrdinaryNote() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let notebook = try service.createNotebook(title: "Orphaned import")
    let noteId = NoteID.generate()
    let now = NoteStoreClock.system.now()
    let snapshot = JSONValue.object([
      "note": .object([
        "noteId": .string(noteId.rawValue),
        "notebookId": .string(notebook.notebookId.rawValue),
        "noteNumber": .integer(1),
        "title": .null,
        "titleSource": .string(NoteTitleSource.derived.rawValue),
        "bodyMarkdown": .string(""),
        "readOnly": .bool(false),
        "createdAt": .string(now),
        "updatedAt": .string(now)
      ]),
      "documentPage": .object([
        "originFileId": .string("file-gone"),
        "pageNumber": .integer(1),
        "text": .string("Lost words"),
        "textStatus": .string("complete"),
        "textSource": .string("ocr"),
        "analysisJSON": .string(#"{"writingMode":"unknown","binding":"unknown"}"#)
      ])
    ])

    try driver.withDatabase { database in
      try database.transaction { db in
        let restored = try service.restoreNoteSnapshot(snapshot, in: db)
        try refreshFTS(noteId: restored.noteId, previous: nil, in: db)
      }
    }

    XCTAssertNil(try service.getNote(noteId).documentPage)
    XCTAssertEqual(try pageRowCount(noteId, using: driver), 0)
  }

  func testUndoDeletePreservesPendingPageEmptyText() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let ingest = try service.createNotebookWithNotes(
      title: "Pending import",
      pages: [syntheticPageDraft(pageNumber: 2, originFileId: try insertSyntheticOriginFile(service), text: "", readOnly: false)]
    )
    let page = try XCTUnwrap(ingest.notes.first)

    try service.deleteNote(noteId: page.noteId)
    _ = try XCTUnwrap(try service.undoLastAction())

    XCTAssertEqual(try storedPageText(page.noteId, using: service.driver), "")
    XCTAssertEqual(try service.getNote(page.noteId).documentPage?.textStatus, .pending)
    XCTAssertEqual(try service.getNote(page.noteId).documentPage?.pageNumber, 2)
  }

  func testUndoPageBodyEditConflictsWithoutMovingActionCursor() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let ingest = try service.createNotebookWithNotes(
      title: "Editable import",
      pages: [syntheticPageDraft(
        originFileId: try insertSyntheticOriginFile(service), text: "Recognized page text", readOnly: false
      )]
    )
    let page = try XCTUnwrap(ingest.notes.first)
    let pageRow = try XCTUnwrap(page.documentPage)
    // Edit while the note is temporarily not a page, then make it a page again.
    try driver.withDatabase { database in
      try database.execute("DELETE FROM document_pages WHERE note_id = ?", bindings: [.id(page.noteId)])
    }
    _ = try service.updateNoteBody(noteId: page.noteId, bodyMarkdown: "Edited OCR body")
    try driver.withDatabase { database in
      try insertDocumentPage(noteId: page.noteId, page: pageRow, text: "Recognized page text", in: database)
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
    XCTAssertEqual(try storedPageText(page.noteId, using: driver), "Recognized page text")
  }

  func testUndoNormalNoteBodyEditStillWorks() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let note = try service.createNote(bodyMarkdown: "before edit")
    _ = try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "after edit")

    _ = try XCTUnwrap(try service.undoLastAction())

    XCTAssertEqual(try service.getNote(note.noteId).bodyMarkdown, "before edit")
  }

  private func storedPageText(_ noteId: NoteID, using driver: NoteDatabaseDriving) throws -> String? {
    try driver.withDatabase { try storedDocumentPageText(noteId, in: $0) }
  }

  private func pageRowCount(_ noteId: NoteID, using driver: NoteDatabaseDriving) throws -> Int {
    try driver.withDatabase { database in
      try database.query("SELECT 1 FROM document_pages WHERE note_id = ?", bindings: [.id(noteId)]).count
    }
  }

  private func insertTranslation(noteId: NoteID, language: String, body: String, using driver: NoteDatabaseDriving) throws {
    try driver.withDatabase { database in
      let previous = try ftsPayload(noteId: noteId, in: database)
      try database.execute(
        """
        INSERT INTO note_translations (note_id, language, body, source_sha256, provenance, created_at, updated_at)
        VALUES (?, ?, ?, 'hash', 'ai', 'now', 'now')
        """,
        bindings: [.id(noteId), .text(language), .text(body)]
      )
      try refreshFTS(noteId: noteId, previous: previous, in: database)
    }
  }
}

private extension NoteService {
  func noteTranslationsIfPresent(_ noteId: NoteID) throws -> [String] {
    try driver.withDatabase { database in
      try database.query("SELECT language FROM note_translations WHERE note_id = ?", bindings: [.id(noteId)])
        .compactMap { $0["language"] }
    }
  }
}
