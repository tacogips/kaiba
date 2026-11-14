import Foundation

public extension NoteService {
  @discardableResult
  func setNotebookReadOnly(notebookId: NotebookID, readOnly: Bool) throws -> Notebook {
    let notebook = try driver.withDatabase { database in
      try database.transaction { db in
        _ = try requireNotebook(notebookId, in: db)
        try db.execute(
          "UPDATE notebooks SET read_only = ?, updated_at = ?, updated_by = owner_user_id WHERE notebook_id = ?",
          bindings: [.int(readOnly ? 1 : 0), .text(NoteStoreClock.system.now()), .id(notebookId)]
        )
        return try requireNotebook(notebookId, in: db)
      }
    }
    publishChange(NoteChangeEvent(
      kind: NoteChangeEventKind.notebookReadOnly,
      notebookId: notebook.notebookId,
      tagNames: folderTagNames(of: notebook)
    ))
    return notebook
  }

  @discardableResult
  func setReadOnly(noteId: NoteID, readOnly: Bool) throws -> Note {
    try driver.withDatabase { database in
      try database.transaction { db in
        _ = try requireNote(noteId, in: db)
        try db.execute(
          "UPDATE notes SET read_only = ?, updated_at = ?, updated_by = (SELECT owner_user_id FROM notebooks WHERE notebook_id = notes.notebook_id) WHERE note_id = ?",
          bindings: [.int(readOnly ? 1 : 0), .text(NoteStoreClock.system.now()), .id(noteId)]
        )
        return try requireNote(noteId, in: db)
      }
    }
  }

  func deleteNote(noteId: NoteID) throws {
    try driver.withDatabase { database in
      try database.transaction { db in
        let note = try requireNote(noteId, in: db)
        let notebook = try requireNotebook(note.notebookId, in: db)
        guard !note.readOnly, !notebook.readOnly else {
          throw NoteServiceError.readOnly(noteId.rawValue)
        }
        try deleteNoteRows(noteId: noteId, in: db)
        try db.execute(
          "UPDATE notebooks SET updated_at = ?, updated_by = owner_user_id WHERE notebook_id = ?",
          bindings: [.text(NoteStoreClock.system.now()), .id(note.notebookId)]
        )
      }
    }
  }

  func deleteNotebook(notebookId: NotebookID) throws {
    let tagNames = try driver.withDatabase { database in
      try database.transaction { db in
        let notebook = try requireNotebook(notebookId, in: db)
        guard !notebook.readOnly else {
          throw NoteServiceError.readOnly(notebookId.rawValue)
        }
        let notes = try db.query(
          "SELECT note_id, read_only FROM notes WHERE notebook_id = ? ORDER BY note_number",
          bindings: [.id(notebookId)]
        )
        if let readOnlyNoteId = notes.first(where: { $0["read_only"] == "1" })?
          .identifier("note_id", as: NoteID.self) {
          throw NoteServiceError.readOnly(readOnlyNoteId.rawValue)
        }
        for row in notes {
          if let noteId = row.identifier("note_id", as: NoteID.self) {
            try deleteNoteRows(noteId: noteId, in: db)
          }
        }
        try db.execute("DELETE FROM notebook_tags WHERE notebook_id = ?", bindings: [.id(notebookId)])
        try db.execute("DELETE FROM notebook_files WHERE notebook_id = ?", bindings: [.id(notebookId)])
        try db.execute("DELETE FROM notebooks WHERE notebook_id = ?", bindings: [.id(notebookId)])
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
