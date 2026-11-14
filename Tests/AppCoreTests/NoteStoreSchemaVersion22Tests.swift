import Foundation
@testable import AppCore
import XCTest

final class NoteStoreSchemaVersion22Tests: NoteTestCase {
  private let pageMeta = #"{"documentPage":{"pageNumber":1,"ocrState":"complete","analysis":{"writingMode":"unknown","binding":"unknown"},"originFileId":"file-1"}}"#
  private let pendingPageMeta = #"{"documentPage":{"pageNumber":2,"ocrState":"pending","analysis":{"writingMode":"unknown","binding":"unknown"},"originFileId":"file-2"}}"#

  func testFreshSchemaPlacesSearchTextLast() throws {
    let driver = try makeNoteDriver()
    try NoteStoreSchema.prepare(on: driver)
    try driver.withDatabase { database in
      XCTAssertEqual(try database.query("PRAGMA table_info(notes)").last?["name"], "search_text")
      XCTAssertEqual(try versions(in: database), [23])
    }
  }

  func testVersion21MigrationMovesPageBodyAndPreservesFTSSearchability() throws {
    let driver = try makeNoteDriver()
    try NoteStoreSchema.prepare(on: driver)
    let service = try NoteService(driver: driver)
    let inserted = try service.createNotebookWithNotes(
      title: "Pages",
      kindTagName: nil,
      pages: [
        NotePageDraft(bodyMarkdown: "", readOnly: false, metaJSON: pageMeta, searchText: "Alpha quantum ledger"),
        NotePageDraft(bodyMarkdown: "", readOnly: false, metaJSON: pendingPageMeta, searchText: ""),
        NotePageDraft(bodyMarkdown: "", readOnly: false, metaJSON: pageMeta, searchText: "![Figure 1](/files/f1)"),
        NotePageDraft(bodyMarkdown: "ordinary markdown")
      ],
      notebookReadOnly: false
    )
    let page = inserted.notes[0]
    let pending = inserted.notes[1]
    let figure = inserted.notes[2]
    let ordinary = inserted.notes[3]

    let pageIds = [page.noteId, pending.noteId, figure.noteId]
    var originalState: [NoteID: (title: String?, updatedAt: String?)] = [:]
    try driver.withDatabase { database in
      for noteId in pageIds {
        let oldPayload = try XCTUnwrap(ftsPayload(noteId: noteId, in: database))
        let state = try XCTUnwrap(try database.query(
          "SELECT title, updated_at FROM notes WHERE note_id = ?",
          bindings: [.id(noteId)]
        ).first)
        originalState[noteId] = (state["title"], state["updated_at"])
        try database.execute(
          "UPDATE notes SET body_markdown = search_text, search_text = NULL WHERE note_id = ?",
          bindings: [.id(noteId)]
        )
        try refreshFTS(noteId: noteId, previous: oldPayload, in: database)
      }
      try database.execute("ALTER TABLE notes DROP COLUMN search_text")
      try database.execute("DELETE FROM note_schema_version")
      try database.execute("INSERT INTO note_schema_version VALUES (21, 'then')")
    }

    try NoteStoreSchema.prepare(on: driver)
    try driver.withDatabase { database in
      for noteId in pageIds {
        let migratedState = try XCTUnwrap(try database.query(
          "SELECT title, updated_at FROM notes WHERE note_id = ?",
          bindings: [.id(noteId)]
        ).first)
        XCTAssertEqual(migratedState["title"], originalState[noteId]?.title)
        XCTAssertEqual(migratedState["updated_at"], originalState[noteId]?.updatedAt)
      }
      let row = try XCTUnwrap(try database.query(
        "SELECT body_markdown, search_text FROM notes WHERE note_id = ?",
        bindings: [.id(page.noteId)]
      ).first)
      XCTAssertEqual(row["body_markdown"], "")
      XCTAssertEqual(row["search_text"], "Alpha quantum ledger")
      let pendingRow = try XCTUnwrap(try database.query(
        "SELECT body_markdown, search_text FROM notes WHERE note_id = ?",
        bindings: [.id(pending.noteId)]
      ).first)
      XCTAssertEqual(pendingRow["body_markdown"], "")
      XCTAssertEqual(pendingRow["search_text"], "")
      let figureRow = try XCTUnwrap(try database.query(
        "SELECT body_markdown, search_text FROM notes WHERE note_id = ?",
        bindings: [.id(figure.noteId)]
      ).first)
      XCTAssertEqual(figureRow["body_markdown"], "")
      XCTAssertEqual(figureRow["search_text"], "![Figure 1](/files/f1)")
      let ordinaryRow = try XCTUnwrap(try database.query(
        "SELECT body_markdown, search_text FROM notes WHERE note_id = ?",
        bindings: [.id(ordinary.noteId)]
      ).first)
      XCTAssertEqual(ordinaryRow["body_markdown"], "ordinary markdown")
      XCTAssertNil(ordinaryRow["search_text"])
      XCTAssertEqual(try versions(in: database), [21, 22, 23])
    }
    XCTAssertEqual(try service.searchNotes(query: "quantum").first?.note.noteId, page.noteId)
    let report = try service.checkStore()
    XCTAssertTrue(report.searchIndexHealthy)
    XCTAssertEqual(report.notesMissingFromSearchIndex, [])
    XCTAssertEqual(report.orphanedSearchIndexRows, 0)

    try NoteStoreSchema.prepare(on: driver)
    try driver.withDatabase { database in
      XCTAssertEqual(try versions(in: database), [21, 22, 23])
      let row = try XCTUnwrap(try database.query(
        "SELECT body_markdown, search_text FROM notes WHERE note_id = ?",
        bindings: [.id(page.noteId)]
      ).first)
      XCTAssertEqual(row["body_markdown"], "")
      XCTAssertEqual(row["search_text"], "Alpha quantum ledger")
    }
  }

