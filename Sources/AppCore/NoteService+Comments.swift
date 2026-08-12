import Foundation

public extension NoteService {
  @discardableResult
  func addComment(noteId: String, bodyMarkdown: String, author: String = "user") throws -> NoteComment {
    let result = try driver.withDatabase { database in
      try database.transaction { db -> (comment: NoteComment, notebookId: String) in
        let note = try requireNote(noteId, in: db)
        let now = NoteStoreClock.system.now()
        let commentId = makeNoteId(prefix: "comment")
        try db.execute(
          """
          INSERT INTO note_comments (comment_id, note_id, notebook_id, body_markdown, author, created_at)
          VALUES (?, ?, ?, ?, ?, ?)
          """,
          bindings: [
            .text(commentId), .text(noteId), .text(note.notebookId),
            .text(bodyMarkdown), .text(author), .text(now)
          ]
        )
        let comment = NoteComment(
          commentId: commentId,
          noteId: noteId,
          notebookId: note.notebookId,
          bodyMarkdown: bodyMarkdown,
          author: author,
          createdAt: now
        )
        return (comment, note.notebookId)
      }
    }
    publishChange(NoteChangeEvent(
      kind: NoteChangeEventKind.noteUpdated,
      notebookId: result.notebookId
    ))
    return result.comment
  }
}
