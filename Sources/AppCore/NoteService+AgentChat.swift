import Foundation

/// Note-level agent chat (`design-docs/specs/ai-agent-integration.md`,
/// AI6/AI7/AI8). A conversation about a subject note is an
/// `agent-conversation` notebook whose turns are notes. Subject binding is
/// recorded in notebook meta JSON (`kaibaChat.subjectNoteId`) plus a
/// `source-citation` link from every turn to the subject note. Turn state
/// (pending/answered/failed/unavailable, user markdown, error) lives in note
/// meta JSON under `kaibaChat`.

public enum AgentChatTurnStatus: String, Codable, Equatable, Sendable {
  case pending
  case answered
  case failed
  /// Persisted while no agent runtime is configured; retried like `failed`
  /// once a runtime becomes available.
  case unavailable
}

public struct AgentChatTurnState: Equatable, Sendable {
  public var status: AgentChatTurnStatus
  public var userMarkdown: String
  public var errorMessage: String?

  public init(status: AgentChatTurnStatus, userMarkdown: String, errorMessage: String? = nil) {
    self.status = status
    self.userMarkdown = userMarkdown
    self.errorMessage = errorMessage
  }
}

public struct AgentChatConversation: Equatable, Sendable {
  public var notebook: Notebook
  public var subjectNoteId: String
  public var turnCount: Int

  public init(notebook: Notebook, subjectNoteId: String, turnCount: Int) {
    self.notebook = notebook
    self.subjectNoteId = subjectNoteId
    self.turnCount = turnCount
  }
}

public extension NoteService {
  /// Creates the conversation notebook for a subject note.
  @discardableResult
  func startAgentConversation(
    subjectNoteId: String,
    title: String? = nil
  ) throws -> Notebook {
    let subject = try getNote(subjectNoteId)
    let conversationTitle = title
      ?? "Chat: \(subject.title ?? NoteTitleDerivation.fallbackTitle(from: subject.bodyMarkdown))"
    let metaJSON = try Self.chatNotebookMetaJSON(
      subjectNoteId: subjectNoteId,
      subjectNotebookId: subject.notebookId
    )
    return try createNotebook(
      title: conversationTitle,
      kindTagName: NoteStoreSchema.agentConversationNotebookKindTag,
      metaJSON: metaJSON
    )
  }