  func testVersion21MigrationRunsWhenColumnAlreadyExists() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let page = try service.createNotebookWithNotes(
      title: "Pages",
      pages: [NotePageDraft(bodyMarkdown: "Existing column text", readOnly: false, metaJSON: pageMeta)]
    ).notes[0]
    try driver.withDatabase { database in
      try database.execute("DELETE FROM note_schema_version")
      try database.execute("INSERT INTO note_schema_version VALUES (21, 'then')")
    }
    try NoteStoreSchema.prepare(on: driver)
    try driver.withDatabase { database in
      let row = try XCTUnwrap(try database.query(
        "SELECT body_markdown, search_text FROM notes WHERE note_id = ?",
        bindings: [.id(page.noteId)]
      ).first)
      XCTAssertEqual(row["body_markdown"], "")
      XCTAssertEqual(row["search_text"], "Existing column text")
      XCTAssertEqual(try versions(in: database), [21, 22, 23])
    }
  }

  func testVersion20UpgradesThroughVersion21ToVersion22() throws {
    let driver = try makeNoteDriver()
    try NoteStoreSchema.prepare(on: driver)
    let service = try NoteService(driver: driver)
    let page = try service.createNotebookWithNotes(
      title: "Pages",
      pages: [NotePageDraft(bodyMarkdown: "Legacy twenty text", readOnly: false, metaJSON: pageMeta)]
    ).notes[0]
    try driver.withDatabase { database in
      try database.execute("DROP TABLE user_agent_credentials")
      try database.execute("""
        CREATE TABLE user_agent_credentials (
          user_id TEXT PRIMARY KEY REFERENCES users(user_id),
          provider TEXT NOT NULL CHECK (provider IN ('anthropic','openai','openrouter','openai-compatible')),
          api_key TEXT NOT NULL, base_url TEXT, default_model TEXT NOT NULL,
          enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0,1)),
          created_at TEXT NOT NULL, updated_at TEXT NOT NULL
        ) STRICT
        """)
      try database.execute("DELETE FROM note_schema_version")
      try database.execute("INSERT INTO note_schema_version VALUES (20, 'then')")
    }
    try NoteStoreSchema.prepare(on: driver)
    try driver.withDatabase { database in
      let row = try XCTUnwrap(try database.query(
        "SELECT body_markdown, search_text FROM notes WHERE note_id = ?",
        bindings: [.id(page.noteId)]
      ).first)
      XCTAssertEqual(row["body_markdown"], "")
      XCTAssertEqual(row["search_text"], "Legacy twenty text")
      XCTAssertEqual(try versions(in: database), [20, 21, 22, 23])
    }
  }

  func testVersion24IsRejectedAsFuture() throws {
    let driver = try makeNoteDriver()
    try NoteStoreSchema.prepare(on: driver)
    try driver.withDatabase { database in
      try database.execute("DELETE FROM note_schema_version")
      try database.execute("INSERT INTO note_schema_version VALUES (24, 'then')")
    }
    XCTAssertThrowsError(try NoteStoreSchema.prepare(on: driver)) { error in
      XCTAssertEqual(error as? NoteStoreSchemaError, .unsupportedFutureVersion(found: 24, supported: 23))
    }
  }

  func testPageDraftSearchTextDerivesTitleAndBodyUpdatesAreRefused() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let result = try service.createNotebookWithNotes(
      title: "Pages",
      kindTagName: nil,
      pages: [NotePageDraft(
        bodyMarkdown: "",
        readOnly: false,
        metaJSON: pageMeta,
        searchText: "Heading line\nrest"
      )],
      notebookReadOnly: false
    )
    let page = try XCTUnwrap(result.notes.first)
    XCTAssertEqual(page.title, "Heading line")
    XCTAssertEqual(try service.searchNotes(query: "rest").first?.note.noteId, page.noteId)
    XCTAssertThrowsError(try service.updateNoteBody(noteId: page.noteId, bodyMarkdown: "replacement")) { error in
      XCTAssertEqual(
        error as? NoteServiceError,
        .invalidInput("document page text is managed by OCR; use a comment to annotate the page")
      )
    }
    let ordinary = try service.createNote(bodyMarkdown: "editable")
    XCTAssertEqual(try service.updateNoteBody(noteId: ordinary.noteId, bodyMarkdown: "updated").bodyMarkdown, "updated")
  }

  private func versions(in database: SQLiteDatabase) throws -> [Int] {
    try database.query("SELECT version FROM note_schema_version ORDER BY version")
      .compactMap { $0["version"].flatMap(Int.init) }
  }
}
