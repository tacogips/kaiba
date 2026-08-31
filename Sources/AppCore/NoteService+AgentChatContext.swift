import Foundation

struct AgentChatSubjectSnapshot {
  let subject: AgentChatSubject
  let markdown: String?
  let libraryId: LibraryID
  /// Exact note content captured for an edit-mode provider invocation. This is
  /// intentionally separate from `markdown`, which is truncated for normal
  /// chat, so replacement writes can reject a concurrent human edit.
  let noteBodyMarkdown: String?
}

extension NoteService {
  /// Captures the subject and its context while the conversation and subject
  /// libraries are checked on the same database snapshot. A move therefore
  /// cannot turn an already-authorized open subject into protected provider
  /// context between validation and the read.
  func agentChatSubjectSnapshot(
    conversationNotebookId: NotebookID,
    editMode: Bool
  ) throws -> AgentChatSubjectSnapshot {
    try driver.withDatabase { database in
      try database.transaction { db in
        let conversation = try requireNotebook(conversationNotebookId, in: db)
        guard let conversationLibraryId = conversation.libraryId else {
          throw NoteServiceError.invalidRow(
            "agent chat conversation is missing a library: \(conversationNotebookId)"
          )
        }
        guard let subject = try chatSubject(notebookId: conversationNotebookId, in: db) else {
          throw NoteServiceError.invalidInput(
            "notebook is not an agent chat conversation: \(conversationNotebookId)"
          )
        }
        let markdown: String?
        let noteBodyMarkdown: String?
        switch subject {
        case let .note(subjectNoteId):
          let subjectNote = try requireNote(subjectNoteId, in: db)
          if editMode {
            guard subjectNote.bodyMarkdown.utf8.count <= Self.subjectContextLimitBytes else {
              throw NoteServiceError.invalidInput(
                "note \(subjectNoteId) is too large to edit in agent chat"
              )
            }
            markdown = subjectNote.bodyMarkdown
            noteBodyMarkdown = subjectNote.bodyMarkdown
          } else {
            markdown = utf8Prefix(subjectNote.bodyMarkdown, limit: Self.subjectContextLimitBytes)
            noteBodyMarkdown = nil
          }
        case let .notebook(subjectNotebookId):
          noteBodyMarkdown = nil
          let subjectNotebook = try requireNotebook(subjectNotebookId, in: db)
          if let subjectTagId = try tagMemoSubjectTagId(notebookId: subjectNotebookId, in: db) {
            markdown = try optionalAgentChatContext {
              try tagContextMarkdown(
                tagId: subjectTagId,
                libraryId: subjectNotebook.libraryId,
                in: db
              )
            }
          } else {
            markdown = try optionalAgentChatContext {
              try notebookContextMarkdown(notebookId: subjectNotebookId, in: db)
            }
          }
        }
        return AgentChatSubjectSnapshot(
          subject: subject,
          markdown: markdown,
          libraryId: conversationLibraryId,
          noteBodyMarkdown: noteBodyMarkdown
        )
      }
    }
  }

  /// Notebook-subject context: title plus each note's markdown in page order,
  /// capped so a large imported document cannot blow the prompt.
  func notebookContextMarkdown(
    notebookId: NotebookID,
    limitBytes: Int = 200 * 1024
  ) throws -> String {
    try driver.withDatabase { database in
      try notebookContextMarkdown(notebookId: notebookId, limitBytes: limitBytes, in: database)
    }
  }

  func notebookContextMarkdown(
    notebookId: NotebookID,
    limitBytes: Int = 200 * 1024,
    in database: SQLiteDatabase
  ) throws -> String {
    let notebook = try requireNotebook(notebookId, in: database)
    let rows = try database.query(
      """
      SELECT body_markdown
      FROM notes
      WHERE notebook_id = ?
      ORDER BY note_number, note_id
      LIMIT 200
      """,
      bindings: [.id(notebookId)]
    )
    return boundedMarkdownContext(
      heading: "# \(notebook.title)",
      sections: rows.compactMap { $0["body_markdown"] },
      limitBytes: limitBytes
    )
  }

  /// Checks immutable conversation identity for an idempotent replay. A
  /// deleted note subject remains replayable, but current subjects must still
  /// match the conversation's owner and library boundary.
  func isReplayableAgentChatConversation(
    _ conversation: Notebook,
    in database: SQLiteDatabase
  ) throws -> Bool {
    let kindRows = try database.query(
      """
      SELECT 1
      FROM notebook_tags
      WHERE notebook_id = ? AND tag_id = ?
      LIMIT 1
      """,
      bindings: [
        .id(conversation.notebookId),
        .id(NoteStoreSchema.agentConversationNotebookKindTagId)
      ]
    )
    guard !kindRows.isEmpty,
      let row = try database.query(
        """
        SELECT json_extract(meta_json, '$.kaibaChat.subjectNoteId') AS subject_note,
          json_extract(meta_json, '$.kaibaChat.subjectNotebookId') AS subject_notebook
        FROM notebooks
        WHERE notebook_id = ?
        LIMIT 1
        """,
        bindings: [.id(conversation.notebookId)]
      ).first,
      let subjectNotebookId = row.identifier("subject_notebook", as: NotebookID.self)
    else {
      return false
    }

    if row["subject_note"] != nil {
      guard let subjectNoteId = row.identifier("subject_note", as: NoteID.self) else {
        return false
      }
      let sourceRows = try database.query(
        "SELECT notebook_id FROM notes WHERE note_id = ? LIMIT 1",
        bindings: [.id(subjectNoteId)]
      )
      guard !sourceRows.isEmpty else {
        return true
      }
      let subjectNote = try requireNote(subjectNoteId, in: database)
      let subjectNotebook = try requireNotebook(subjectNote.notebookId, in: database)
      return subjectNotebook.notebookId == subjectNotebookId
        && subjectNotebook.ownerUserId == conversation.ownerUserId
        && subjectNotebook.libraryId == conversation.libraryId
    }

    let subjectRows = try database.query(
      "SELECT notebook_id FROM notebooks WHERE notebook_id = ? LIMIT 1",
      bindings: [.id(subjectNotebookId)]
    )
    guard !subjectRows.isEmpty else {
      return true
    }
    let subjectNotebook = try requireNotebook(subjectNotebookId, in: database)
    return subjectNotebook.ownerUserId == conversation.ownerUserId
      && subjectNotebook.libraryId == conversation.libraryId
  }
}

private func optionalAgentChatContext(_ load: () throws -> String) throws -> String? {
  do {
    return try load()
  } catch let error as NoteServiceError {
    guard case .notFound = error else {
      throw error
    }
    return nil
  }
}
