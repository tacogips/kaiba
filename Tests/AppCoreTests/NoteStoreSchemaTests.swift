import Foundation
@testable import AppCore
import XCTest

class NoteTestCase: XCTestCase {
  override func tearDownWithError() throws {
    try super.tearDownWithError()
    try removeCurrentNoteTestRoot()
  }

  private func removeCurrentNoteTestRoot() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/AppCoreTests", isDirectory: true)
      .appendingPathComponent(currentTestFunctionName, isDirectory: true)
    if FileManager.default.fileExists(atPath: root.path) {
      try FileManager.default.removeItem(at: root)
    }
  }

  private var currentTestFunctionName: String {
    var candidate = name
    if let last = candidate.split(separator: " ").last {
      candidate = String(last)
    }
    if let last = candidate.split(separator: "/").last {
      candidate = String(last)
    }
    return candidate
      .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
      .replacingOccurrences(of: "()", with: "")
  }
}

final class NoteStoreSchemaTests: NoteTestCase {
  func testPrepareCreatesSchemaAndSeedsRowsIdempotently() throws {
    let driver = try makeNoteDriver()

    try NoteStoreSchema.prepare(on: driver)
    try NoteStoreSchema.prepare(on: driver)

    try driver.withDatabase { database in
      XCTAssertTrue(try database.tableExists("notebooks"))
      XCTAssertTrue(try database.tableExists("notes"))
      XCTAssertTrue(try database.tableExists("note_fts_map"))
      XCTAssertEqual(
        try NoteStoreSchema.seededTagClassIds(in: database),
        [
        .contentKind, .documentKind, .event, .folder, .person, .source, .topic, .workflow, .year
      ]
      )

      let kindTags = try database.query(
        """
        SELECT name
        FROM tags
        WHERE is_system = 1 AND name LIKE 'notebook-kind:%'
        ORDER BY name
        """
      ).compactMap { $0["name"] }
      XCTAssertEqual(
        kindTags,
        [
          "notebook-kind:agent-conversation",
          "notebook-kind:imported-material",
          "notebook-kind:long-term-memory",
          "notebook-kind:translation",
          "notebook-kind:user-memo"
        ]
      )

      let autoActions = try database.query("SELECT trigger, workflow_id FROM auto_actions ORDER BY trigger")
      XCTAssertEqual(
        autoActions.map { $0["trigger"] },
        ["note-created", "note-updated", "notebook-created"]
      )
      XCTAssertTrue(autoActions.allSatisfy { $0.identifier("workflow_id", as: WorkflowID.self) == NoteStoreSchema.autoTaggingWorkflowId })
      XCTAssertEqual(try database.query("PRAGMA foreign_keys").first?["foreign_keys"], "1")
      XCTAssertEqual(try schemaVersions(in: database), [NoteStoreSchema.currentVersion])

      try database.requireFTS5Available()
      try database.requireFTS5TrigramAvailable()
      let ftsSchema = try database.query(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'note_fts' LIMIT 1"
      ).first?["sql"]
      XCTAssertTrue(ftsSchema?.contains("tokenize='trigram'") == true)
    }
  }

  func testPrepareRejectsOlderSchemaVersion() throws {
    let driver = try makeNoteDriver()
    try driver.withDatabase { database in
      try database.execute(
        """
        CREATE TABLE note_schema_version (
          version INTEGER PRIMARY KEY,
          applied_at TEXT NOT NULL
        )
        """
      )
      try database.execute(
        "INSERT INTO note_schema_version (version, applied_at) VALUES (1, '2026-07-04T00:00:00Z')"
      )
    }

    XCTAssertThrowsError(try NoteStoreSchema.prepare(on: driver)) { error in
      XCTAssertEqual(
        error as? NoteStoreSchemaError,
        .unsupportedLegacyVersion(found: 1, required: NoteStoreSchema.currentVersion)
      )
    }
  }

  func testPrepareCachesSQLiteCapabilityProbeAcrossNoteStores() throws {
    NoteSQLiteCapabilityCache.resetForTesting()
    defer {
      NoteSQLiteCapabilityCache.resetForTesting()
    }
    let first = try makeNoteDriver()
    let second = try makeNoteDriver()

    try NoteStoreSchema.prepare(on: first)
    try NoteStoreSchema.prepare(on: first)
    try NoteStoreSchema.prepare(on: second)

    XCTAssertEqual(NoteSQLiteCapabilityCache.probeRunCountForTesting(), 1)
    try first.withDatabase { database in
      XCTAssertTrue(try database.tableExists("notes"))
    }
    try second.withDatabase { database in
      XCTAssertTrue(try database.tableExists("notes"))
    }
  }

