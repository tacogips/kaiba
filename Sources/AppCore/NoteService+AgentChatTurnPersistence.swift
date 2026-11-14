import Foundation

/// Persists agent-chat turn states. Keeping the turn update primitive separate
/// lets edit-mode apply the note replacement and the answered turn in one
/// transaction, so recovery observes either both writes or neither.
extension NoteService {
  /// Fills in the assistant half and marks the turn answered.
  @discardableResult
  func completeAgentChatTurn(
    turnNoteId: NoteID,
    assistantMarkdown: String,
    originatingActionId: AutoActionID? = nil
  ) throws -> Note {
    try completeAgentChatTurn(
      turnNoteId: turnNoteId,
      assistantMarkdown: assistantMarkdown,
      expectedSubject: nil,
      expectedLibraryId: nil,
      originatingActionId: originatingActionId
    )
  }

  @discardableResult
  func completeAgentChatTurn(
    turnNoteId: NoteID,
    assistantMarkdown: String,
    expectedSubject: AgentChatSubject?,
    expectedLibraryId: LibraryID?,
    originatingActionId: AutoActionID?
  ) throws -> Note {
    try updateChatTurn(turnNoteId: turnNoteId) { state in
      AgentChatTurnState(
        status: .answered,
        userMarkdown: state.userMarkdown,
        model: state.model,
        mode: state.mode,
        replyLibraryId: expectedLibraryId ?? state.replyLibraryId
      )
    } assistantMarkdown: { _ in
      assistantMarkdown
    } validate: { note, database in
      try validateAgentChatSubject(
        turn: note,
        expectedSubject: expectedSubject,
        expectedLibraryId: expectedLibraryId,
        phase: "reply completion",
        in: database
      )
    }
  }

  func completeAgentChatTurnInDatabase(
    turnNoteId: NoteID,
    assistantMarkdown: String,
    expectedSubject: AgentChatSubject,
    expectedLibraryId: LibraryID,
    in database: SQLiteDatabase
  ) throws -> Note {
    try updateChatTurnInDatabase(
      turnNoteId: turnNoteId,
      transformState: { state in
        AgentChatTurnState(
          status: .answered,
          userMarkdown: state.userMarkdown,
          model: state.model,
          mode: state.mode,
          replyLibraryId: expectedLibraryId
        )
      },
      assistantMarkdown: { _ in assistantMarkdown },
      validate: { note, db in
        try validateAgentChatSubject(
          turn: note,
          expectedSubject: expectedSubject,
          expectedLibraryId: expectedLibraryId,
          phase: "reply completion",
          in: db
        )
      },
      in: database
    )
  }

  /// Records a failed reply attempt; the turn stays retryable.
  @discardableResult
  func failAgentChatTurn(
    turnNoteId: NoteID,
    message: String,
    expectedSubject: AgentChatSubject? = nil,
    expectedLibraryId: LibraryID? = nil,
    originatingActionId _: AutoActionID? = nil
  ) throws -> Note {
    try updateChatTurn(turnNoteId: turnNoteId) { state in
      AgentChatTurnState(
        status: .failed,
        userMarkdown: state.userMarkdown,
        errorMessage: message,
        model: state.model,
        mode: state.mode,
        replyLibraryId: state.replyLibraryId
      )
    } assistantMarkdown: { _ in
      nil
    } validate: { note, database in
      try validateAgentChatSubject(
        turn: note,
        expectedSubject: expectedSubject,
        expectedLibraryId: expectedLibraryId,
        phase: "reply failure",
        in: database
      )
    }
  }

  /// Terminalizes a queued reply that cannot safely run for its original
  /// principal. Unlike `.failed`, this state is deliberately not retryable.
  @discardableResult
  func cancelAgentChatTurn(turnNoteId: NoteID, message: String) throws -> Note {
    try updateChatTurn(turnNoteId: turnNoteId) { state in
      AgentChatTurnState(
        status: .cancelled,
        userMarkdown: state.userMarkdown,
        errorMessage: message,
        model: state.model,
        mode: state.mode,
        replyLibraryId: state.replyLibraryId
      )
    } assistantMarkdown: { _ in
      nil
    }
  }

