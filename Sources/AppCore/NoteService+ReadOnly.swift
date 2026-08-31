import Foundation

public extension NoteService {
  @discardableResult
  func setNotebookReadOnly(notebookId: NotebookID, readOnly: Bool) throws -> Notebook {
    let notebook = try driver.withDatabase { database in
      try database.transaction { db in
        let existing = try requireNotebook(notebookId, in: db)
        try db.execute(
          "UPDATE notebooks SET read_only = ?, updated_at = ?, updated_by = owner_user_id WHERE notebook_id = ?",
          bindings: [.int(readOnly ? 1 : 0), .text(NoteStoreClock.system.now()), .id(notebookId)]
        )
        let updated = try requireNotebook(notebookId, in: db)
        if existing.readOnly != readOnly {
          try recordAction(
            NoteActionRecord(
              kind: .notebookReadOnlySet,
              provenance: .human,
              entityType: .notebook,
              entityId: notebookId.rawValue,
              notebookId: notebookId,
              display: ["title": .string(updated.title)],
              delta: .object(["readOnly": .object([
                "before": .bool(existing.readOnly),
                "after": .bool(readOnly)
              ])]),
              undoable: true
            ),
            in: db
          )
        }
        return updated
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
    let result = try driver.withDatabase { database in
      try database.transaction { db -> (note: Note, changed: Bool) in
        let existing = try requireNote(noteId, in: db)
        try db.execute(
          "UPDATE notes SET read_only = ?, updated_at = ?, updated_by = (SELECT owner_user_id FROM notebooks WHERE notebook_id = notes.notebook_id) WHERE note_id = ?",
          bindings: [.int(readOnly ? 1 : 0), .text(NoteStoreClock.system.now()), .id(noteId)]
        )
        let updated = try requireNote(noteId, in: db)
        if existing.readOnly != readOnly {
          try recordAction(
            NoteActionRecord(
              kind: .noteReadOnlySet,
              provenance: .human,
              entityType: .note,
              entityId: noteId.rawValue,
              notebookId: updated.notebookId,
              display: ["title": .optionalString(updated.title)],
              delta: .object(["readOnly": .object([
                "before": .bool(existing.readOnly),
                "after": .bool(readOnly)
              ])]),
              undoable: true
            ),
            in: db
          )
        }
        return (updated, existing.readOnly != readOnly)
      }
    }
    // Undo of this change publishes noteUpdated (U13); the forward mutation must
    // too, or a live client sees the lock flip only when it is undone.
    if result.changed {
      publishChange(NoteChangeEvent(
        kind: NoteChangeEventKind.noteUpdated,
        notebookId: result.note.notebookId
      ))
    }
    return result.note
  }

  func deleteNote(noteId: NoteID) throws {
    let notebookId = try driver.withDatabase { database in
      try database.transaction { db -> NotebookID in
        let note = try requireNote(noteId, in: db)
        let notebook = try requireNotebook(note.notebookId, in: db)
        guard !note.readOnly, !notebook.readOnly else {
          throw NoteServiceError.readOnly(noteId.rawValue)
        }
        // Deletion is the one moment content must enter the log: the snapshot
        // is what undo restores (U4).
        let snapshot = try captureNoteSnapshot(noteId: noteId, in: db)
        // Derived translation outputs are valid only while their source note
        // exists. Removing them in the same transaction prevents a restarted
        // translation from completing with an orphaned stale output.
        try deleteTranslationOutputs(sourceNoteId: noteId, in: db)
        try deleteNoteRows(noteId: noteId, in: db)
        try db.execute(
          "UPDATE notebooks SET updated_at = ?, updated_by = owner_user_id WHERE notebook_id = ?",
          bindings: [.text(NoteStoreClock.system.now()), .id(note.notebookId)]
        )
        try recordAction(
          NoteActionRecord(
            kind: .noteDeleted,
            provenance: .human,
            entityType: .note,
            entityId: noteId.rawValue,
            notebookId: note.notebookId,
            display: ["title": .optionalString(note.title)],
            delta: snapshot,
            undoable: true
          ),
          in: db
        )
        return note.notebookId
      }
    }
    // The same wake-up undoing the deletion publishes (U13); without it, live
    // clients keep showing a note that no longer exists.
    publishChange(NoteChangeEvent(
      kind: NoteChangeEventKind.noteUpdated,
      notebookId: notebookId
    ))
  }

  func deleteNotebook(notebookId: NotebookID) throws {
    let deletionEvent = try driver.withDatabase { database in
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
        // Recorded for the history view but not undoable (U10): a cascade
        // snapshot would embed every note body.
        try recordAction(
          NoteActionRecord(
            kind: .notebookDeleted,
            provenance: .human,
            entityType: .notebook,
            entityId: notebookId.rawValue,
            notebookId: notebookId,
            display: [
              "title": .string(notebook.title),
              "noteCount": .integer(Int64(notes.count))
            ],
            undoable: false
          ),
          in: db
        )
        return NoteChangeEvent(
          kind: NoteChangeEventKind.notebookDeleted,
          notebookId: notebookId,
          tagNames: folderTagNames(of: notebook),
          ownerUserId: notebook.ownerUserId,
          libraryId: notebook.libraryId
        )
      }
    }
    publishChange(deletionEvent)
  }
}
