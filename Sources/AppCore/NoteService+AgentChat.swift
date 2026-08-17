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

/// How the agent acts on a turn. `memo` answers in the conversation without
/// touching the subject; `edit` applies the requested change to the subject
/// note through `updateNoteBody`. Snapshotted per turn like `model`, so a
/// conversation can switch modes mid-thread.
public enum AgentChatTurnMode: String, Codable, Equatable, Sendable {
  case memo
  case edit
}

public struct AgentChatTurnState: Equatable, Sendable {
  public var status: AgentChatTurnStatus
  public var userMarkdown: String
  public var errorMessage: String?
  /// Immutable model snapshot selected when the turn was created.
  public var model: String?
  /// Immutable mode snapshot; nil means `memo`.
  public var mode: AgentChatTurnMode?

  public init(
    status: AgentChatTurnStatus,
    userMarkdown: String,
    errorMessage: String? = nil,
    model: String? = nil,
    mode: AgentChatTurnMode? = nil
  ) {
    self.status = status
    self.userMarkdown = userMarkdown
    self.errorMessage = errorMessage
    self.model = model
    self.mode = mode
  }
}

/// A validated text attachment supplied with an agent chat turn.
public struct AgentChatAttachment: Equatable, Sendable {
  public let data: Data
  public let mediaType: String
  public let originalFilename: String

  public init(data: Data, mediaType: String, originalFilename: String) {
    self.data = data
    self.mediaType = mediaType
    self.originalFilename = originalFilename
  }
}

public enum AgentChatAttachmentValidation {
  public static let maximumFiles = 4
  public static let maximumAggregateBytes = 1_048_576
  public static let maximumFilenameBytes = 255
  public static let maximumPromptFramingBytes = 4 * 1024
  public static let allowedMediaTypes: Set<String> = [
    "text/plain", "text/markdown", "text/csv", "text/tab-separated-values",
    "application/json", "application/xml", "application/yaml", "application/x-yaml"
  ]

  public static func validate(
    data: Data,
    declaredMediaType: String,
    originalFilename: String
  ) throws -> AgentChatAttachment {
    let mediaType = declaredMediaType.split(separator: ";", maxSplits: 1).first
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
    guard allowedMediaTypes.contains(mediaType) else {
      throw NoteServiceError.invalidInput("unsupported chat attachment media type")
    }
    guard !originalFilename.isEmpty,
      originalFilename.utf8.count <= maximumFilenameBytes,
      !originalFilename.contains("/"), !originalFilename.contains("\\"),
      !originalFilename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw NoteServiceError.invalidInput("invalid chat attachment filename")
    }
    guard !data.isEmpty, String(data: data, encoding: .utf8) != nil else {
      throw NoteServiceError.invalidInput("chat attachments must be non-empty UTF-8 text")
    }
    return AgentChatAttachment(data: data, mediaType: mediaType, originalFilename: originalFilename)
  }

  public static func validate(_ attachments: [AgentChatAttachment]) throws {
    guard attachments.count <= maximumFiles else {
      throw NoteServiceError.invalidInput("at most four chat attachments are allowed")
    }
    guard attachments.reduce(0, { $0 + $1.data.count }) <= maximumAggregateBytes else {
      throw NoteServiceError.invalidInput("chat attachments exceed 1 MiB")
    }
    let identities = attachments.map { "\($0.originalFilename)\u{0}\(sha256Hex($0.data))" }
    guard Set(identities).count == identities.count else {
      throw NoteServiceError.invalidInput("duplicate chat attachment")
    }
  }
}

/// What a chat conversation is about: a single note, or a whole notebook.
public enum AgentChatSubject: Equatable, Sendable {
  case note(NoteID)
  case notebook(NotebookID)
}

public struct AgentChatConversation: Equatable, Sendable {
  public var notebook: Notebook
  /// Nil for a notebook-scoped conversation.
  public var subjectNoteId: NoteID?
  /// The subject notebook: the note's notebook for note-scoped chats, the
  /// subject itself for notebook-scoped ones.
  public var subjectNotebookId: NotebookID?
  public var turnCount: Int