  func testPrepareRestoresDeletedLongTermMemoryKindTag() throws {
    let driver = try makeNoteDriver()
    try NoteStoreSchema.prepare(on: driver)
    try driver.withDatabase { database in
      try database.execute(
        "DELETE FROM tags WHERE name = ?",
        bindings: [.text(NoteStoreSchema.longTermMemoryNotebookKindTag)]
      )
    }

    try NoteStoreSchema.prepare(on: driver)

    try driver.withDatabase { database in
      let tagRow = try XCTUnwrap(database.query(
        "SELECT tag_id, class_id, is_system FROM tags WHERE name = ?",
        bindings: [.text(NoteStoreSchema.longTermMemoryNotebookKindTag)]
      ).first)
      XCTAssertEqual(tagRow.identifier("tag_id", as: TagID.self), NoteStoreSchema.longTermMemoryNotebookKindTagId)
      XCTAssertEqual(tagRow.identifier("class_id", as: TagClassID.self), .documentKind)
      XCTAssertEqual(tagRow["is_system"], "1")
      XCTAssertEqual(try schemaVersions(in: database), [NoteStoreSchema.currentVersion])
    }
    XCTAssertEqual(
      try NoteService(driver: driver).longTermMemoryNotebook().title,
      "Kaiba Long-Term Memory"
    )
  }

  func testPrepareRejectsUserTagCollisionForLongTermMemoryIdentity() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    _ = try service.longTermMemoryNotebook()
    try driver.withDatabase { database in
      try database.execute(
        "UPDATE tags SET is_system = 0 WHERE name = ?",
        bindings: [.text(NoteStoreSchema.longTermMemoryNotebookKindTag)]
      )
    }

