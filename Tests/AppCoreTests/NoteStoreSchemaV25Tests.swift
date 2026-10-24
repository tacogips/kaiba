import Foundation
@testable import AppCore
import XCTest

/// The ERD-generated v25 baseline (`design-docs/specs/note-store-schema-v25.md`):
/// a fresh store runs the generated DDL once, and every older store is refused.
final class NoteStoreSchemaV25Tests: NoteTestCase {
  func testGeneratedStatementsMatchTheCommittedSQL() throws {
    let sqlURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("schema/note-store.sqlite.sql")
    let committed = try String(contentsOf: sqlURL, encoding: .utf8)
    XCTAssertEqual(noteStoreSchemaSQL + "\n", committed, "run `mise run schema:generate`")
    XCTAssertEqual(
      NoteStoreSchema.generatedSchemaStatements,
      NoteStoreSchema.splitSchemaStatements(committed)
    )
    XCTAssertFalse(NoteStoreSchema.generatedSchemaStatements.contains { $0.hasPrefix("PRAGMA") })
  }

  func testFreshStoreCreatesEveryERDObjectAndRecordsVersion25() throws {
    let driver = try makeNoteDriver()
    try NoteStoreSchema.prepare(on: driver)

    try driver.withDatabase { database in
      XCTAssertEqual(
        try database.query("SELECT version FROM note_schema_version").compactMap { $0["version"] },
        ["25"]
      )
      let expected = Set(NoteStoreSchema.generatedSchemaStatements.compactMap(createdObjectName))
      XCTAssertGreaterThan(expected.count, 50)
      let present = Set(try database.query(
        "SELECT name FROM sqlite_master WHERE type IN ('table', 'index')"
      ).compactMap { $0["name"] })
      XCTAssertTrue(expected.isSubset(of: present), "missing: \(expected.subtracting(present).sorted())")
      for table in ["document_pages", "note_translations", "translation_jobs", "notebook_revisions", "note_fts"] {
        XCTAssertTrue(try database.tableExists(table), table)
      }
      XCTAssertFalse(try database.query("PRAGMA table_info(notes)").contains { $0["name"] == "search_text" })
      // Every ERD table is STRICT (sqlite.strict in schema/note-store.erd.jsonl).
      let strictTables = try database.query("PRAGMA table_list").filter { $0["type"] == "table" && $0["strict"] == "1" }
      for statement in NoteStoreSchema.generatedSchemaStatements where statement.hasPrefix("CREATE TABLE") {
        XCTAssertTrue(statement.contains(") STRICT"), statement)
      }
      XCTAssertEqual(
        strictTables.count,
        NoteStoreSchema.generatedSchemaStatements.filter { $0.hasPrefix("CREATE TABLE") }.count
      )
    }
  }

  func testOlderStoresAreRejectedWithoutModification() throws {
    for version in [1, 24] {
      let driver = try makeNoteDriver()
      try driver.withDatabase { database in
        try database.execute("CREATE TABLE note_schema_version (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)")
        try database.execute(
          "INSERT INTO note_schema_version (version, applied_at) VALUES (?, 'then')",
          bindings: [.int(Int64(version))]
        )
      }
      XCTAssertThrowsError(try NoteStoreSchema.prepare(on: driver)) { error in
        XCTAssertEqual(
          error as? NoteStoreSchemaError,
          .unsupportedLegacyVersion(found: version, required: NoteStoreSchema.currentVersion)
        )
      }
      try driver.withDatabase { database in
        XCTAssertEqual(
          try database.query("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0["name"] },
          ["note_schema_version"]
        )
      }
    }
  }

  func testFutureStoreIsRejected() throws {
    let driver = try makeNoteDriver()
    try NoteStoreSchema.prepare(on: driver)
    try driver.withDatabase { database in
      try database.execute("INSERT INTO note_schema_version (version, applied_at) VALUES (26, 'then')")
    }
    XCTAssertThrowsError(try NoteStoreSchema.prepare(on: driver)) { error in
      XCTAssertEqual(
        error as? NoteStoreSchemaError,
        .unsupportedFutureVersion(found: 26, supported: NoteStoreSchema.currentVersion)
      )
    }
  }

  func testNonEmptyDatabaseWithoutVersionTableIsRejected() throws {
    let driver = try makeNoteDriver()
    try driver.withDatabase { database in
      try database.execute("CREATE TABLE unrelated (value TEXT)")
    }
    XCTAssertThrowsError(try NoteStoreSchema.prepare(on: driver)) { error in
      XCTAssertEqual(
        error as? NoteStoreSchemaError,
        .storeInvariant("database is not a kaiba note store")
      )
    }
    try driver.withDatabase { database in
      XCTAssertFalse(try database.tableExists("notes"))
    }
  }

  func testDocumentPageConstraintsRejectInconsistentTextState() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let notebook = try service.createNotebook(title: "Pages")
    let note = try service.createNote(notebookId: notebook.notebookId, title: nil, bodyMarkdown: "")
    try driver.withDatabase { database in
      try database.execute(
        """
        INSERT INTO files (file_id, storage_kind, local_path, media_type, byte_size, sha256, created_at)
        VALUES ('file-origin', 'local', 'files/origin', 'application/pdf', 1, 'abc', 'now')
        """
      )
      let insert = """
        INSERT INTO document_pages (
          note_id, origin_file_id, page_number, text, text_status, text_source, analysis_json
        ) VALUES (?, 'file-origin', ?, '', ?, ?, jsonb('{"writingMode":"unknown","binding":"unknown"}'))
        """
      let invalid: [InvalidPageRow] = [
        InvalidPageRow(page: 1, status: "complete", source: .null),
        InvalidPageRow(page: 1, status: "pending", source: .text("ocr")),
        InvalidPageRow(page: 1, status: "complete", source: .text("handwriting")),
        InvalidPageRow(page: 1, status: "unknown", source: .null),
        InvalidPageRow(page: 0, status: "pending", source: .null)
      ]
      for row in invalid {
        XCTAssertThrowsError(
          try database.execute(insert, bindings: [.id(note.noteId), .int(row.page), .text(row.status), row.source]),
          "\(row)"
        )
      }
      XCTAssertThrowsError(try database.execute(
        """
        INSERT INTO document_pages (note_id, origin_file_id, page_number, text_status, analysis_json)
        VALUES (?, 'file-missing', 1, 'pending', jsonb('{}'))
        """,
        bindings: [.id(note.noteId)]
      ), "origin file must exist")
      try database.execute(insert, bindings: [.id(note.noteId), .int(1), .text("complete"), .text("ocr")])
    }
  }
}

private struct InvalidPageRow {
  var page: Int64
  var status: String
  var source: SQLiteValue
}

private func createdObjectName(_ statement: String) -> String? {
  let pattern = #"^CREATE (?:UNIQUE )?(?:TABLE|INDEX) "([^"]+)""#
  guard let regex = try? NSRegularExpression(pattern: pattern),
        let match = regex.firstMatch(in: statement, range: NSRange(statement.startIndex..., in: statement)),
        let range = Range(match.range(at: 1), in: statement) else {
    return nil
  }
  return String(statement[range])
}
