import Foundation
@testable import AppCore
import XCTest

final class NoteStoreSchemaVersion23Tests: NoteTestCase {
  private let pageMeta = #"{"documentPage":{"pageNumber":1,"ocrState":"complete","analysis":{"writingMode":"unknown","binding":"unknown"},"originFileId":"file-1"}}"#

  func testFreshStoreCreatesOutboxTablesAndRecordsVersion23() throws {
    let driver = try makeNoteDriver()
    try NoteStoreSchema.prepare(on: driver)

    try driver.withDatabase { database in
      XCTAssertEqual(try versions(in: database), [23])
      XCTAssertTrue(try database.tableExists("search_engine_sync_state"))
      XCTAssertTrue(try database.tableExists("search_index_outbox"))
      XCTAssertTrue(try database.query("PRAGMA foreign_key_list(search_index_outbox)").isEmpty)
      XCTAssertEqual(try database.query("PRAGMA table_info(search_index_outbox)").count, 7)
    }
  }

  func testVersion22StoreUpgradesTo23() throws {
    let driver = try makeNoteDriver()
    try NoteStoreSchema.prepare(on: driver)
    try driver.withDatabase { database in
      try database.execute("DROP TABLE search_index_outbox")
      try database.execute("DROP TABLE search_engine_sync_state")
      try database.execute("DELETE FROM note_schema_version")
      try database.execute("INSERT INTO note_schema_version VALUES (22, 'then')")
      XCTAssertFalse(try database.tableExists("search_index_outbox"))
      XCTAssertFalse(try database.tableExists("search_engine_sync_state"))
    }

    try NoteStoreSchema.prepare(on: driver)

    try driver.withDatabase { database in
      XCTAssertEqual(try versions(in: database), [22, 23])
      XCTAssertTrue(try database.tableExists("search_engine_sync_state"))
      XCTAssertTrue(try database.tableExists("search_index_outbox"))
    }
  }

  func testVersion21PageMigrationCanRefreshFTSBeforeOutboxActivation() throws {
    let driver = try makeNoteDriver()
    try NoteStoreSchema.prepare(on: driver)
    let service = try NoteService(driver: driver)
    let note = try service.createNotebookWithNotes(
      title: "Legacy page",
      pages: [NotePageDraft(bodyMarkdown: "", readOnly: false, metaJSON: pageMeta, searchText: "Page content")]
    ).notes[0]
    try driver.withDatabase { database in
      try database.execute(
        "UPDATE notes SET body_markdown = search_text, search_text = NULL WHERE note_id = ?",
        bindings: [.id(note.noteId)]
      )
      try database.execute("ALTER TABLE notes DROP COLUMN search_text")
      try database.execute("DROP TABLE search_index_outbox")
      try database.execute("DROP TABLE search_engine_sync_state")
      try database.execute("DELETE FROM note_schema_version")
      try database.execute("INSERT INTO note_schema_version VALUES (21, 'then')")
      XCTAssertFalse(try database.tableExists("search_index_outbox"))
      XCTAssertFalse(try database.tableExists("search_engine_sync_state"))
    }

    try NoteStoreSchema.prepare(on: driver)

    try driver.withDatabase { database in
      XCTAssertEqual(try versions(in: database), [21, 22, 23])
      XCTAssertTrue(try database.tableExists("search_engine_sync_state"))
      XCTAssertTrue(try database.tableExists("search_index_outbox"))
      XCTAssertEqual(try database.query("SELECT note_id FROM search_index_outbox").count, 0)
      XCTAssertEqual(try database.query(
        "SELECT note_id FROM note_fts_map WHERE note_id = ?",
        bindings: [.id(note.noteId)]
      ).count, 1)
    }
  }

  private func versions(in database: SQLiteDatabase) throws -> [Int] {
    try database.query("SELECT version FROM note_schema_version ORDER BY version")
      .compactMap { $0["version"].flatMap(Int.init) }
  }
}
