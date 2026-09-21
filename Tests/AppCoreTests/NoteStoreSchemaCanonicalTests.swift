import Foundation
@testable import AppCore
import XCTest

/// Schema-level guards for the entity-page canonical binding and the Quick
/// Memos kind tag (`design-docs/specs/note-capture-and-entity-pages.md`, E1
/// and C3). Kept beside `NoteStoreSchemaTests` and reusing its `NoteTestCase`
/// base and `makeNoteDriver()` helper.
final class NoteStoreSchemaCanonicalTests: NoteTestCase {
  func testTagsTableCarriesNullableCanonicalNoteColumn() throws {
    let driver = try makeNoteDriver()
    try NoteStoreSchema.prepare(on: driver)

    try driver.withDatabase { database in
      let column = try XCTUnwrap(
        try database.query("PRAGMA table_info(tags)")
          .first { $0["name"] == "canonical_note_id" },
        "tags is missing the canonical_note_id column"
      )
      XCTAssertEqual(column["type"], "TEXT")
      XCTAssertEqual(column["notnull"], "0")
      XCTAssertNil(column["dflt_value"])

      let foreignKey = try XCTUnwrap(
        try database.query("PRAGMA foreign_key_list(tags)")
          .first { $0["from"] == "canonical_note_id" },
        "canonical_note_id is not a foreign key"
      )
      XCTAssertEqual(foreignKey["table"], "notes")
      XCTAssertEqual(foreignKey["to"], "note_id")
      XCTAssertEqual(foreignKey["on_delete"], "SET NULL")
    }
  }

  func testDeletingCanonicalNoteClearsTheTagBinding() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let notebook = try service.createNotebook(title: "Entities")
    let note = try service.createNote(
      notebookId: notebook.notebookId,
      title: "Kaiba",
      bodyMarkdown: "The canonical description."
    )
    let tag = try service.defineTag(name: "kaiba", classId: .topic)

    try driver.withDatabase { database in
      try database.execute(
        "UPDATE tags SET canonical_note_id = ? WHERE tag_id = ?",
        bindings: [.id(note.noteId), .id(tag.tagId)]
      )
      XCTAssertEqual(
        try canonicalNoteId(ofTag: tag.tagId, in: database),
        note.noteId
      )
    }

    try service.deleteNote(noteId: note.noteId)

    try driver.withDatabase { database in
      let row = try XCTUnwrap(
        try database.query(
          "SELECT tag_id, canonical_note_id FROM tags WHERE tag_id = ?",
          bindings: [.id(tag.tagId)]
        ).first,
        "deleting the canonical note must not delete the tag"
      )
      XCTAssertNil(row["canonical_note_id"])
    }
  }

  func testCanonicalNoteBindingRejectsUnknownNote() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let tag = try service.defineTag(name: "kaiba", classId: .topic)

    XCTAssertThrowsError(
      try driver.withDatabase { database in
        try database.execute(
          "UPDATE tags SET canonical_note_id = 'note-does-not-exist' WHERE tag_id = ?",
          bindings: [.id(tag.tagId)]
        )
      },
      "the foreign key must reject a canonical note that does not exist"
    )

    try driver.withDatabase { database in
      XCTAssertNil(try canonicalNoteId(ofTag: tag.tagId, in: database))
    }
  }

  func testFreshStoreSeedsQuickMemoNotebookKindTag() throws {
    XCTAssertEqual(NoteStoreSchema.quickMemoNotebookKindTag, "notebook-kind:quick-memo")

    let driver = try makeNoteDriver()
    try NoteStoreSchema.prepare(on: driver)

    try driver.withDatabase { database in
      let row = try XCTUnwrap(
        try database.query(
          "SELECT tag_id, class_id, is_system FROM tags WHERE name = ?",
          bindings: [.text(NoteStoreSchema.quickMemoNotebookKindTag)]
        ).first,
        "a fresh store must seed the quick-memo kind tag"
      )
      XCTAssertEqual(
        row.identifier("tag_id", as: TagID.self),
        NoteStoreSchema.quickMemoNotebookKindTagId
      )
      XCTAssertEqual(row.identifier("class_id", as: TagClassID.self), .documentKind)
      XCTAssertEqual(row["is_system"], "1")
    }
  }

  func testPrepareRestoresDeletedQuickMemoKindTag() throws {
    let driver = try makeNoteDriver()
    try NoteStoreSchema.prepare(on: driver)
    try driver.withDatabase { database in
      try database.execute(
        "DELETE FROM tags WHERE name = ?",
        bindings: [.text(NoteStoreSchema.quickMemoNotebookKindTag)]
      )
    }

    try NoteStoreSchema.prepare(on: driver)

    try driver.withDatabase { database in
      let row = try XCTUnwrap(
        try database.query(
          "SELECT tag_id FROM tags WHERE name = ?",
          bindings: [.text(NoteStoreSchema.quickMemoNotebookKindTag)]
        ).first
      )
      XCTAssertEqual(
        row.identifier("tag_id", as: TagID.self),
        NoteStoreSchema.quickMemoNotebookKindTagId
      )
    }
  }

  func testCurrentVersionIsTwentyAndAVersionNineteenStoreIsRefused() throws {
    XCTAssertEqual(NoteStoreSchema.currentVersion, 20)

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
        "INSERT INTO note_schema_version (version, applied_at) VALUES (19, '2026-09-21T00:00:00Z')"
      )
    }

    XCTAssertThrowsError(try NoteStoreSchema.prepare(on: driver)) { error in
      XCTAssertEqual(
        error as? NoteStoreSchemaError,
        .unsupportedLegacyVersion(found: 19, required: 20)
      )
    }
  }

  private func canonicalNoteId(
    ofTag tagId: TagID,
    in database: SQLiteDatabase
  ) throws -> NoteID? {
    try database.query(
      "SELECT canonical_note_id FROM tags WHERE tag_id = ?",
      bindings: [.id(tagId)]
    ).first?.identifier("canonical_note_id", as: NoteID.self)
  }
}