  public init(
    notebook: Notebook,
    subjectNoteId: NoteID?,
    subjectNotebookId: NotebookID? = nil,
    turnCount: Int
  ) {
    self.notebook = notebook
    self.subjectNoteId = subjectNoteId
    self.subjectNotebookId = subjectNotebookId
    self.turnCount = turnCount
  }
}

public extension NoteService {
  /// Creates the conversation notebook for a subject note.
  @discardableResult
  func startAgentConversation(
    subjectNoteId: NoteID,
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

  /// Creates the conversation notebook for a whole-notebook subject (a memo
  /// thread started with no note selected).
  @discardableResult
  func startAgentConversation(
    subjectNotebookId: NotebookID,
    title: String? = nil
  ) throws -> Notebook {
    let subject = try getNotebook(subjectNotebookId)
    let conversationTitle = title ?? "Chat: \(subject.title)"
    let metaJSON = try Self.chatNotebookMetaJSON(
      subjectNoteId: nil,
      subjectNotebookId: subjectNotebookId
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
    conversationNotebookId: NotebookID,
    userMarkdown: String,
    agentAvailable: Bool,
    idempotencyKey: String? = nil,
    model: String? = nil,
    mode: AgentChatTurnMode? = nil,
    attachments: [AgentChatAttachment] = []
  ) throws -> Note {
    let trimmed = userMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw NoteServiceError.invalidInput("chat message must not be empty")
    }
    try AgentChatAttachmentValidation.validate(attachments)
    let status: AgentChatTurnStatus = agentAvailable ? .pending : .unavailable
    struct AppendResult {
      var note: Note
      var inserted: Bool
      var dispatches: [QueuedAutoActionDispatch]
    }
    struct StagedAttachment {
      var attachment: AgentChatAttachment
      var fileId: FileID
      var stored: StoredNoteFile
    }
    let fileStore: any NoteFileStore = chatAttachmentFileStore
      ?? LocalNoteFileStore(noteRoot: noteRootPath())
    var staged: [StagedAttachment] = []
    do {
      for attachment in attachments {
        let fileId = FileID.generate()
        let stored = try fileStore.store(data: attachment.data, fileId: fileId)
        staged.append(StagedAttachment(attachment: attachment, fileId: fileId, stored: stored))
      }
    } catch {
      for stagedAttachment in staged {
        try? fileStore.delete(record: storedFileRecord(
          fileId: stagedAttachment.fileId,
          stored: stagedAttachment.stored,
          mediaType: stagedAttachment.attachment.mediaType,
          originalFilename: stagedAttachment.attachment.originalFilename
        ))
      }
      throw error
    }
    let cleanupStaged: () -> Void = {
      for stagedAttachment in staged {
        try? fileStore.delete(record: storedFileRecord(
          fileId: stagedAttachment.fileId,
          stored: stagedAttachment.stored,
          mediaType: stagedAttachment.attachment.mediaType,
          originalFilename: stagedAttachment.attachment.originalFilename
        ))
      }
    }
    let result: AppendResult
    do {
      result = try driver.withDatabase { database in
        try database.transaction { db -> AppendResult in
        _ = try requireWritableNotebook(conversationNotebookId, in: db)
        guard let subject = try chatSubject(
          notebookId: conversationNotebookId,
          in: db
        ) else {
          throw NoteServiceError.invalidInput(
            "notebook is not an agent chat conversation: \(conversationNotebookId)"
          )
        }
        // The client toggle is advisory; the mode a turn persists must pass
        // the same writability gate `updateNoteBody` enforces at apply time.
        if mode == .edit {
          guard case let .note(subjectNoteId) = subject else {
            throw NoteServiceError.invalidInput("note edit mode requires a note subject")
          }
          try requireWritableNote(subjectNoteId, in: db)
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
        let noteId = NoteID.generate()
        let body = Self.chatTurnBody(
          noteNumber: noteNumber,
          userMarkdown: trimmed,
          assistantMarkdown: nil
        )
        let metaJSON = try Self.chatTurnMetaJSON(
          state: AgentChatTurnState(status: status, userMarkdown: trimmed, model: model, mode: mode),
          idempotencyKey: idempotencyKey
        )
        try db.execute(
          """
          INSERT INTO notes (
            note_id, notebook_id, note_number, title, body_markdown,
            read_only, created_by, updated_by, created_at, updated_at, meta_json
          ) VALUES (
            ?, ?, ?, ?, ?, 0,
            (SELECT owner_user_id FROM notebooks WHERE notebook_id = ?),
            (SELECT owner_user_id FROM notebooks WHERE notebook_id = ?),
            ?, ?, jsonb(?)
          )
          """,
          bindings: [
            .id(noteId),
            .id(conversationNotebookId),
            .int(Int64(noteNumber)),
            .optionalText(noteTitle(from: body)),
            .text(body),
            .id(conversationNotebookId),
            .id(conversationNotebookId),
            .text(now),
            .text(now),
            .text(metaJSON)
          ]
        )
        for (position, stagedAttachment) in staged.enumerated() {
          let record = try insertFileRecord(
            fileId: stagedAttachment.fileId,
            stored: stagedAttachment.stored,
            mediaType: stagedAttachment.attachment.mediaType,
            originalFilename: stagedAttachment.attachment.originalFilename,
            in: db
          )
          try db.execute(
            "INSERT INTO note_files (note_id, file_id, role, position) VALUES (?, ?, ?, ?)",
            bindings: [
              .id(noteId), .id(record.fileId), .text(NoteFileRole.related.rawValue), .int(Int64(position))
            ]
          )
        }
        if case let .note(subjectNoteId) = subject, try noteExists(subjectNoteId, in: db) {
          _ = try linkNotesInDatabase(
            from: noteId,
            to: subjectNoteId,
            linkKind: "source-citation",
            provenance: .ai,
            in: db
          )
        }
        try db.execute(
          "UPDATE notebooks SET updated_at = ?, updated_by = owner_user_id WHERE notebook_id = ?",
          bindings: [.text(now), .id(conversationNotebookId)]
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
    } catch {
      cleanupStaged()
      throw error
    }
    if !result.inserted { cleanupStaged() }
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
    turnNoteId: NoteID,
    assistantMarkdown: String,
    originatingActionId: AutoActionID? = nil
  ) throws -> Note {
    try updateChatTurn(turnNoteId: turnNoteId) { state in
      AgentChatTurnState(
        status: .answered,
        userMarkdown: state.userMarkdown,
        model: state.model,
        mode: state.mode
      )
    } assistantMarkdown: { _ in
      assistantMarkdown
    }
  }

  /// Records a failed reply attempt; the turn stays retryable.
  @discardableResult
  func failAgentChatTurn(
    turnNoteId: NoteID,
    message: String,
    originatingActionId: AutoActionID? = nil
  ) throws -> Note {
    try updateChatTurn(turnNoteId: turnNoteId) { state in
      AgentChatTurnState(
        status: .failed,
        userMarkdown: state.userMarkdown,
        errorMessage: message,
        model: state.model,
        mode: state.mode
      )
    } assistantMarkdown: { _ in
      nil
    }
  }

  /// Conversations whose subject is the note, newest first.
  func listAgentConversations(
    subjectNoteId: NoteID,
    limit: Int = 50
  ) throws -> [AgentChatConversation] {
    try listAgentConversations(
      predicate: "json_extract(nb.meta_json, '$.kaibaChat.subjectNoteId') = ?",
      binding: subjectNoteId,
      limit: limit
    )
  }

  /// Conversations whose subject is the whole notebook (started with no note
  /// selected), newest first. Note-scoped conversations inside the notebook do
  /// not appear here — they belong to their note.
  func listAgentConversations(
    subjectNotebookId: NotebookID,
    limit: Int = 50
  ) throws -> [AgentChatConversation] {
    try listAgentConversations(
      predicate: """
        json_extract(nb.meta_json, '$.kaibaChat.subjectNotebookId') = ?
          AND json_extract(nb.meta_json, '$.kaibaChat.subjectNoteId') IS NULL
        """,
      binding: subjectNotebookId,
      limit: limit
    )
  }

  private func listAgentConversations(
    predicate: String,
    binding: some KaibaIdentifier,
    limit: Int
  ) throws -> [AgentChatConversation] {
    guard (0...200).contains(limit) else {
      throw NoteServiceError.invalidInput("limit must be between 0 and 200")
    }
    return try driver.withDatabase { database in
      let rows = try database.query(
        """
        SELECT nb.notebook_id AS notebook_id,
          json_extract(nb.meta_json, '$.kaibaChat.subjectNoteId') AS subject_note_id,
          json_extract(nb.meta_json, '$.kaibaChat.subjectNotebookId') AS subject_notebook_id,
          (SELECT COUNT(*) FROM notes n WHERE n.notebook_id = nb.notebook_id) AS turn_count
        FROM notebooks nb
        WHERE \(predicate)
        ORDER BY nb.updated_at DESC, nb.notebook_id
        LIMIT ?
        """,
        bindings: [.id(binding), .int(Int64(limit))]
      )
      return try rows.map { row in
        guard let notebookId = row.identifier("notebook_id", as: NotebookID.self),
          let countText = row["turn_count"],
          let turnCount = Int(countText)
        else {
          throw NoteServiceError.invalidRow("agent conversation row is missing fields")
        }
        return AgentChatConversation(
          notebook: try requireNotebook(notebookId, in: database),
          subjectNoteId: row.identifier("subject_note_id", as: NoteID.self) ?? nil,
          subjectNotebookId: row.identifier("subject_notebook_id", as: NotebookID.self) ?? nil,
          turnCount: turnCount
        )
      }
    }
  }

  /// Parses chat turn state from a turn note's meta JSON; nil for non-chat notes.
  static func chatTurnState(of note: Note) -> AgentChatTurnState? {
    guard let metaJSON = note.metaJSON,
      let root = try? JSONValue(parsing: metaJSON),
      let chat = root["kaibaChat"],
      let statusText = chat["status"]?.asString,
      let status = AgentChatTurnStatus(rawValue: statusText),
      let userMarkdown = chat["userMarkdown"]?.asString
    else {
      return nil
    }
    return AgentChatTurnState(
      status: status,
      userMarkdown: userMarkdown,
      errorMessage: chat["error"]?.asString,
      model: chat["model"]?.asString,
      mode: chat["mode"]?.asString.flatMap(AgentChatTurnMode.init(rawValue:))
    )
  }

  /// The subject note id recorded in a conversation notebook's meta JSON.
  func chatSubjectNoteId(notebookId: NotebookID) throws -> NoteID? {
    try driver.withDatabase { database in
      try chatSubjectNoteId(notebookId: notebookId, in: database)
    }
  }

  /// The conversation's subject (note or notebook); nil when the notebook is
  /// not an agent chat conversation.
  func chatSubject(notebookId: NotebookID) throws -> AgentChatSubject? {
    try driver.withDatabase { database in
      try chatSubject(notebookId: notebookId, in: database)
    }
  }

  // MARK: - Reply generation (called by KaibaAutoActionDispatcher)

  /// Generates the assistant reply for a pending (or previously failed) turn.
  /// Answered turns are skipped, making dispatch retries idempotent.
  func generateAgentChatReply(
    turnNoteId: NoteID,
    invoker: any AgentInvoking,
    provider: String? = nil,
    model: String? = nil,
    originatingActionId: AutoActionID? = nil,
    streamPublisher: (any AgentReplyStreamPublishing)? = nil
  ) async throws {
    let turnNote = try getNote(turnNoteId)
    guard let state = Self.chatTurnState(of: turnNote) else {
      throw NoteServiceError.invalidInput("note is not an agent chat turn: \(turnNoteId)")
    }
    guard state.status != .answered else {
      return
    }
    guard let subject = try chatSubject(notebookId: turnNote.notebookId) else {
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
    let attachmentContext = try chatAttachmentContext(
      currentTurn: turnNote,
      priorTurnsNewestFirst: priorNotes.reversed()
    )
    turns.append(AgentInvocationTurn(
      role: .user,
      markdown: state.userMarkdown + attachmentContext
    ))
    // Edit mode only ever targets a note subject (enforced at append time);
    // a stale or hand-written mode on another subject degrades to memo chat.
    var editSubjectNoteId: NoteID?
    if state.mode == .edit, case let .note(subjectNoteId) = subject {
      editSubjectNoteId = subjectNoteId
    }
    var noteEditApplied = false
    do {
      let subjectMarkdown: String?
      switch subject {
      case let .note(subjectNoteId):
        if editSubjectNoteId != nil {
          // The reply replaces the whole body, so the agent must see all of
          // it: a fetch failure or an over-budget body fails the turn instead
          // of letting the agent rewrite the note from a partial view.
          let body = try getNote(subjectNoteId).bodyMarkdown
          guard body.utf8.count <= Self.subjectContextLimitBytes else {
            throw NoteServiceError.invalidInput(
              "note \(subjectNoteId) is too large to edit in agent chat"
            )
          }
          subjectMarkdown = body
        } else {
          subjectMarkdown = ((try? getNote(subjectNoteId))?.bodyMarkdown)
            .map { utf8Prefix($0, limit: Self.subjectContextLimitBytes) }
        }
      case let .notebook(subjectNotebookId):
        // A tag-memo subject notebook holds only chat/memo state; ground the
        // agent on the tag's occurrences across notebooks instead (T4).
        if let subjectTagId = (try? tagMemoSubjectTagId(notebookId: subjectNotebookId)) ?? nil {
          subjectMarkdown = try? tagContextMarkdown(tagId: subjectTagId)
        } else {
          subjectMarkdown = try? notebookContextMarkdown(notebookId: subjectNotebookId)
        }
      }
      let request = AgentInvocationRequest(
        purpose: .chat,
        systemPrompt: editSubjectNoteId == nil ? Self.chatSystemPrompt : Self.noteEditSystemPrompt,
        turns: turns,
        contextMarkdown: subjectMarkdown,
        provider: provider,
        model: state.model ?? model
      )
      let reply: AgentInvocationResult
      // An edit-mode reply is mostly the raw replacement body; streaming it
      // into the memo timeline would show markup, so it completes in one shot.
      if editSubjectNoteId == nil, let streamPublisher, let streaming = invoker as? AgentStreamingInvoking {
        reply = try await streaming.invoke(request) { chunk in
          streamPublisher.publishAgentReplyChunk(turnNoteId: turnNoteId, text: chunk)
        }
      } else {
        reply = try await invoker.invoke(request)
      }
      let assistantMarkdown: String
      if let editSubjectNoteId {
        let applied = try applyNoteEditReply(
          reply.markdown,
          subjectNoteId: editSubjectNoteId,
          originatingActionId: originatingActionId
        )
        assistantMarkdown = applied.assistantMarkdown
        noteEditApplied = applied.updatedNote
      } else {
        assistantMarkdown = reply.markdown
      }
      _ = try completeAgentChatTurn(
        turnNoteId: turnNoteId,
        assistantMarkdown: assistantMarkdown,
        originatingActionId: originatingActionId
      )
      streamPublisher?.finishAgentReplyStream(
        turnNoteId: turnNoteId,
        status: "answered",
        message: nil
      )
    } catch {
      // A committed note edit survives a later turn-persistence failure; the
      // failure message must not imply the note is untouched.
      let message = noteEditApplied
        ? "the note edit was applied, but recording the turn failed: \(error)"
        : "\(error)"
      _ = try? failAgentChatTurn(
        turnNoteId: turnNoteId,
        message: message,
        originatingActionId: originatingActionId
      )
      streamPublisher?.finishAgentReplyStream(
        turnNoteId: turnNoteId,
        status: "failed",
        message: message
      )
      throw error
    }
  }

  /// Byte budget for the subject document handed to the agent as context.
  static let subjectContextLimitBytes = 200 * 1024

  /// Notebook-subject context: title plus each note's markdown in page order,
  /// capped so a large imported document cannot blow the prompt.
  func notebookContextMarkdown(
    notebookId: NotebookID,
    limitBytes: Int = 200 * 1024
  ) throws -> String {
    let notebook = try getNotebook(notebookId)
    return boundedMarkdownContext(
      heading: "# \(notebook.title)",
      sections: try listNotes(notebookId: notebookId, limit: 200, offset: 0).map(\.bodyMarkdown),
      limitBytes: limitBytes
    )
  }

  static var chatSystemPrompt: String {
    """
    You are a reading assistant for a note-taking system. The user is asking \
    about the document provided as context. Answer in markdown, grounded in \
    the document; quote short passages when helpful and say clearly when the \
    document does not contain the answer.
    """
  }

  /// One deterministic attachment context is appended to the current user
  /// turn: current files first, then prior turns newest-first. Content and
  /// framing have independent global budgets. Metadata is percent-normalized
  /// to a bounded representation before inclusion in delimiters.
  private func chatAttachmentContext(
    currentTurn: Note,
    priorTurnsNewestFirst: ReversedCollection<[Note]>
  ) throws -> String {
    var contentRemaining = AgentChatAttachmentValidation.maximumAggregateBytes
    let opening = "\n<untrusted-attachments>\n"
    let closing = "</untrusted-attachments>"
    var framingRemaining = AgentChatAttachmentValidation.maximumPromptFramingBytes
      - opening.utf8.count - closing.utf8.count
    var context = opening
    let orderedTurns = [currentTurn] + priorTurnsNewestFirst
    for turn in orderedTurns {
      let attachments = try listFiles(noteId: turn.noteId).sorted {
        $0.position == $1.position ? $0.file.fileId < $1.file.fileId : $0.position < $1.position
      }
      for attachment in attachments {
        let filename = promptMetadata(attachment.file.originalFilename ?? attachment.file.fileId.rawValue)
        let mediaType = promptMetadata(attachment.file.mediaType)
        let header = "<attachment filename=\"\(filename)\" media-type=\"\(mediaType)\">\n"
        let footer = "\n</attachment>"
        let attachmentFraming = header.utf8.count + footer.utf8.count
        guard attachmentFraming <= framingRemaining else {
          // Accepted current-turn filenames are bounded so this is only
          // reachable for prior turns. Do not add further omission markers.
          return context + closing
        }
        let text = String(data: try resolveFileContent(fileId: attachment.file.fileId), encoding: .utf8) ?? ""
        if text.utf8.count <= contentRemaining {
          contentRemaining -= text.utf8.count
          framingRemaining -= attachmentFraming
          context += header + text + footer
        } else {
          let omission = "<attachment omitted=\"budget\" filename=\"\(filename)\" media-type=\"\(mediaType)\" />"
          guard omission.utf8.count <= framingRemaining else { return context + closing }
          framingRemaining -= omission.utf8.count
          context += omission
        }
      }
    }
    return context == opening ? "" : context + closing
  }

  /// Percent encoding constrains every metadata byte to at most three bytes;
  /// four accepted 255-byte filenames therefore fit the 4 KiB framing budget.
  private func promptMetadata(_ value: String) -> String {
    value.utf8.map { byte in
      switch byte {
      case 45, 46, 48...57, 65...90, 95, 97...122:
        String(UnicodeScalar(byte))
      default:
        String(format: "%%%02X", byte)
      }
    }.joined()
  }

  // MARK: - Internals

  private func updateChatTurn(
    turnNoteId: NoteID,
    transformState: (AgentChatTurnState) -> AgentChatTurnState,
    assistantMarkdown: (AgentChatTurnState) -> String?
  ) throws -> Note {
    let result = try driver.withDatabase { database in
      try database.transaction { db -> (note: Note, notebookId: NotebookID) in
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
        try db.execute(
          "UPDATE notebooks SET updated_at = ?, updated_by = owner_user_id WHERE notebook_id = ?",
          bindings: [.text(now), .id(note.notebookId)]
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
    notebookId: NotebookID,
    in database: SQLiteDatabase
  ) throws -> NoteID? {
    try database.query(
      """
      SELECT json_extract(meta_json, '$.kaibaChat.subjectNoteId') AS subject
      FROM notebooks
      WHERE notebook_id = ?
      LIMIT 1
      """,
      bindings: [.id(notebookId)]
    ).first?.identifier("subject", as: NoteID.self)
  }

  private func chatSubject(
    notebookId: NotebookID,
    in database: SQLiteDatabase
  ) throws -> AgentChatSubject? {
    guard let row = try database.query(
      """
      SELECT json_extract(meta_json, '$.kaibaChat.subjectNoteId') AS subject_note,
        json_extract(meta_json, '$.kaibaChat.subjectNotebookId') AS subject_notebook
      FROM notebooks
      WHERE notebook_id = ?
      LIMIT 1
      """,
      bindings: [.id(notebookId)]
    ).first else {
      return nil
    }
    if let subjectNoteId = row.identifier("subject_note", as: NoteID.self) {
      return .note(subjectNoteId)
    }
    if let subjectNotebookId = row.identifier("subject_notebook", as: NotebookID.self) {
      return .notebook(subjectNotebookId)
    }
    return nil
  }

  private func chatTurn(
    notebookId: NotebookID,
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
      bindings: [.id(notebookId), .text(idempotencyKey)]
    )
    guard let noteId = rows.first?.identifier("note_id", as: NoteID.self) else {
      return nil
    }
    return try requireNote(noteId, in: database)
  }

  private func noteExists(_ noteId: NoteID, in database: SQLiteDatabase) throws -> Bool {
    try !database.query(
      "SELECT note_id FROM notes WHERE note_id = ? LIMIT 1",
      bindings: [.id(noteId)]
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
      let root = try? JSONValue(parsing: metaJSON),
      let chat = root["kaibaChat"]
    else {
      return nil
    }
    return chat["idempotencyKey"]?.asString
  }

  static func chatNotebookMetaJSON(
    subjectNoteId: NoteID?,
    subjectNotebookId: NotebookID
  ) throws -> String {
    var chat: JSONObject = ["subjectNotebookId": .id(subjectNotebookId)]
    chat["subjectNoteId"] = subjectNoteId.map(JSONValue.id)
    do {
      return try JSONValue.object(["kaibaChat": .object(chat)]).encodedString()
    } catch {
      throw NoteServiceError.invalidInput("chat notebook meta JSON must be UTF-8")
    }
  }

  static func chatTurnMetaJSON(
    state: AgentChatTurnState,
    idempotencyKey: String?
  ) throws -> String {
    var chat: JSONObject = [
      "status": .string(state.status.rawValue),
      "userMarkdown": .string(state.userMarkdown)
    ]
    chat["idempotencyKey"] = idempotencyKey.map(JSONValue.string)
    chat["error"] = state.errorMessage.map(JSONValue.string)
    chat["model"] = state.model.map(JSONValue.string)
    chat["mode"] = state.mode.map { .string($0.rawValue) }
    do {
      return try JSONValue.object(["kaibaChat": .object(chat)]).encodedString()
    } catch {
      throw NoteServiceError.invalidInput("chat turn meta JSON must be UTF-8")
    }
  }
}
