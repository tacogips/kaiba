import Foundation

public struct NotebookReindexReport: Equatable, Sendable {
  public var notes: Int
  public var conversationTurns: Int
  public var engineQueued: Bool
}

public extension NoteService {
  /// Rebuild the selected notebook and its page/notebook discussions only.
  /// Local repair commits with durable engine work, before notifying the worker.
  func rebuildNotebookSearchIndex(notebookId: NotebookID) throws -> NotebookReindexReport {
    let report = try driver.withDatabase { database in
      try database.transaction { db in
        try requireEnabledActingUser(in: db)
        _ = try requireNotebook(notebookId, in: db)
        let rows = try db.query(
          """
          WITH RECURSIVE selected_notebooks(notebook_id) AS (
            SELECT ?
            UNION
            SELECT b.notebook_id FROM notebooks b JOIN selected_notebooks parent
              ON json_extract(b.meta_json, '$.kaibaChat.subjectNotebookId') = parent.notebook_id
                OR json_extract(b.meta_json, '$.kaibaChat.subjectNoteId') IN
                  (SELECT note_id FROM notes WHERE notebook_id = parent.notebook_id)
            WHERE b.owner_user_id IS (SELECT owner_user_id FROM notebooks WHERE notebook_id = ?)
              AND b.library_id IS (SELECT library_id FROM notebooks WHERE notebook_id = ?)
          )
          SELECT n.note_id, n.notebook_id FROM notes n
          JOIN selected_notebooks selected ON selected.notebook_id = n.notebook_id
          ORDER BY n.notebook_id, n.note_number
          """,
          bindings: Array(repeating: .id(notebookId), count: 3)
        )
        var count = 0
        var conversations = 0
        for row in rows {
          guard let noteId = row.identifier("note_id", as: NoteID.self) else { continue }
          _ = try requireNote(noteId, in: db)
          try refreshFTS(noteId: noteId, previous: ftsPayload(noteId: noteId, in: db), in: db)
          if row.identifier("notebook_id", as: NotebookID.self) == notebookId { count += 1 } else { conversations += 1 }
        }
        let activated = try !db.query("SELECT 1 FROM search_engine_sync_state WHERE id = 1").isEmpty
        return NotebookReindexReport(notes: count, conversationTurns: conversations, engineQueued: activated)
      }
    }
    publishChange(NoteChangeEvent(kind: NoteChangeEventKind.notebookUpdated, notebookId: notebookId))
    return report
  }
}