  func updateChatTurn(
    turnNoteId: NoteID,
    transformState: (AgentChatTurnState) -> AgentChatTurnState,
    assistantMarkdown: (AgentChatTurnState) -> String?,
    validate: ((Note, SQLiteDatabase) throws -> Void)? = nil
  ) throws -> Note {
    let result = try driver.withDatabase { database in
      try database.transaction { db in
        try updateChatTurnInDatabase(
          turnNoteId: turnNoteId,
          transformState: transformState,
          assistantMarkdown: assistantMarkdown,
          validate: validate,
          in: db
        )
      }
    }
    publishChange(NoteChangeEvent(kind: NoteChangeEventKind.noteUpdated, notebookId: result.notebookId))
    return result
  }

  func updateChatTurnInDatabase(
    turnNoteId: NoteID,
    transformState: (AgentChatTurnState) -> AgentChatTurnState,
    assistantMarkdown: (AgentChatTurnState) -> String?,
    validate: ((Note, SQLiteDatabase) throws -> Void)? = nil,
    in database: SQLiteDatabase
  ) throws -> Note {
    try requireEnabledActingUser(in: database)
    let note = try requireNote(turnNoteId, in: database)
    guard let state = Self.chatTurnState(of: note) else {
      throw NoteServiceError.invalidInput("note is not an agent chat turn: \(turnNoteId)")
    }
    try validate?(note, database)
    let newState = transformState(state)
    let assistant = assistantMarkdown(state)
    let idempotencyKey = Self.chatIdempotencyKey(of: note)
    let body = Self.chatTurnBody(
      noteNumber: note.noteNumber,
      userMarkdown: newState.userMarkdown,
      assistantMarkdown: assistant
    )
    let metaJSON = try Self.chatTurnMetaJSON(state: newState, idempotencyKey: idempotencyKey)
    let previous = try ftsPayload(noteId: turnNoteId, in: database)
    let now = NoteStoreClock.system.now()
    try database.execute(
      """
      UPDATE notes
      SET body_markdown = ?, title = ?, meta_json = jsonb(?), updated_at = ?,
        updated_by = (SELECT owner_user_id FROM notebooks WHERE notebook_id = notes.notebook_id)
      WHERE note_id = ?
      """,
      bindings: [
        .text(body),
        .optionalText(noteTitle(from: body)),
        .text(metaJSON),
        .text(now),
        .id(turnNoteId)
      ]
    )
    try database.execute(
      "UPDATE notebooks SET updated_at = ?, updated_by = owner_user_id WHERE notebook_id = ?",
      bindings: [.text(now), .id(note.notebookId)]
    )
    try refreshFTS(noteId: turnNoteId, previous: previous, in: database)
    let updated = try requireNote(turnNoteId, in: database)
    // Translation completion snapshots source notebooks with their durable
    // action-log revision. A provider reply changes the chat turn body after
    // the initial user turn has been created, so record that content mutation
    // in the same transaction. It is deliberately non-undoable: undoing only
    // the rendered body would not restore the corresponding chat-turn state.
    if updated.bodyMarkdown != note.bodyMarkdown {
      try recordAction(
        NoteActionRecord(
          kind: .noteBodyUpdated,
          provenance: .ai,
          entityType: .note,
          entityId: turnNoteId.rawValue,
          notebookId: note.notebookId,
          display: ["title": .optionalString(updated.title)],
          undoable: false
        ),
        in: database
      )
    }
    return updated
  }

  private func validateAgentChatSubject(
    turn: Note,
    expectedSubject: AgentChatSubject?,
    expectedLibraryId: LibraryID?,
    phase: String,
    in database: SQLiteDatabase
  ) throws {
    guard let expectedSubject else { return }
    let conversation = try requireNotebook(turn.notebookId, in: database)
    guard conversation.libraryId == expectedLibraryId || expectedLibraryId == nil,
      let subject = try chatSubject(notebookId: turn.notebookId, in: database),
      subject == expectedSubject
    else {
      throw NoteServiceError.invalidInput(
        "agent chat conversation subject changed before \(phase): \(turn.notebookId)"
      )
    }
  }
}