  /// Appends the user half of a turn. The assistant half arrives later via
  /// `completeAgentChatTurn` (fired by the chat-reply auto-action) or never,
  /// when no runtime is available (`agentAvailable: false`).
  @discardableResult
  func appendPendingAgentChatTurn(
    conversationNotebookId: String,
    userMarkdown: String,
    agentAvailable: Bool,
    idempotencyKey: String? = nil
  ) throws -> Note {
    let trimmed = userMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw NoteServiceError.invalidInput("chat message must not be empty")
    }
    let status: AgentChatTurnStatus = agentAvailable ? .pending : .unavailable
    struct AppendResult {
      var note: Note
      var inserted: Bool
      var dispatches: [QueuedAutoActionDispatch]
    }
    let result = try driver.withDatabase { database in
      try database.transaction { db -> AppendResult in
        _ = try requireWritableNotebook(conversationNotebookId, in: db)
        guard let subjectNoteId = try chatSubjectNoteId(
          notebookId: conversationNotebookId,
          in: db
        ) else {
          throw NoteServiceError.invalidInput(
            "notebook is not an agent chat conversation: \(conversationNotebookId)"
          )
        }
        if let idempotencyKey,
          let existing = try chatTurn(
            notebookId: conversationNotebookId,
            idempotencyKey: idempotencyKey,
            in: db
          ) {
          return AppendResult(note: existing, inserted: false, dispatches: [])
        }
        let now = NoteStoreClock.system.now()
        let noteNumber = try nextNoteNumber(notebookId: conversationNotebookId, in: db)
        let noteId = makeNoteId(prefix: "note")
        let body = Self.chatTurnBody(
          noteNumber: noteNumber,
          userMarkdown: trimmed,
          assistantMarkdown: nil
        )
        let metaJSON = try Self.chatTurnMetaJSON(
          state: AgentChatTurnState(status: status, userMarkdown: trimmed),
          idempotencyKey: idempotencyKey
        )
        try db.execute(
          """
          INSERT INTO notes (
            note_id, notebook_id, note_number, title, body_markdown,
            read_only, created_at, updated_at, meta_json
          ) VALUES (?, ?, ?, ?, ?, 0, ?, ?, jsonb(?))
          """,
          bindings: [
            .text(noteId),
            .text(conversationNotebookId),
            .int(Int64(noteNumber)),
            .optionalText(noteTitle(from: body)),
            .text(body),
            .text(now),
            .text(now),
            .text(metaJSON)
          ]
        )
        if try noteExists(subjectNoteId, in: db) {
          _ = try linkNotesInDatabase(
            from: noteId,
            to: subjectNoteId,
            linkKind: "source-citation",
            provenance: .ai,
            in: db
          )
        }
        try db.execute(
          "UPDATE notebooks SET updated_at = ? WHERE notebook_id = ?",
          bindings: [.text(now), .text(conversationNotebookId)]
        )
        try refreshFTS(noteId: noteId, previous: nil, in: db)
        let note = try requireNote(noteId, in: db)
        let dispatches = try enqueueAutoActions(
          for: NoteAutoActionEvent(
            trigger: .noteCreated,
            notebookId: conversationNotebookId,
            noteId: noteId,
            noteBodyMarkdown: note.bodyMarkdown
          ),
          in: db
        )
        return AppendResult(note: note, inserted: true, dispatches: dispatches)
      }
    }
    if result.inserted {
      dispatchQueuedAutoActions(result.dispatches)
      publishChange(NoteChangeEvent(
        kind: NoteChangeEventKind.noteCreated,
        notebookId: conversationNotebookId
      ))
    }
    return result.note
  }

  /// Fills in the assistant half and marks the turn answered.
  @discardableResult
  func completeAgentChatTurn(
    turnNoteId: String,
    assistantMarkdown: String,
    originatingActionId: String? = nil
  ) throws -> Note {
    try updateChatTurn(turnNoteId: turnNoteId) { state in
      AgentChatTurnState(status: .answered, userMarkdown: state.userMarkdown)
    } assistantMarkdown: { _ in
      assistantMarkdown
    }
  }

  /// Records a failed reply attempt; the turn stays retryable.
  @discardableResult
  func failAgentChatTurn(
    turnNoteId: String,
    message: String,
    originatingActionId: String? = nil
  ) throws -> Note {
    try updateChatTurn(turnNoteId: turnNoteId) { state in
      AgentChatTurnState(
        status: .failed,
        userMarkdown: state.userMarkdown,
        errorMessage: message
      )
    } assistantMarkdown: { _ in
      nil
    }
  }

  /// Conversations whose subject is the note, newest first.
  func listAgentConversations(
    subjectNoteId: String,
    limit: Int = 50
  ) throws -> [AgentChatConversation] {
    guard (0...200).contains(limit) else {
      throw NoteServiceError.invalidInput("limit must be between 0 and 200")
    }
    return try driver.withDatabase { database in
      let rows = try database.query(
        """
        SELECT nb.notebook_id AS notebook_id,
          (SELECT COUNT(*) FROM notes n WHERE n.notebook_id = nb.notebook_id) AS turn_count
        FROM notebooks nb
        WHERE json_extract(nb.meta_json, '$.kaibaChat.subjectNoteId') = ?
        ORDER BY nb.updated_at DESC, nb.notebook_id
        LIMIT ?
        """,
        bindings: [.text(subjectNoteId), .int(Int64(limit))]
      )
      return try rows.map { row in
        guard let notebookId = row["notebook_id"],
          let countText = row["turn_count"],
          let turnCount = Int(countText)
        else {
          throw NoteServiceError.invalidRow("agent conversation row is missing fields")
        }
        return AgentChatConversation(
          notebook: try requireNotebook(notebookId, in: database),
          subjectNoteId: subjectNoteId,
          turnCount: turnCount
        )
      }
    }
  }

  /// Parses chat turn state from a turn note's meta JSON; nil for non-chat notes.
  static func chatTurnState(of note: Note) -> AgentChatTurnState? {
    guard let metaJSON = note.metaJSON,
      let data = metaJSON.data(using: .utf8),
      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let chat = root["kaibaChat"] as? [String: Any],
      let statusText = chat["status"] as? String,
      let status = AgentChatTurnStatus(rawValue: statusText),
      let userMarkdown = chat["userMarkdown"] as? String
    else {
      return nil
    }
    return AgentChatTurnState(
      status: status,
      userMarkdown: userMarkdown,
      errorMessage: chat["error"] as? String
    )
  }

  /// The subject note id recorded in a conversation notebook's meta JSON.
  func chatSubjectNoteId(notebookId: String) throws -> String? {
    try driver.withDatabase { database in
      try chatSubjectNoteId(notebookId: notebookId, in: database)
    }
  }

  // MARK: - Reply generation (called by KaibaAutoActionDispatcher)

  /// Generates the assistant reply for a pending (or previously failed) turn.
  /// Answered turns are skipped, making dispatch retries idempotent.
  func generateAgentChatReply(
    turnNoteId: String,
    invoker: any AgentInvoking,
    provider: String? = nil,
    model: String? = nil,
    originatingActionId: String? = nil
  ) async throws {
    let turnNote = try getNote(turnNoteId)
    guard let state = Self.chatTurnState(of: turnNote) else {
      throw NoteServiceError.invalidInput("note is not an agent chat turn: \(turnNoteId)")
    }
    guard state.status != .answered else {
      return
    }
    guard let subjectNoteId = try chatSubjectNoteId(notebookId: turnNote.notebookId) else {
      throw NoteServiceError.invalidInput(
        "notebook is not an agent chat conversation: \(turnNote.notebookId)"
      )
    }
    let priorNotes = try listNotes(notebookId: turnNote.notebookId, limit: 100, offset: 0)
      .filter { $0.noteNumber < turnNote.noteNumber }
      .sorted { $0.noteNumber < $1.noteNumber }
    var turns: [AgentInvocationTurn] = []
    for note in priorNotes {
      guard let priorState = Self.chatTurnState(of: note) else {
        continue
      }
      turns.append(AgentInvocationTurn(role: .user, markdown: priorState.userMarkdown))
      if priorState.status == .answered,
        let assistant = Self.assistantMarkdown(fromTurnBody: note.bodyMarkdown) {
        turns.append(AgentInvocationTurn(role: .assistant, markdown: assistant))
      }
    }
    turns.append(AgentInvocationTurn(role: .user, markdown: state.userMarkdown))
    let subjectMarkdown = (try? getNote(subjectNoteId))?.bodyMarkdown
    let request = AgentInvocationRequest(
      purpose: .chat,
      systemPrompt: Self.chatSystemPrompt,
      turns: turns,
      contextMarkdown: subjectMarkdown.map { String($0.prefix(200 * 1024)) },
      provider: provider,
      model: model
    )
    do {
      let reply = try await invoker.invoke(request)
      _ = try completeAgentChatTurn(
        turnNoteId: turnNoteId,
        assistantMarkdown: reply.markdown,
        originatingActionId: originatingActionId
      )
    } catch {
      _ = try? failAgentChatTurn(
        turnNoteId: turnNoteId,
        message: "\(error)",
        originatingActionId: originatingActionId
      )
      throw error
    }
  }

  static var chatSystemPrompt: String {
    """
    You are a reading assistant for a note-taking system. The user is asking \
    about the document provided as context. Answer in markdown, grounded in \
    the document; quote short passages when helpful and say clearly when the \
    document does not contain the answer.
    """
  }

  // MARK: - Internals

  private func updateChatTurn(
    turnNoteId: String,
    transformState: (AgentChatTurnState) -> AgentChatTurnState,
    assistantMarkdown: (AgentChatTurnState) -> String?
  ) throws -> Note {
    let result = try driver.withDatabase { database in
      try database.transaction { db -> (note: Note, notebookId: String) in
        let note = try requireNote(turnNoteId, in: db)
        guard let state = Self.chatTurnState(of: note) else {
          throw NoteServiceError.invalidInput("note is not an agent chat turn: \(turnNoteId)")
        }
        let newState = transformState(state)
        let assistant = assistantMarkdown(state)
        let idempotencyKey = Self.chatIdempotencyKey(of: note)
        let body = Self.chatTurnBody(
          noteNumber: note.noteNumber,
          userMarkdown: newState.userMarkdown,
          assistantMarkdown: assistant
        )
        let metaJSON = try Self.chatTurnMetaJSON(state: newState, idempotencyKey: idempotencyKey)
        let previous = try ftsPayload(noteId: turnNoteId, in: db)
        let now = NoteStoreClock.system.now()
        try db.execute(
          """
          UPDATE notes
          SET body_markdown = ?, title = ?, meta_json = jsonb(?), updated_at = ?
          WHERE note_id = ?
          """,
          bindings: [
            .text(body),
            .optionalText(noteTitle(from: body)),
            .text(metaJSON),
            .text(now),
            .text(turnNoteId)
          ]
        )
        try db.execute(
          "UPDATE notebooks SET updated_at = ? WHERE notebook_id = ?",
          bindings: [.text(now), .text(note.notebookId)]
        )
        try refreshFTS(noteId: turnNoteId, previous: previous, in: db)
        return (try requireNote(turnNoteId, in: db), note.notebookId)
      }
    }
    publishChange(NoteChangeEvent(
      kind: NoteChangeEventKind.noteUpdated,
      notebookId: result.notebookId
    ))
    return result.note
  }

  private func chatSubjectNoteId(
    notebookId: String,
    in database: SQLiteDatabase
  ) throws -> String? {
    try database.query(
      """
      SELECT json_extract(meta_json, '$.kaibaChat.subjectNoteId') AS subject
      FROM notebooks
      WHERE notebook_id = ?
      LIMIT 1
      """,
      bindings: [.text(notebookId)]
    ).first?["subject"] ?? nil
  }

  private func chatTurn(
    notebookId: String,
    idempotencyKey: String,
    in database: SQLiteDatabase
  ) throws -> Note? {
    let rows = try database.query(
      """
      SELECT note_id
      FROM notes
      WHERE notebook_id = ?
        AND json_extract(meta_json, '$.kaibaChat.idempotencyKey') = ?
      LIMIT 1
      """,
      bindings: [.text(notebookId), .text(idempotencyKey)]
    )
    guard let noteId = rows.first?["note_id"] else {
      return nil
    }
    return try requireNote(noteId, in: database)
  }

  private func noteExists(_ noteId: String, in database: SQLiteDatabase) throws -> Bool {
    try !database.query(
      "SELECT note_id FROM notes WHERE note_id = ? LIMIT 1",
      bindings: [.text(noteId)]
    ).isEmpty
  }

  static func chatTurnBody(
    noteNumber: Int,
    userMarkdown: String,
    assistantMarkdown: String?
  ) -> String {
    """
    # Chat Turn \(noteNumber)

    ## User
    \(userMarkdown)

    ## Agent
    \(assistantMarkdown ?? "_(no reply yet)_")
    """
  }

  static func assistantMarkdown(fromTurnBody body: String) -> String? {
    guard let range = body.range(of: "\n## Agent\n") else {
      return nil
    }
    let assistant = String(body[range.upperBound...])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return assistant == "_(no reply yet)_" || assistant.isEmpty ? nil : assistant
  }

  static func chatIdempotencyKey(of note: Note) -> String? {
    guard let metaJSON = note.metaJSON,
      let data = metaJSON.data(using: .utf8),
      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let chat = root["kaibaChat"] as? [String: Any]
    else {
      return nil
    }
    return chat["idempotencyKey"] as? String
  }

  static func chatNotebookMetaJSON(
    subjectNoteId: String,
    subjectNotebookId: String
  ) throws -> String {
    let root = ["kaibaChat": [
      "subjectNoteId": subjectNoteId,
      "subjectNotebookId": subjectNotebookId
    ]]
    let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    guard let json = String(data: data, encoding: .utf8) else {
      throw NoteServiceError.invalidInput("chat notebook meta JSON must be UTF-8")
    }
    return json
  }

  static func chatTurnMetaJSON(
    state: AgentChatTurnState,
    idempotencyKey: String?
  ) throws -> String {
    var chat: [String: Any] = [
      "status": state.status.rawValue,
      "userMarkdown": state.userMarkdown
    ]
    chat["idempotencyKey"] = idempotencyKey
    chat["error"] = state.errorMessage
    let data = try JSONSerialization.data(
      withJSONObject: ["kaibaChat": chat],
      options: [.sortedKeys]
    )
    guard let json = String(data: data, encoding: .utf8) else {
      throw NoteServiceError.invalidInput("chat turn meta JSON must be UTF-8")
    }
    return json
  }
}