    XCTAssertThrowsError(try NoteStoreSchema.prepare(on: driver)) { error in
      XCTAssertEqual(
        error as? NoteStoreSchemaError,
        .systemTagCollision(name: NoteStoreSchema.longTermMemoryNotebookKindTag)
      )
    }
    try driver.withDatabase { database in
      let tagRow = try XCTUnwrap(database.query(
        "SELECT is_system FROM tags WHERE name = ?",
        bindings: [.text(NoteStoreSchema.longTermMemoryNotebookKindTag)]
      ).first)
      XCTAssertEqual(tagRow["is_system"], "0")
    }
  }

  func testFileLocatorConstraintRejectsInvalidLocalRows() throws {
    let driver = try makeNoteDriver()
    try NoteStoreSchema.prepare(on: driver)

    XCTAssertThrowsError(
      try driver.withDatabase { database in
        try database.execute(
          """
          INSERT INTO files (
            file_id, storage_kind, media_type, byte_size, sha256, created_at
          ) VALUES ('file-1', 'local', 'text/plain', 1, 'abc', '2026-07-04T00:00:00Z')
          """
        )
      }
    )
  }

  func testPrepareRejectsFutureSchemaVersion() throws {
    let driver = try makeNoteDriver()
    try NoteStoreSchema.prepare(on: driver)
    try driver.withDatabase { database in
      try database.execute(
        "INSERT INTO note_schema_version (version, applied_at) VALUES (?, ?)",
        bindings: [.int(999), .text("2026-07-04T00:00:00Z")]
      )
    }

    XCTAssertThrowsError(try NoteStoreSchema.prepare(on: driver)) { error in
      XCTAssertEqual(
        error as? NoteStoreSchemaError,
        .unsupportedFutureVersion(found: 999, supported: NoteStoreSchema.currentVersion)
      )
    }
  }

  func testSQLiteDriverReusesConnectionBetweenOperations() throws {
    guard let driver = try makeNoteDriver() as? SQLiteNoteDatabaseDriver else {
      XCTFail("Expected SQLite note database driver")
      return
    }
    let firstDatabase = try driver.withDatabase { ObjectIdentifier($0) }
    let secondDatabase = try driver.withDatabase { ObjectIdentifier($0) }

    XCTAssertEqual(firstDatabase, secondDatabase)
  }

  func testTagPartialIndexesEnforceParentScopedFolderAndNonFolderUniqueness() throws {
    let driver = try makeNoteDriver()
    try NoteStoreSchema.prepare(on: driver)
    try driver.withDatabase { database in
      let insert = """
        INSERT INTO tags (
          tag_id, name, class_id, parent_tag_id, is_system, created_at
        ) VALUES (?, ?, ?, ?, 0, '2026-08-04T00:00:00Z')
        """
      try database.execute(
        insert,
        bindings: [.text("parent-a"), .text("Parent A"), .text("folder"), .null]
      )
      try database.execute(
        insert,
        bindings: [.text("parent-b"), .text("Parent B"), .text("folder"), .null]
      )
      try database.execute(
        insert,
        bindings: [.text("root-shared"), .text("Shared"), .text("folder"), .null]
      )
      try database.execute(
        insert,
        bindings: [.text("nested-a"), .text("Shared"), .text("folder"), .text("parent-a")]
      )
      try database.execute(
        insert,
        bindings: [.text("nested-b"), .text("Shared"), .text("folder"), .text("parent-b")]
      )
      try database.execute(
        insert,
        bindings: [.text("topic-shared"), .text("Shared"), .text("topic"), .null]
      )

      XCTAssertThrowsError(try database.execute(
        insert,
        bindings: [.text("root-duplicate"), .text("Shared"), .text("folder"), .null]
      )) { error in
        guard let sqliteError = error as? SQLiteError else {
          return XCTFail("expected root-folder UNIQUE constraint, got \(error)")
        }
        XCTAssertTrue(isSQLiteUniqueConstraintViolation(sqliteError))
      }
      XCTAssertThrowsError(try database.execute(
        insert,
        bindings: [.text("nested-duplicate"), .text("Shared"), .text("folder"), .text("parent-a")]
      )) { error in
        guard let sqliteError = error as? SQLiteError else {
          return XCTFail("expected nested-folder UNIQUE constraint, got \(error)")
        }
        XCTAssertTrue(isSQLiteUniqueConstraintViolation(sqliteError))
      }
      XCTAssertThrowsError(try database.execute(
        insert,
        bindings: [.text("classless-duplicate"), .text("Shared"), .null, .null]
      )) { error in
        guard let sqliteError = error as? SQLiteError else {
          return XCTFail("expected non-folder UNIQUE constraint, got \(error)")
        }
        XCTAssertTrue(isSQLiteUniqueConstraintViolation(sqliteError))
      }

      let sharedRows = try database.query(
        "SELECT tag_id FROM tags WHERE name = 'Shared' ORDER BY tag_id"
      ).compactMap { $0.identifier("tag_id", as: TagID.self) }
      XCTAssertEqual(
        sharedRows,
        [TagID("nested-a"), TagID("nested-b"), TagID("root-shared"), TagID("topic-shared")]
      )
    }
  }

  func testThrownDatabaseBodyEvictsHandleAndRestoresConfiguredForeignKeys() throws {
    enum InjectedFailure: Error { case fail }
    let root = try makeNoteRoot()
    let path = URL(fileURLWithPath: root).appendingPathComponent("eviction.sqlite").path
    let connection = SQLiteNoteDatabaseConnection(
      databasePath: path,
      openOptions: SQLiteOpenOptions(requireFTS5: true)
    )
    XCTAssertThrowsError(try connection.withDatabase { database in
      try database.execute("CREATE TEMP TABLE failed_handle_marker (value TEXT)")
      try database.execute("PRAGMA foreign_keys = OFF")
      throw InjectedFailure.fail
    })
    try connection.withDatabase { database in
      XCTAssertTrue(try database.query(
        "SELECT name FROM sqlite_temp_master WHERE name = 'failed_handle_marker'"
      ).isEmpty)
      XCTAssertEqual(try database.query("PRAGMA foreign_keys").first?["foreign_keys"], "1")
    }
  }

}

private func schemaVersions(in database: SQLiteDatabase) throws -> [Int] {
  try database.query("SELECT version FROM note_schema_version ORDER BY version")
    .compactMap { row in
      row["version"].flatMap(Int.init)
    }
}

func makeNoteRoot(function: String = #function) throws -> String {
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    .appendingPathComponent("tmp/AppCoreTests", isDirectory: true)
    .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root.path
}

func makeNoteDriver(function: String = #function) throws -> NoteDatabaseDriving {
  SQLiteNoteDatabaseDriver(noteRoot: try makeNoteRoot(function: function))
}
