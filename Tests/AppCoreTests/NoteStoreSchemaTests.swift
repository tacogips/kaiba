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
        ["content-kind", "document-kind", "event", "folder", "person", "source", "topic", "workflow", "year"]
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
      XCTAssertTrue(autoActions.allSatisfy { $0["workflow_id"] == NoteStoreSchema.autoTaggingWorkflowId })
      XCTAssertEqual(try database.query("PRAGMA foreign_keys").first?["foreign_keys"], "1")
      XCTAssertEqual(try schemaVersions(in: database), Array(1...NoteStoreSchema.currentVersion))

      try database.requireFTS5Available()
      try database.requireFTS5TrigramAvailable()
      let ftsSchema = try database.query(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'note_fts' LIMIT 1"
      ).first?["sql"]
      XCTAssertTrue(ftsSchema?.contains("tokenize='trigram'") == true)
    }
  }

  func testPrepareDispatchesV2MigrationFromVersionOneStore() throws {
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
      try database.execute("""
        CREATE VIRTUAL TABLE note_fts USING fts5(
          title, body, tags,
          content='',
          tokenize='unicode61'
        )
        """)
    }

    try NoteStoreSchema.prepare(on: driver)

    try driver.withDatabase { database in
      XCTAssertEqual(try schemaVersions(in: database), Array(1...NoteStoreSchema.currentVersion))
      let ftsSchema = try database.query(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'note_fts' LIMIT 1"
      ).first?["sql"]
      XCTAssertTrue(ftsSchema?.contains("tokenize='trigram'") == true)
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

  func testPrepareMigratesV9StoreByRemovingBoardStatusWithoutDataLoss() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let notebook = try service.createNotebook(
      title: "Existing notebook",
      metaJSON: #"{"source":"v5-fixture"}"#
    )
    let sourceNote = try service.createNote(
      notebookId: notebook.notebookId,
      title: "Existing note",
      bodyMarkdown: "Existing body",
      readOnly: true,
      tags: [NoteTagInput(name: "v5-tag")],
      provenance: .human,
      assignedBy: "v5-fixture",
      metaJSON: #"{"ordinal":1}"#
    )
    let relatedNote = try service.createNote(
      notebookId: notebook.notebookId,
      bodyMarkdown: "Related body",
      metaJSON: #"{"ordinal":2}"#
    )
    let link = try service.linkNotes(
      from: sourceNote.noteId,
      to: relatedNote.noteId,
      linkKind: "supports",
      provenance: .human
    )
    let noteFile = try service.attachFile(
      noteId: relatedNote.noteId,
      data: Data("note file".utf8),
      role: .related,
      mediaType: "text/plain",
      originalFilename: "note.txt",
      position: 4
    )
    let notebookFile = try service.attachNotebookFile(
      notebookId: notebook.notebookId,
      data: Data("notebook file".utf8),
      role: .sourceDocument,
      mediaType: "text/plain",
      originalFilename: "source.txt"
    )

    try driver.withDatabase { database in
      try database.execute("ALTER TABLE notebooks ADD COLUMN status TEXT NOT NULL DEFAULT 'none'")
      try database.execute("ALTER TABLE tags ADD COLUMN status_set_id TEXT")
      try database.execute("CREATE TABLE kanban_status_sets (set_id TEXT PRIMARY KEY)")
      try database.execute("CREATE TABLE kanban_statuses (status_id TEXT PRIMARY KEY)")
      try database.execute("DELETE FROM note_schema_version WHERE version = 10")
      XCTAssertEqual(try schemaVersions(in: database), Array(1...9))
    }

    try NoteStoreSchema.prepare(on: driver)

    try driver.withDatabase { database in
      let notebookRow = try XCTUnwrap(
        database.query(
          """
          SELECT notebook_id, title, read_only, json(meta_json) AS meta_json
          FROM notebooks WHERE notebook_id = ?
          """,
          bindings: [.text(notebook.notebookId)]
        ).first
      )
      XCTAssertEqual(notebookRow["notebook_id"], notebook.notebookId)
      XCTAssertEqual(notebookRow["title"], "Existing notebook")
      XCTAssertEqual(notebookRow["read_only"], "0")
      XCTAssertEqual(notebookRow["meta_json"], #"{"source":"v5-fixture"}"#)

      let noteRows = try database.query(
        """
        SELECT note_id, notebook_id, note_number, title, title_source, body_markdown,
          read_only, json(meta_json) AS meta_json
        FROM notes WHERE notebook_id = ? ORDER BY note_number
        """,
        bindings: [.text(notebook.notebookId)]
      )
      XCTAssertEqual(noteRows.map { $0["note_id"] }, [sourceNote.noteId, relatedNote.noteId])
      XCTAssertEqual(noteRows.map { $0["notebook_id"] }, [notebook.notebookId, notebook.notebookId])
      XCTAssertEqual(noteRows.map { $0["body_markdown"] }, ["Existing body", "Related body"])
      XCTAssertEqual(noteRows.map { $0["read_only"] }, ["1", "0"])
      XCTAssertEqual(noteRows.map { $0["meta_json"] }, [#"{"ordinal":1}"#, #"{"ordinal":2}"#])

      let tagNames = try database.query(
        """
        SELECT tags.name FROM note_tags
        INNER JOIN tags ON tags.tag_id = note_tags.tag_id
        WHERE note_tags.note_id = ? ORDER BY tags.name
        """,
        bindings: [.text(sourceNote.noteId)]
      ).compactMap { $0["name"] }
      XCTAssertEqual(tagNames, ["v5-tag"])

      let linkRow = try XCTUnwrap(database.query(
        """
        SELECT from_note_id, to_note_id, link_kind, provenance FROM note_links
        WHERE from_note_id = ? AND to_note_id = ?
        """,
        bindings: [.text(sourceNote.noteId), .text(relatedNote.noteId)]
      ).first)
      XCTAssertEqual(linkRow["from_note_id"], link.fromNoteId)
      XCTAssertEqual(linkRow["to_note_id"], link.toNoteId)
      XCTAssertEqual(linkRow["link_kind"], "supports")
      XCTAssertEqual(linkRow["provenance"], "human")

      let fileIds = try database.query(
        "SELECT file_id FROM files WHERE file_id IN (?, ?) ORDER BY file_id",
        bindings: [.text(noteFile.file.fileId), .text(notebookFile.file.fileId)]
      ).compactMap { $0["file_id"] }
      XCTAssertEqual(fileIds, [noteFile.file.fileId, notebookFile.file.fileId].sorted())
      let noteFileRow = try XCTUnwrap(database.query(
        "SELECT role, position FROM note_files WHERE note_id = ? AND file_id = ?",
        bindings: [.text(relatedNote.noteId), .text(noteFile.file.fileId)]
      ).first)
      XCTAssertEqual(noteFileRow["role"], "related")
      XCTAssertEqual(noteFileRow["position"], "4")
      let notebookFileRow = try XCTUnwrap(database.query(
        "SELECT role FROM notebook_files WHERE notebook_id = ? AND file_id = ?",
        bindings: [.text(notebook.notebookId), .text(notebookFile.file.fileId)]
      ).first)
      XCTAssertEqual(notebookFileRow["role"], "source-document")
      let notebookColumns = try database.query("PRAGMA table_info(notebooks)").compactMap { $0["name"] }
      let tagColumns = try database.query("PRAGMA table_info(tags)").compactMap { $0["name"] }
      XCTAssertFalse(notebookColumns.contains("status"))
      XCTAssertFalse(notebookColumns.contains("progress"))
      XCTAssertFalse(tagColumns.contains("status_set_id"))
      XCTAssertFalse(try database.tableExists("kanban_status_sets"))
      XCTAssertFalse(try database.tableExists("kanban_statuses"))
      XCTAssertEqual(try schemaVersions(in: database), Array(1...NoteStoreSchema.currentVersion))
    }
    let filesRoot = URL(fileURLWithPath: driver.databasePath)
      .deletingLastPathComponent()
      .appendingPathComponent("files", isDirectory: true)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: filesRoot.appendingPathComponent(try XCTUnwrap(noteFile.file.localPath)).path
      )
    )
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: filesRoot.appendingPathComponent(try XCTUnwrap(notebookFile.file.localPath)).path
      )
    )
  }

  func testPrepareRestoresLongTermMemoryKindTagOnV7Store() throws {
    let driver = try makeNoteDriver()
    try NoteStoreSchema.prepare(on: driver)
    try driver.withDatabase { database in
      // Fixture setup only: strip the v8 tag and marker so the store represents
      // a v7 shape that predates the long-term-memory notebook kind.
      try database.execute(
        "DELETE FROM tags WHERE name = ?",
        bindings: [.text(NoteStoreSchema.longTermMemoryNotebookKindTag)]
      )
      try database.execute("DELETE FROM note_schema_version WHERE version IN (8, 9, 10)")
      XCTAssertEqual(try schemaVersions(in: database), Array(1...7))
    }

    try NoteStoreSchema.prepare(on: driver)

    try driver.withDatabase { database in
      let tagRow = try XCTUnwrap(database.query(
        "SELECT tag_id, class_id, is_system FROM tags WHERE name = ?",
        bindings: [.text(NoteStoreSchema.longTermMemoryNotebookKindTag)]
      ).first)
      XCTAssertEqual(tagRow["tag_id"], NoteStoreSchema.longTermMemoryNotebookKindTagId)
      XCTAssertEqual(tagRow["class_id"], "document-kind")
      XCTAssertEqual(tagRow["is_system"], "1")
      XCTAssertEqual(try schemaVersions(in: database), Array(1...NoteStoreSchema.currentVersion))
    }
    XCTAssertEqual(
      try NoteService(driver: driver).longTermMemoryNotebook().title,
      "Kaiba Long-Term Memory"
    )
  }

  func testPrepareRejectsV5UserTagCollisionForLongTermMemoryIdentity() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let canonical = try service.longTermMemoryNotebook()
    try driver.withDatabase { database in
      try database.execute(
        "UPDATE tags SET is_system = 0 WHERE name = ?",
        bindings: [.text(NoteStoreSchema.longTermMemoryNotebookKindTag)]
      )
      try database.execute(
        """
        UPDATE notebook_tags
        SET provenance = 'human', assigned_by = 'v5-user', deletable = 1
        WHERE notebook_id = ?
        """,
        bindings: [.text(canonical.notebookId)]
      )
      try database.execute("ALTER TABLE notebooks DROP COLUMN read_only")
      try database.execute("DELETE FROM note_schema_version WHERE version IN (6, 7)")
    }

    XCTAssertThrowsError(try NoteStoreSchema.prepare(on: driver)) { error in
      XCTAssertEqual(
        error as? NoteStoreSchemaError,
        .systemTagCollision(name: NoteStoreSchema.longTermMemoryNotebookKindTag)
      )
    }
    try driver.withDatabase { database in
      XCTAssertEqual(try schemaVersions(in: database), Array(1...NoteStoreSchema.currentVersion))
      XCTAssertTrue(try database.query("PRAGMA table_info(notebooks)").contains { $0["name"] == "read_only" })
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

  func testPrepareRebuildsLegacyUnicodeFTSAsTrigram() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let note = try service.createNote(bodyMarkdown: "# 日本語ノート\nこれは日本語検索の検証です")
    try driver.withDatabase { database in
      try database.execute("DROP TABLE note_fts")
      try database.execute("""
        CREATE VIRTUAL TABLE note_fts USING fts5(
          title, body, tags,
          content='',
          tokenize='unicode61'
        )
        """)
      try database.execute("DELETE FROM note_fts_map")
      try database.execute(
        "INSERT INTO note_fts(rowid, title, body, tags) VALUES (1, ?, ?, '')",
        bindings: [.text(note.title ?? ""), .text(note.bodyMarkdown)]
      )
      try database.execute(
        "INSERT INTO note_fts_map (fts_rowid, note_id) VALUES (1, ?)",
        bindings: [.text(note.noteId)]
      )
    }

    try NoteStoreSchema.prepare(on: driver)

    try driver.withDatabase { database in
      let ftsSchema = try database.query(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'note_fts' LIMIT 1"
      ).first?["sql"]
      XCTAssertTrue(ftsSchema?.contains("tokenize='trigram'") == true)
      try database.execute("INSERT INTO note_fts(note_fts) VALUES('integrity-check')")
    }
    XCTAssertEqual(try service.searchNotes(query: "日本語検索").map(\.note.noteId), [note.noteId])
  }

  func testV7PartialIndexesEnforceParentScopedFolderAndNonFolderUniqueness() throws {
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
      ).compactMap { $0["tag_id"] }
      XCTAssertEqual(sharedRows, ["nested-a", "nested-b", "root-shared", "topic-shared"])
    }
  }

  func testV6ToV7RebuildPreservesTagAndAssignmentIdentity() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let notebook = try service.createNotebook(title: "Migrated", kindTagName: "migration-kind")
    let note = try service.createNote(
      notebookId: notebook.notebookId,
      bodyMarkdown: "# Migrated note",
      tags: [NoteTagInput(name: "migration-topic", classId: "topic")]
    )
    let parent = try service.defineTag(name: "migration-parent", classId: "folder")
    let child = try service.defineTag(
      name: "migration-child",
      classId: "folder",
      parentTagId: parent.tagId
    )
    let tagRowsBefore = try driver.withDatabase { database in
      try database.query(
        """
        SELECT tag_id, name, class_id, parent_tag_id, is_system, created_at
        FROM tags ORDER BY tag_id
        """
      )
    }
    let noteAssignmentsBefore = try driver.withDatabase { database in
      try database.query(
        """
        SELECT note_id, tag_id, provenance, assigned_by, deletable, created_at
        FROM note_tags ORDER BY note_id, tag_id
        """
      )
    }
    let notebookAssignmentsBefore = try driver.withDatabase { database in
      try database.query(
        """
        SELECT notebook_id, tag_id, provenance, assigned_by, deletable, created_at
        FROM notebook_tags ORDER BY notebook_id, tag_id
        """
      )
    }

    try downgradeTagSchemaToV6(on: driver)

    try NoteStoreSchema.prepare(on: driver)

    try driver.withDatabase { database in
      XCTAssertEqual(try database.query(
        """
        SELECT tag_id, name, class_id, parent_tag_id, is_system, created_at
        FROM tags ORDER BY tag_id
        """
      ), tagRowsBefore)
      let migratedChild = try XCTUnwrap(tagRowsBefore.first { $0["tag_id"] == child.tagId })
      XCTAssertEqual(migratedChild["parent_tag_id"], parent.tagId)
      XCTAssertEqual(try database.query(
        """
        SELECT note_id, tag_id, provenance, assigned_by, deletable, created_at
        FROM note_tags ORDER BY note_id, tag_id
        """
      ), noteAssignmentsBefore)
      XCTAssertEqual(try database.query(
        """
        SELECT notebook_id, tag_id, provenance, assigned_by, deletable, created_at
        FROM notebook_tags ORDER BY notebook_id, tag_id
        """
      ), notebookAssignmentsBefore)
      XCTAssertTrue(noteAssignmentsBefore.contains { $0["note_id"] == note.noteId })
      XCTAssertTrue(notebookAssignmentsBefore.contains { $0["notebook_id"] == notebook.notebookId })
      XCTAssertEqual(try schemaVersions(in: database), Array(1...NoteStoreSchema.currentVersion))
      XCTAssertEqual(try database.query("PRAGMA foreign_keys").first?["foreign_keys"], "1")
      XCTAssertTrue(try database.query("PRAGMA foreign_key_check").isEmpty)
      let indexes = Set(try database.query("PRAGMA index_list(tags)").compactMap { $0["name"] })
      XCTAssertTrue(indexes.contains("idx_tags_non_folder_name_unique"))
      XCTAssertTrue(indexes.contains("idx_tags_root_folder_name_unique"))
      XCTAssertTrue(indexes.contains("idx_tags_nested_folder_parent_name_unique"))
    }
  }

  func testV7MigrationPreCommitFailureRollsBackAndEvictsFailedHandle() throws {
    let driver = try makeNoteDriver()
    try NoteStoreSchema.prepare(on: driver)
    try downgradeTagSchemaToV6(on: driver)
    try driver.withDatabase { database in
      try database.execute("CREATE TEMP TABLE v7_failed_handle_marker (value TEXT)")
    }
    let recorder = V7MigrationFaultRecorder(failingAt: .beforeRebuildCommit)
    NoteStoreSchema.setV7MigrationFaultInjectorForTesting(recorder.inject)
    defer {
      NoteStoreSchema.setV7MigrationFaultInjectorForTesting(nil)
    }

    XCTAssertThrowsError(try NoteStoreSchema.prepare(on: driver))
    XCTAssertEqual(recorder.count(for: .beforeRebuildCommit), 1)
    try driver.withDatabase { database in
      XCTAssertTrue(try database.query(
        "SELECT name FROM sqlite_temp_master WHERE name = 'v7_failed_handle_marker'"
      ).isEmpty)
      XCTAssertEqual(try database.query("PRAGMA foreign_keys").first?["foreign_keys"], "1")
      XCTAssertFalse(try schemaVersions(in: database).contains(7))
      let tableSQL = try database.query(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'tags'"
      ).first?["sql"]?.lowercased()
      XCTAssertTrue(tableSQL?.contains("name text not null unique") == true)
    }

    NoteStoreSchema.setV7MigrationFaultInjectorForTesting(nil)
    try NoteStoreSchema.prepare(on: driver)
    try assertPreparedV7Store(on: driver)
  }

  func testV7MigrationPostCommitAndRestorationFailuresRecoverMarkerlessSchema() throws {
    for checkpoint in [
      NoteStoreSchemaV7MigrationCheckpoint.afterRebuildCommit,
      .beforeForeignKeyRestorationVerification
    ] {
      let driver = try makeNoteDriver(function: "\(#function)-\(checkpoint)")
      try NoteStoreSchema.prepare(on: driver)
      try downgradeTagSchemaToV6(on: driver)
      try driver.withDatabase { database in
        try database.execute("CREATE TEMP TABLE v7_failed_handle_marker (value TEXT)")
      }
      let recorder = V7MigrationFaultRecorder(failingAt: checkpoint)
      NoteStoreSchema.setV7MigrationFaultInjectorForTesting(recorder.inject)

      XCTAssertThrowsError(try NoteStoreSchema.prepare(on: driver))
      XCTAssertEqual(recorder.count(for: checkpoint), 1)
      try driver.withDatabase { database in
        XCTAssertTrue(try database.query(
          "SELECT name FROM sqlite_temp_master WHERE name = 'v7_failed_handle_marker'"
        ).isEmpty)
        XCTAssertEqual(try database.query("PRAGMA foreign_keys").first?["foreign_keys"], "1")
        XCTAssertFalse(try schemaVersions(in: database).contains(7))
        let indexes = Set(try database.query("PRAGMA index_list(tags)").compactMap { $0["name"] })
        XCTAssertTrue(indexes.contains("idx_tags_nested_folder_parent_name_unique"))
      }

      NoteStoreSchema.setV7MigrationFaultInjectorForTesting(nil)
      try NoteStoreSchema.prepare(on: driver)
      XCTAssertEqual(recorder.count(for: .beforeRebuildCommit), 1)
      try assertPreparedV7Store(on: driver)
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

private enum InjectedV7MigrationFailure: Error {
  case requested
}

private final class V7MigrationFaultRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private let failingCheckpoint: NoteStoreSchemaV7MigrationCheckpoint
  private var counts: [String: Int] = [:]

  init(failingAt checkpoint: NoteStoreSchemaV7MigrationCheckpoint) {
    failingCheckpoint = checkpoint
  }

  func inject(_ checkpoint: NoteStoreSchemaV7MigrationCheckpoint) throws {
    lock.lock()
    counts[key(for: checkpoint), default: 0] += 1
    lock.unlock()
    if checkpoint == failingCheckpoint {
      throw InjectedV7MigrationFailure.requested
    }
  }

  func count(for checkpoint: NoteStoreSchemaV7MigrationCheckpoint) -> Int {
    lock.lock()
    defer {
      lock.unlock()
    }
    return counts[key(for: checkpoint), default: 0]
  }

  private func key(for checkpoint: NoteStoreSchemaV7MigrationCheckpoint) -> String {
    String(describing: checkpoint)
  }
}

private func downgradeTagSchemaToV6(on driver: NoteDatabaseDriving) throws {
  try driver.withDatabase { database in
    try database.execute("PRAGMA foreign_keys = OFF")
    try database.transaction { db in
      try db.execute(
        """
        CREATE TABLE tags_v6 (
          tag_id TEXT PRIMARY KEY,
          name TEXT NOT NULL UNIQUE,
          class_id TEXT REFERENCES tag_classes(class_id),
          parent_tag_id TEXT REFERENCES tags(tag_id),
          is_system INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL
        )
        """
      )
      try db.execute(
        """
        INSERT INTO tags_v6
        SELECT tag_id, name, class_id, parent_tag_id, is_system, created_at
        FROM tags
        """
      )
      try db.execute("DROP TABLE tags")
      try db.execute("ALTER TABLE tags_v6 RENAME TO tags")
      try db.execute("DELETE FROM note_schema_version WHERE version = 7")
    }
    try database.execute("PRAGMA foreign_keys = ON")
  }
}

private func assertPreparedV7Store(on driver: NoteDatabaseDriving) throws {
  try driver.withDatabase { database in
    XCTAssertEqual(try schemaVersions(in: database), Array(1...NoteStoreSchema.currentVersion))
    XCTAssertEqual(try database.query("PRAGMA foreign_keys").first?["foreign_keys"], "1")
    XCTAssertTrue(try database.query("PRAGMA foreign_key_check").isEmpty)
    let indexes = Set(try database.query("PRAGMA index_list(tags)").compactMap { $0["name"] })
    XCTAssertTrue(indexes.contains("idx_tags_non_folder_name_unique"))
    XCTAssertTrue(indexes.contains("idx_tags_root_folder_name_unique"))
    XCTAssertTrue(indexes.contains("idx_tags_nested_folder_parent_name_unique"))
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
