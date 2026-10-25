import Foundation

public extension NoteService {
  /// Maximum sections in a continuous Markdown notebook snapshot. The server's
  /// independent HTTP body limit still bounds the serialized request size.
  static var maximumDraftNoteCount: Int { 2000 }

  /// Reconcile a Markdown writer snapshot in one transaction. Replaying the same
  /// snapshot is harmless, including when the response to a new note was lost.
  func saveNotebookDraft(notebookId: NotebookID, title: String, bodies: [String]) throws -> Notebook {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, title.count <= 1000, (1...Self.maximumDraftNoteCount).contains(bodies.count),
          bodies.allSatisfy({ $0.utf8.count <= MarkdownHeadingSplitter.maximumSectionBytes }) else {
      throw NoteServiceError.invalidInput("draft requires a title and 1...\(Self.maximumDraftNoteCount) bounded notes")
    }
    let saved = try driver.withDatabase { database in
      try database.transaction { db in
        try requireEnabledActingUser(in: db)
        try requireNotebookOwnership(notebookId, subject: notebookId.rawValue, in: db)
        let notebook = try requireNotebook(notebookId, in: db)
        guard !notebook.readOnly, notebook.type != .agentChat else {
          throw NoteServiceError.readOnly(notebookId.rawValue)
        }
        let ids = try db.query("SELECT note_id FROM notes WHERE notebook_id = ? ORDER BY note_number", bindings: [.id(notebookId)])
          .compactMap { $0.identifier("note_id", as: NoteID.self) }
        let notes = try ids.map { try requireWritableNote($0, in: db) }
        guard !notes.contains(where: Self.isDocumentPageNote) else {
          throw NoteServiceError.invalidInput("document pages cannot be replaced by a Markdown draft")
        }
        let matches = NotebookDraftIdentityMatcher.matchingOldIndices(oldBodies: notes.map(\.bodyMarkdown), newBodies: bodies)
        let retained = Set(matches.compactMap { $0 })
        // Snapshot removed notes at their original positions before temporarily
        // moving the survivors to avoid the unique notebook/number constraint.
        for (index, removed) in notes.enumerated() where !retained.contains(index) {
          let snapshot = try captureNoteSnapshot(noteId: removed.noteId, in: db)
          try deleteNoteRows(noteId: removed.noteId, in: db)
          try recordAction(NoteActionRecord(kind: .noteDeleted, provenance: .human, entityType: .note,
            entityId: removed.noteId.rawValue, notebookId: notebookId,
            display: ["title": .optionalString(removed.title)], delta: snapshot, undoable: true), in: db)
        }
        let temporaryBase = max(notes.map(\.noteNumber).max() ?? 0, bodies.count) + 1
        let moving = Set(matches.enumerated().compactMap { index, oldIndex -> Int? in
          guard let oldIndex, notes[oldIndex].noteNumber != index + 1 else { return nil }
          return oldIndex
        })
        for index in moving {
          try db.execute("UPDATE notes SET note_number = ? WHERE note_id = ?",
            bindings: [.int(Int64(temporaryBase + index)), .id(notes[index].noteId)])
        }
        var dispatches: [QueuedAutoActionDispatch] = []
        for (index, body) in bodies.enumerated() {
          if let oldIndex = matches[index] {
            let note = notes[oldIndex]
            if moving.contains(oldIndex) {
              try db.execute("UPDATE notes SET note_number = ? WHERE note_id = ?",
                bindings: [.int(Int64(index + 1)), .id(note.noteId)])
            }
            if note.bodyMarkdown != body {
              let changed = try updateNoteBodyInDatabase(noteId: note.noteId, bodyMarkdown: body,
                provenance: .human, originatingActionId: nil, in: db)
              dispatches.append(contentsOf: changed.dispatches)
            }
          } else {
            let noteId = try insertDraftNote(notebookId: notebookId, number: index + 1, body: body, in: db)
            dispatches.append(contentsOf: try enqueueAutoActions(for: makeAutoActionEvent(
              trigger: .noteCreated, notebookId: notebookId, noteId: noteId, noteBodyMarkdown: body), in: db))
          }
        }
        let updated = try writeNotebookTitle(notebookId: notebookId, title: title, in: db)
        return (notebook: updated, dispatches: dispatches)
      }
    }
    dispatchQueuedAutoActions(saved.dispatches)
    publishChange(NoteChangeEvent(kind: NoteChangeEventKind.notebookUpdated, notebookId: notebookId))
    return saved.notebook
  }
}

extension NoteService {
  private func insertDraftNote(notebookId: NotebookID, number: Int, body: String, in db: SQLiteDatabase) throws -> NoteID {
    let id = NoteID.generate()
    let now = NoteStoreClock.system.now()
    try db.execute("""
      INSERT INTO notes (note_id, notebook_id, note_number, title, title_source, body_markdown,
        read_only, created_by, updated_by, created_at, updated_at)
      VALUES (?, ?, ?, ?, 'derived', ?, 0,
        (SELECT owner_user_id FROM notebooks WHERE notebook_id = ?),
        (SELECT owner_user_id FROM notebooks WHERE notebook_id = ?), ?, ?)
      """, bindings: [.id(id), .id(notebookId), .int(Int64(number)), .optionalText(noteTitle(from: body)),
        .text(body), .id(notebookId), .id(notebookId), .text(now), .text(now)])
    try refreshFTS(noteId: id, previous: nil, in: db)
    try recordAction(NoteActionRecord(kind: .noteCreated, provenance: .human, entityType: .note,
      entityId: id.rawValue, notebookId: notebookId, display: ["title": .optionalString(noteTitle(from: body))],
      undoable: false), in: db)
    return id
  }
}
