import Foundation

/// Edit-mode agent chat (`design-docs/specs/ai-agent-integration.md`). The
/// agent has no tool channel back into kaiba, so an edit-mode reply carries
/// the complete replacement note body between sentinel lines and the server
/// applies it through `updateNoteBody` — the same guarded write path as
/// `kaiba edit`, portable across every provider adapter.

public extension NoteService {
  private struct AgentChatEditApplication {
    let note: Note
    let turn: Note
    let dispatches: [QueuedAutoActionDispatch]
  }

  static let noteEditBodyOpening = "<kaiba-note-body>"
  static let noteEditBodyClosing = "</kaiba-note-body>"

  static var noteEditSystemPrompt: String {
    """
    You are an editing assistant for a note-taking system. The document \
    provided as context is the current body of the user's note, and the \
    user's message asks you to change it. Reply with the complete revised \
    note body in markdown, wrapped between a line containing only \
    \(noteEditBodyOpening) and a line containing only \(noteEditBodyClosing). \
    Preserve everything the user did not ask to change. Text after the \
    closing line is shown to the user as a short summary of the change. \
    When the request is unclear, or no change is needed, reply in plain \
    markdown without those markers and the note is left untouched.
    """
  }

  /// Splits an edit-mode reply into the replacement body (between the
  /// sentinels) and the commentary around it. A reply without a usable body
  /// returns nil so the caller can fall back to a plain chat answer — the
  /// agent declining or asking a clarifying question must never blank a note.
  static func noteEditReply(
    from markdown: String
  ) -> (bodyMarkdown: String?, commentary: String) {
    guard let opening = markdown.range(of: noteEditBodyOpening),
      let closing = markdown.range(of: noteEditBodyClosing, range: opening.upperBound..<markdown.endIndex)
    else {
      return (nil, markdown)
    }
    let body = String(markdown[opening.upperBound..<closing.lowerBound])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let commentary = (String(markdown[..<opening.lowerBound]) + "\n"
      + String(markdown[closing.upperBound...]))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else {
      return (nil, markdown)
    }
    return (body, commentary)
  }

  /// Applies an edit-mode reply to the subject note and returns the assistant
  /// markdown to persist on the turn, plus whether the note was rewritten.
  /// Throws when the note refuses the write (for example, it was locked after
  /// the turn was accepted).
  internal func applyNoteEditReply(
    _ markdown: String,
    turnNoteId: NoteID,
    subjectNoteId: NoteID,
    conversationNotebookId: NotebookID,
    expectedSubject: AgentChatSubject,
    expectedLibraryId: LibraryID,
    expectedSubjectBodyMarkdown: String?,
    originatingActionId: AutoActionID?
  ) throws -> (assistantMarkdown: String, updatedNote: Bool) {
    let parsed = Self.noteEditReply(from: markdown)
    guard let bodyMarkdown = parsed.bodyMarkdown else {
      return (markdown, false)
    }
    let result = try driver.withDatabase { database in
      try database.transaction { db -> AgentChatEditApplication in
        try requireEnabledActingUser(in: db)
        let conversation = try requireNotebook(conversationNotebookId, in: db)
        guard conversation.libraryId == expectedLibraryId,
          let currentSubject = try chatSubject(notebookId: conversationNotebookId, in: db),
          currentSubject == expectedSubject
        else {
          throw NoteServiceError.invalidInput(
            "agent chat conversation subject changed before applying edit: \(conversationNotebookId)"
          )
        }
        let subject = try requireNote(subjectNoteId, in: db)
        guard subject.bodyMarkdown == expectedSubjectBodyMarkdown else {
          throw NoteServiceError.conflict(
            "agent chat subject content changed before applying edit: \(subjectNoteId)"
          )
        }
        let updated = try updateNoteBodyInDatabase(
          noteId: subjectNoteId,
          bodyMarkdown: bodyMarkdown,
          provenance: .ai,
          originatingActionId: originatingActionId,
          in: db
        )
        try agentChatEditPrecompletionHook?(db)
        let turn = try completeAgentChatTurnInDatabase(
          turnNoteId: turnNoteId,
          assistantMarkdown: parsed.commentary.isEmpty ? "Updated the note." : parsed.commentary,
          expectedSubject: expectedSubject,
          expectedLibraryId: expectedLibraryId,
          in: db
        )
        return AgentChatEditApplication(
          note: updated.note,
          turn: turn,
          dispatches: updated.dispatches
        )
      }
    }
    dispatchQueuedAutoActions(result.dispatches)
    publishChange(NoteChangeEvent(
      kind: NoteChangeEventKind.noteUpdated,
      notebookId: result.note.notebookId
    ))
    if result.turn.notebookId != result.note.notebookId {
      publishChange(NoteChangeEvent(
        kind: NoteChangeEventKind.noteUpdated,
        notebookId: result.turn.notebookId
      ))
    }
    return (parsed.commentary.isEmpty ? "Updated the note." : parsed.commentary, true)
  }
}
