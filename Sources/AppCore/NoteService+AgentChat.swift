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
  /// Terminal safety stop: this turn must not resume if its original account
  /// is later re-enabled.
  case cancelled
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
  /// Immutable library that authorized the provider context for an answered
  /// reply. A recovered outbox lease uses this to terminalize its stream
  /// without weakening visibility after a later conversation move.
  public var replyLibraryId: LibraryID?

  public init(
    status: AgentChatTurnStatus,
    userMarkdown: String,
    errorMessage: String? = nil,
    model: String? = nil,
    mode: AgentChatTurnMode? = nil,
    replyLibraryId: LibraryID? = nil
  ) {
    self.status = status
    self.userMarkdown = userMarkdown
    self.errorMessage = errorMessage
    self.model = model
    self.mode = mode
    self.replyLibraryId = replyLibraryId
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
  /// Returns a committed idempotent turn after authorizing its conversation.
  ///
  /// Replay intentionally does not resolve the conversation subject: a turn
  /// that was valid when committed remains replayable after that mutable
  /// subject is deleted. New sends continue through
  /// `appendPendingAgentChatTurn`, which validates the subject before insert.
  func existingAgentChatTurn(
    conversationNotebookId: NotebookID,
    idempotencyKey: String
  ) throws -> Note? {
    try driver.withDatabase { database in
      let conversation = try requireNotebook(conversationNotebookId, in: database)
      guard try isReplayableAgentChatConversation(conversation, in: database) else {
        return nil
      }
      return try chatTurn(
        notebookId: conversationNotebookId,
        idempotencyKey: idempotencyKey,
        in: database
      )
    }
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
        // Replays are reads of a turn already committed in this conversation.
        // Authorize the conversation first, but do not revalidate its mutable
        // subject: that subject may legitimately have been deleted since the
        // original request completed.
        let conversation = try requireNotebook(conversationNotebookId, in: db)
        if let idempotencyKey,
          try isReplayableAgentChatConversation(conversation, in: db),
          let existing = try chatTurn(
            notebookId: conversationNotebookId,
            idempotencyKey: idempotencyKey,
            in: db
          ) {
          return AppendResult(note: existing, inserted: false, dispatches: [])
        }

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
      var queryBindings: [SQLiteValue] = [.id(binding)]
      var ownershipPredicate = ""
      var libraryReachPredicate = ""
      if let actingUserId {
        ownershipPredicate = " AND nb.owner_user_id = ?"
        queryBindings.append(.id(actingUserId))
      }
      if let reachableLibraryIds = try reachableLibraryIds(in: database) {
        guard !reachableLibraryIds.isEmpty else {
          return []
        }
        libraryReachPredicate = " AND nb.library_id IN (\(placeholders(count: reachableLibraryIds.count)))"
        queryBindings.append(contentsOf: reachableLibraryIds.sqliteBindings)
      }
      queryBindings.append(.int(Int64(limit)))
      let rows = try database.query(
        """
        SELECT nb.notebook_id AS notebook_id,
          json_extract(nb.meta_json, '$.kaibaChat.subjectNoteId') AS subject_note_id,
          json_extract(nb.meta_json, '$.kaibaChat.subjectNotebookId') AS subject_notebook_id,
          (SELECT COUNT(*) FROM notes n WHERE n.notebook_id = nb.notebook_id) AS turn_count
        FROM notebooks nb
        WHERE \(predicate)\(ownershipPredicate)\(libraryReachPredicate)
        ORDER BY nb.updated_at DESC, nb.notebook_id
        LIMIT ?
        """,
        bindings: queryBindings
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
      mode: chat["mode"]?.asString.flatMap(AgentChatTurnMode.init(rawValue:)),
      replyLibraryId: chat.identifier("replyLibraryId", as: LibraryID.self)
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
    if state.status == .answered {
      try await reconcileAnsweredAgentReplyStream(
        turnNote: turnNote,
        state: state,
        streamPublisher: streamPublisher
      )
      return
    }
    guard state.status != .cancelled else {
      return
    }
    let subjectSnapshot = try agentChatSubjectSnapshot(
      conversationNotebookId: turnNote.notebookId,
      editMode: state.mode == .edit
    )
    let subject = subjectSnapshot.subject
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
    var turnWasCompleted = false
    do {
      let request = AgentInvocationRequest(
        purpose: .chat,
        systemPrompt: editSubjectNoteId == nil ? Self.chatSystemPrompt : Self.noteEditSystemPrompt,
        turns: turns,
        contextMarkdown: subjectSnapshot.markdown,
        provider: provider,
        model: state.model ?? model
      )
      let reply: AgentInvocationResult
      try await admitAutoActionProviderInvocation()
      // An edit-mode reply is mostly the raw replacement body; streaming it
      // into the memo timeline would show markup, so it completes in one shot.
      if editSubjectNoteId == nil, let streamPublisher, let streaming = invoker as? AgentStreamingInvoking {
        let lease: AgentReplyStreamLease?
        if requiresActiveAutoActionDispatchLease {
          guard let activeLease = try activeAgentReplyStreamLease() else {
            throw NoteServiceError.conflict("auto-action dispatch lease is no longer active")
          }
          lease = activeLease
        } else {
          lease = nil
        }
        let postLeaseValidationHook = agentReplyStreamPostLeaseValidationHook
        let chunkRelay = AgentReplyChunkRelay { chunk in
          if let lease {
            await postLeaseValidationHook?(lease)
            await streamPublisher.publishLeasedAgentReplyChunk(
              turnNoteId: turnNoteId,
              text: chunk,
              libraryId: subjectSnapshot.libraryId,
              lease: lease
            )
          } else {
            streamPublisher.publishAgentReplyChunk(
              turnNoteId: turnNoteId,
              text: chunk,
              libraryId: subjectSnapshot.libraryId
            )
          }
        }
        reply = try await streaming.invoke(request) { chunk in
          chunkRelay.append(chunk)
        }
        try await chunkRelay.finishPublishing()
      } else {
        reply = try await invoker.invoke(request)
      }
      try AgentReplyOutputLimits.validateFinalReply(reply.markdown)
      let assistantMarkdown: String
      if let editSubjectNoteId {
        let applied = try applyNoteEditReply(
          reply.markdown,
          turnNoteId: turnNoteId,
          subjectNoteId: editSubjectNoteId,
          conversationNotebookId: turnNote.notebookId,
          expectedSubject: subject,
          expectedLibraryId: subjectSnapshot.libraryId,
          expectedSubjectBodyMarkdown: subjectSnapshot.noteBodyMarkdown,
          originatingActionId: originatingActionId
        )
        assistantMarkdown = applied.assistantMarkdown
        turnWasCompleted = applied.updatedNote
      } else {
        assistantMarkdown = reply.markdown
      }
      if !turnWasCompleted {
        _ = try completeAgentChatTurn(
          turnNoteId: turnNoteId,
          assistantMarkdown: assistantMarkdown,
          expectedSubject: subject,
          expectedLibraryId: subjectSnapshot.libraryId,
          originatingActionId: originatingActionId
        )
      }
      if let streamPublisher {
        if activeAutoActionDispatchLease != nil {
          guard let lease = try activeAgentReplyStreamLease() else { return }
          guard hasActiveAutoActionDispatchLease() else { return }
          await agentReplyStreamPostLeaseValidationHook?(lease)
          await streamPublisher.finishLeasedAgentReplyStream(
            turnNoteId: turnNoteId,
            status: "answered",
            message: nil,
            libraryId: subjectSnapshot.libraryId,
            lease: lease
          )
        } else {
          streamPublisher.finishAgentReplyStream(
            turnNoteId: turnNoteId,
            status: "answered",
            message: nil,
            libraryId: subjectSnapshot.libraryId
          )
        }
      }
    } catch {
      let message = "\(error)"
      let failureWasRecorded = (try? failAgentChatTurn(
        turnNoteId: turnNoteId,
        message: message,
        expectedSubject: subject,
        expectedLibraryId: subjectSnapshot.libraryId,
        originatingActionId: originatingActionId
      )) != nil
      if let streamPublisher {
        if activeAutoActionDispatchLease != nil {
          if let lease = try activeAgentReplyStreamLease(), hasActiveAutoActionDispatchLease() {
            await agentReplyStreamPostLeaseValidationHook?(lease)
            await streamPublisher.finishLeasedAgentReplyStream(
              turnNoteId: turnNoteId,
              status: "failed",
              message: failureWasRecorded ? message : nil,
              libraryId: subjectSnapshot.libraryId,
              lease: lease
            )
          }
        } else {
          streamPublisher.finishAgentReplyStream(
            turnNoteId: turnNoteId,
            status: "failed",
            message: failureWasRecorded ? message : nil,
            libraryId: subjectSnapshot.libraryId
          )
        }
      }
      throw error
    }
  }

  /// Byte budget for the subject document handed to the agent as context.
  static let subjectContextLimitBytes = 200 * 1024

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

  private func chatSubjectNoteId(
    notebookId: NotebookID,
    in database: SQLiteDatabase
  ) throws -> NoteID? {
    guard case let .note(subjectNoteId)? = try chatSubject(notebookId: notebookId, in: database) else {
      return nil
    }
    return subjectNoteId
  }

  func chatSubject(
    notebookId: NotebookID,
    in database: SQLiteDatabase
  ) throws -> AgentChatSubject? {
    let conversation = try requireNotebook(notebookId, in: database)
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
    let subjectNoteId = row.identifier("subject_note", as: NoteID.self)
    let subjectNotebookId = row.identifier("subject_notebook", as: NotebookID.self)
    if let subjectNoteId {
      let subjectNote = try requireNote(subjectNoteId, in: database)
      let subjectNotebook = try requireNotebook(subjectNote.notebookId, in: database)
      guard subjectNotebook.ownerUserId == conversation.ownerUserId,
        subjectNotebook.libraryId == conversation.libraryId,
        subjectNotebookId == nil || subjectNotebookId == subjectNotebook.notebookId
      else {
        throw NoteServiceError.invalidInput(
          "agent chat conversation has an invalid note subject: \(notebookId)"
        )
      }
      return .note(subjectNoteId)
    }
    if let subjectNotebookId {
      let subjectNotebook = try requireNotebook(subjectNotebookId, in: database)
      guard subjectNotebook.ownerUserId == conversation.ownerUserId,
        subjectNotebook.libraryId == conversation.libraryId
      else {
        throw NoteServiceError.invalidInput(
          "agent chat conversation has an invalid notebook subject: \(notebookId)"
        )
      }
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
      ORDER BY note_number, note_id
      """,
      bindings: [.id(notebookId), .text(idempotencyKey)]
    )
    for row in rows {
      guard let noteId = row.identifier("note_id", as: NoteID.self) else {
        throw NoteServiceError.invalidRow("idempotent chat turn row is missing note ID")
      }
      let note = try requireNote(noteId, in: database)
      guard Self.chatIdempotencyKey(of: note) == idempotencyKey,
        Self.chatTurnState(of: note) != nil
      else {
        continue
      }
      return note
    }
    return nil
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
    chat["replyLibraryId"] = state.replyLibraryId.map(JSONValue.id)
    do {
      return try JSONValue.object(["kaibaChat": .object(chat)]).encodedString()
    } catch {
      throw NoteServiceError.invalidInput("chat turn meta JSON must be UTF-8")
    }
  }

  /// Recovery may claim a new outbox lease after an answered turn committed
  /// but before its original worker admitted the terminal stream marker. The
  /// durable answer is authoritative, so finish the current lease's stream
  /// without invoking the provider again. `replyLibraryId` preserves the
  /// provider-context visibility boundary across a later notebook move.
  private func reconcileAnsweredAgentReplyStream(
    turnNote: Note,
    state: AgentChatTurnState,
    streamPublisher: (any AgentReplyStreamPublishing)?
  ) async throws {
    guard let streamPublisher, activeAutoActionDispatchLease != nil,
      let lease = try activeAgentReplyStreamLease()
    else {
      return
    }
    let libraryId: LibraryID
    if let replyLibraryId = state.replyLibraryId {
      libraryId = replyLibraryId
    } else {
      libraryId = try getNotebook(turnNote.notebookId).libraryId
        ?? LibraryID(NoteStoreSchema.defaultLibraryName)
    }
    await agentReplyStreamPostLeaseValidationHook?(lease)
    await streamPublisher.finishLeasedAgentReplyStream(
      turnNoteId: turnNote.noteId,
      status: "answered",
      message: nil,
      libraryId: libraryId,
      lease: lease
    )
  }
}
