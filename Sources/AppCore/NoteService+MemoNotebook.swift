import Foundation

struct SavedMemoNotebook {
  let comment: NoteComment
  let sourceNotebookId: NotebookID
  let memoNotebookId: NotebookID?
}

public extension NoteService {
  /// Open an existing memo as a chat notebook. Older comments are materialized
  /// lazily; a transaction makes repeated/concurrent opens reuse one notebook.
  func openMemoNotebook(commentId: CommentID) throws -> Notebook {
    let notebook = try driver.withDatabase { database in
      try database.transaction { db in
        guard let row = try db.query(
          "SELECT * FROM note_comments WHERE comment_id = ?", bindings: [.id(commentId)]
        ).first else { throw NoteServiceError.invalidInput("memo not found") }
        return try ensureMemoNotebook(noteComment(from: row), in: db)
      }
    }
    publishChange(NoteChangeEvent(kind: NoteChangeEventKind.notebookCreated, notebookId: notebook.notebookId))
    return notebook
  }
}

extension NoteService {
  func ensureMemoNotebook(_ comment: NoteComment, in database: SQLiteDatabase) throws -> Notebook {
    let sourceId: NotebookID
    if let noteId = comment.noteId {
      sourceId = try requireNote(noteId, in: database).notebookId
    } else if let notebookId = comment.notebookId {
      sourceId = notebookId
    } else { throw NoteServiceError.invalidInput("memo has no source") }
    let authorizedSource = try requireNotebook(sourceId, in: database)
    guard !Self.isPendingNotebookIngestMetadata(authorizedSource.metaJSON) else {
      throw NoteServiceError.invalidInput("memo source import is not finalized")
    }
    if let row = try database.query(
      "SELECT notebook_id FROM notebooks WHERE json_extract(meta_json, '$.kaibaChat.memoCommentId') = ?",
      bindings: [.id(comment.commentId)]
    ).first, let notebookId = row.identifier("notebook_id", as: NotebookID.self) {
      let existing = try requireNotebook(notebookId, in: database)
      guard existing.libraryId == authorizedSource.libraryId, existing.ownerUserId == authorizedSource.ownerUserId else {
        throw NoteServiceError.invalidInput("memo notebook no longer matches its source")
      }
      return existing
    }
    let source: Notebook
    let context: String
    if let noteId = comment.noteId {
      let note = try requireNote(noteId, in: database)
      source = try requireNotebook(note.notebookId, in: database)
      context = try agentBranchContext(noteId: noteId, notebook: source, in: database)
        ?? noteChatContext(note, in: database)
    } else if let notebookId = comment.notebookId {
      source = try requireNotebook(notebookId, in: database)
      if let last = try database.query(
        "SELECT note_id FROM notes WHERE notebook_id = ? ORDER BY note_number DESC LIMIT 1",
        bindings: [.id(notebookId)]
      ).first?.identifier("note_id", as: NoteID.self),
        let branch = try agentBranchContext(noteId: last, notebook: source, in: database) {
        context = branch
      } else if source.type == .agentChat {
        context = try agentChatInheritedContext(source, in: database)
      } else {
        context = try notebookContextMarkdown(notebookId: notebookId, in: database)
      }
    } else { throw NoteServiceError.invalidInput("memo has no source") }
    var metadata = try JSONValue(parsing: Self.chatNotebookMetaJSON(
      subjectNoteId: comment.noteId, subjectNotebookId: source.notebookId, branchContext: context
    )).asObject ?? [:]
    var chat = metadata["kaibaChat"]?.asObject ?? [:]
    chat["memoCommentId"] = .string(comment.commentId.rawValue)
    metadata["kaibaChat"] = .object(chat)
    let turnMetadata = try JSONValue.object(["kaibaChat": .object([
      "status": .string("answered"), "userMarkdown": .string(comment.bodyMarkdown), "memoOnly": .bool(true)
    ])]).encodedString()
    let inserted = try scoped(toLibrary: source.libraryId).insertNotebookWithNotes(
      title: promoteCommentNotebookTitle(explicit: nil, commentBody: comment.bodyMarkdown),
      kindTagName: NoteStoreSchema.agentConversationNotebookKindTag,
      metaJSON: JSONValue.object(metadata).encodedString(),
      pages: [NotePageDraft(bodyMarkdown: comment.bodyMarkdown, readOnly: false, metaJSON: turnMetadata)],
      notebookReadOnly: false, provenance: .human, assignedBy: comment.author,
      originatingActionId: nil, enqueueAutoActions: false, recordIngestAction: false, in: database
    )
    return inserted.ingestResult.notebook
  }
}
