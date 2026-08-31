import Foundation

public extension NoteService {
  /// Creates the conversation notebook for a subject note.
  @discardableResult
  func startAgentConversation(
    subjectNoteId: NoteID,
    title: String? = nil
  ) throws -> Notebook {
    try createAgentConversation(subject: .note(subjectNoteId), title: title)
  }

  /// Creates the conversation notebook for a whole-notebook subject (a memo
  /// thread started with no note selected).
  @discardableResult
  func startAgentConversation(
    subjectNotebookId: NotebookID,
    title: String? = nil
  ) throws -> Notebook {
    try createAgentConversation(subject: .notebook(subjectNotebookId), title: title)
  }

  /// Validates the subject and inserts its derived conversation in one
  /// immediate transaction. A concurrent move or deletion therefore happens
  /// either before validation (and is reflected here) or after insertion,
  /// never between a successful validation and conversation creation.
  private func createAgentConversation(
    subject: AgentChatSubject,
    title: String?
  ) throws -> Notebook {
    let result = try driver.withDatabase { database in
      try database.transaction { db in
        let subjectNotebook: Notebook
        let conversationTitle: String
        let subjectNoteId: NoteID?
        switch subject {
        case let .note(noteId):
          let note = try requireNote(noteId, in: db)
          subjectNotebook = try requireNotebook(note.notebookId, in: db)
          conversationTitle = title
            ?? "Chat: \(note.title ?? NoteTitleDerivation.fallbackTitle(from: note.bodyMarkdown))"
          subjectNoteId = noteId
        case let .notebook(notebookId):
          subjectNotebook = try requireNotebook(notebookId, in: db)
          conversationTitle = title ?? "Chat: \(subjectNotebook.title)"
          subjectNoteId = nil
        }
        let metaJSON = try Self.chatNotebookMetaJSON(
          subjectNoteId: subjectNoteId,
          subjectNotebookId: subjectNotebook.notebookId
        )
        try agentChatCreationPreinsertHook?(db)
        try validateAgentConversationSubject(
          subject,
          expectedNotebookId: subjectNotebook.notebookId,
          expectedLibraryId: subjectNotebook.libraryId,
          in: db
        )
        return try insertNotebook(
          title: conversationTitle,
          kindTagName: NoteStoreSchema.agentConversationNotebookKindTag,
          metaJSON: metaJSON,
          libraryId: subjectNotebook.libraryId,
          originatingActionId: nil,
          in: db
        )
      }
    }
    dispatchQueuedAutoActions(result.dispatches)
    publishChange(NoteChangeEvent(
      kind: NoteChangeEventKind.notebookCreated,
      notebookId: result.notebook.notebookId,
      tagNames: folderTagNames(of: result.notebook)
    ))
    return result.notebook
  }

  /// Confirms a subject did not move or disappear between its initial lookup
  /// and insertion of the derived conversation. With SQLite's immediate
  /// transaction, external writers cannot normally interleave; this explicit
  /// check also keeps the invariant intact for alternative drivers and makes
  /// the pre-insert boundary fail closed.
  private func validateAgentConversationSubject(
    _ subject: AgentChatSubject,
    expectedNotebookId: NotebookID,
    expectedLibraryId: LibraryID?,
    in database: SQLiteDatabase
  ) throws {
    let currentNotebook: Notebook
    switch subject {
    case let .note(noteId):
      let currentNote = try requireNote(noteId, in: database)
      currentNotebook = try requireNotebook(currentNote.notebookId, in: database)
    case let .notebook(notebookId):
      currentNotebook = try requireNotebook(notebookId, in: database)
    }
    guard currentNotebook.notebookId == expectedNotebookId,
      currentNotebook.libraryId == expectedLibraryId else {
      throw NoteServiceError.conflict(
        "agent chat subject changed before conversation creation: \(expectedNotebookId)"
      )
    }
  }
}
