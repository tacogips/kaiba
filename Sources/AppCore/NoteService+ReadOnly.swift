import Foundation

public extension NoteService {
  @discardableResult
  func setReadOnly(noteId: String, readOnly: Bool) throws -> Note {
    try driver.withDatabase { database in
      try database.transaction { db in
        _ = try requireNote(noteId, in: db)
        try db.execute(
          "UPDATE notes SET read_only = ?, updated_at = ? WHERE note_id = ?",
          bindings: [.int(readOnly ? 1 : 0), .text(NoteStoreClock.system.now()), .text(noteId)]
        )
        return try requireNote(noteId, in: db)
      }
    }
  }

  func deleteNote(noteId: String) throws {
    try driver.withDatabase { database in
      try database.transaction { db in
        let note = try requireNote(noteId, in: db)
        let notebook = try requireNotebook(note.notebookId, in: db)
        guard !note.readOnly, !notebook.readOnly else {
          throw NoteServiceError.readOnly(noteId)
        }
        try deleteNoteRows(noteId: noteId, in: db)
        try db.execute(
          "UPDATE notebooks SET updated_at = ? WHERE notebook_id = ?",
          bindings: [.text(NoteStoreClock.system.now()), .text(note.notebookId)]
        )
      }
    }
  }

  func deleteNotebook(notebookId: String) throws {
    let tagNames = try driver.withDatabase { database in
      try database.transaction { db in
        let notebook = try requireNotebook(notebookId, in: db)
        guard !notebook.readOnly else {
          throw NoteServiceError.readOnly(notebookId)
        }
        let notes = try db.query(
          "SELECT note_id, read_only FROM notes WHERE notebook_id = ? ORDER BY note_number",
          bindings: [.text(notebookId)]
        )
        if let readOnlyNoteId = notes.first(where: { $0["read_only"] == "1" })?["note_id"] {
          throw NoteServiceError.readOnly(readOnlyNoteId)
        }
        for row in notes {
          if let noteId = row["note_id"] {
            try deleteNoteRows(noteId: noteId, in: db)
          }
        }
        try db.execute("DELETE FROM notebook_tags WHERE notebook_id = ?", bindings: [.text(notebookId)])
        try db.execute("DELETE FROM notebook_files WHERE notebook_id = ?", bindings: [.text(notebookId)])
        try db.execute("DELETE FROM notebooks WHERE notebook_id = ?", bindings: [.text(notebookId)])
        return folderTagNames(of: notebook)
      }
    }
    publishChange(NoteChangeEvent(
      kind: NoteChangeEventKind.notebookDeleted,
      notebookId: notebookId,
      tagNames: tagNames
    ))
  }
}
