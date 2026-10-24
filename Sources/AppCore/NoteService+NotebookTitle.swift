import Foundation

public extension NoteService {
  /// Renaming metadata is allowed for imported, read-only documents.
  @discardableResult
  func renameNotebook(notebookId: NotebookID, title: String) throws -> Notebook {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 1000 else {
      throw NoteServiceError.invalidInput("notebook title must contain 1 to 1000 characters")
    }
    let notebook = try driver.withDatabase { database in
      try database.transaction { db in
        try requireEnabledActingUser(in: db)
        try requireNotebookOwnership(notebookId, subject: notebookId.rawValue, in: db)
        let existing = try requireNotebook(notebookId, in: db)
        guard existing.title != trimmed else { return existing }
        let updated = try writeNotebookTitle(notebookId: notebookId, title: trimmed, in: db)
        try recordAction(NoteActionRecord(
          kind: .notebookTitleUpdated, provenance: .human, entityType: .notebook,
          entityId: notebookId.rawValue, notebookId: notebookId,
          display: ["title": .string(trimmed)],
          delta: .object(["title": .object(["before": .string(existing.title), "after": .string(trimmed)])]),
          undoable: true
        ), in: db)
        return updated
      }
    }
    publishChange(NoteChangeEvent(kind: NoteChangeEventKind.notebookUpdated, notebookId: notebookId))
    return notebook
  }
}

extension NoteService {
  func writeNotebookTitle(notebookId: NotebookID, title: String, in db: SQLiteDatabase) throws -> Notebook {
    let noteIds = try db.query("SELECT note_id FROM notes WHERE notebook_id = ?", bindings: [.id(notebookId)])
      .compactMap { $0.identifier("note_id", as: NoteID.self) }
    let previous = try noteIds.map { try ftsPayload(noteId: $0, in: db) }
    try db.execute(
      "UPDATE notebooks SET title = ?, updated_at = ?, updated_by = owner_user_id WHERE notebook_id = ?",
      bindings: [.text(title), .text(NoteStoreClock.system.now()), .id(notebookId)]
    )
    for (id, payload) in zip(noteIds, previous) { try refreshFTS(noteId: id, previous: payload, in: db) }
    return try requireNotebook(notebookId, in: db)
  }
}
