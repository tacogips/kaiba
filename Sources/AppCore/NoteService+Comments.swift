import Foundation

public extension NoteService {
  @discardableResult
  func addComment(noteId: NoteID, bodyMarkdown: String, author: String = "user") throws -> NoteComment {
    let result = try driver.withDatabase { database in
      try database.transaction { db -> (comment: NoteComment, notebookId: NotebookID) in
        let note = try requireNote(noteId, in: db)
        let now = NoteStoreClock.system.now()
        let commentId = CommentID.generate()
        try db.execute(
          """
          INSERT INTO note_comments (comment_id, note_id, notebook_id, body_markdown, author, created_at)
          VALUES (?, ?, ?, ?, ?, ?)
          """,
          bindings: [
            .id(commentId), .id(noteId), .id(note.notebookId),
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
        try recordAction(
          NoteActionRecord(
            kind: .commentAdded,
            provenance: .human,
            entityType: .comment,
            entityId: commentId.rawValue,
            notebookId: note.notebookId,
            display: ["title": .optionalString(note.title)],
            undoable: true
          ),
          in: db
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
