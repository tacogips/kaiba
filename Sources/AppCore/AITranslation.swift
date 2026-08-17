import Foundation

/// Notebook translation (`design-docs/specs/ai-agent-integration.md`, AI9).
/// A translation is a `notebook-kind:translation` notebook created up front in
/// `pending` state; the translation run then appends one translated note per
/// source note and finally flips the state to `completed` (or `failed`).
/// Translation state lives in notebook meta JSON under `kaibaTranslation`, and
/// every translated note records its source note under the same key, matching
/// the `kaibaChat` precedent.

public enum AITranslationStatus: String, Codable, Equatable, Sendable {
  case pending
  case completed
  case failed
}

public struct AITranslationState: Equatable, Sendable {
  public var sourceNotebookId: NotebookID
  public var targetLanguage: String
  public var status: AITranslationStatus
  public var errorMessage: String?

  public init(
    sourceNotebookId: NotebookID,
    targetLanguage: String,
    status: AITranslationStatus,
    errorMessage: String? = nil
  ) {
    self.sourceNotebookId = sourceNotebookId
    self.targetLanguage = targetLanguage
    self.status = status
    self.errorMessage = errorMessage
  }
}

public extension NoteService {
  static let manualTranslationActionId = AutoActionID("manual-notebook-translation")

  /// Creates the pending translation notebook for a source notebook. The run
  /// itself happens in `AITranslationService.run`, synchronously from the CLI
  /// or via the `notebook-translation` auto-action dispatch.
  @discardableResult
  func startNotebookTranslation(
    sourceNotebookId: NotebookID,
    targetLanguage: String,
    title: String? = nil
  ) throws -> Notebook {
    let language = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !language.isEmpty else {
      throw NoteServiceError.invalidInput("translation target language must not be empty")
    }
    let source = try getNotebook(sourceNotebookId)
    guard !(try listNotes(notebookId: sourceNotebookId, limit: 1, offset: 0).isEmpty) else {
      throw NoteServiceError.invalidInput(
        "source notebook has no notes to translate: \(sourceNotebookId)"
      )
    }
    let metaJSON = try Self.translationNotebookMetaJSON(state: AITranslationState(
      sourceNotebookId: sourceNotebookId,
      targetLanguage: language,
      status: .pending
    ))
    // originatingActionId suppresses follow-up auto-actions (auto-tagging has
    // nothing useful to say about an empty pending notebook).
    return try createNotebook(
      title: title ?? "\(source.title) [\(language)]",
      kindTagName: NoteStoreSchema.translationNotebookKindTag,
      metaJSON: metaJSON,
      originatingActionId: Self.manualTranslationActionId
    )
  }

  /// Queues an async translation run (the UI's "translate" button and the
  /// GraphQL `requestNotebookTranslation` mutation). Returns `(nil, false)`
  /// without creating anything when no dispatcher is installed (agent
  /// unavailable), so no pending notebook is ever left with nothing to
  /// drain it.
  func requestNotebookTranslation(
    sourceNotebookId: NotebookID,
    targetLanguage: String,
    title: String? = nil
  ) throws -> (notebook: Notebook?, queued: Bool) {
    _ = try getNotebook(sourceNotebookId)
    guard autoActionDispatcher != nil else {
      return (nil, false)
    }
    let notebook = try startNotebookTranslation(
      sourceNotebookId: sourceNotebookId,
      targetLanguage: targetLanguage,
      title: title
    )
    let action = AutoAction(
      actionId: Self.manualTranslationActionId,
      trigger: .notebookCreated,
      workflowId: NoteStoreSchema.notebookTranslationWorkflowId,
      filterJSON: nil,
      enabled: true,
      position: 0,
      createdAt: NoteStoreClock.system.now()
    )
    let event = NoteAutoActionEvent(
      trigger: .notebookCreated,
      notebookId: notebook.notebookId
    )
    let queued = try driver.withDatabase { database in
      try database.transaction { db in
        try enqueueManualAutoActionDispatch(action: action, event: event, in: db)
      }
    }
    dispatchQueuedAutoActions([queued])
    return (notebook, true)
  }

  /// Parses translation state from a notebook's meta JSON; nil for
  /// non-translation notebooks.
  static func translationState(of notebook: Notebook) -> AITranslationState? {
    guard let metaJSON = notebook.metaJSON,
      let root = try? JSONValue(parsing: metaJSON),
      let translation = root["kaibaTranslation"],
      let sourceNotebookId: NotebookID = translation.identifier("sourceNotebookId"),
      let targetLanguage = translation["targetLanguage"]?.asString,
      let statusText = translation["status"]?.asString,
      let status = AITranslationStatus(rawValue: statusText)
    else {
      return nil
    }
    return AITranslationState(
      sourceNotebookId: sourceNotebookId,
      targetLanguage: targetLanguage,
      status: status,
      errorMessage: translation["error"]?.asString
    )
  }

  /// Rewrites the `kaibaTranslation` status on a translation notebook,
  /// preserving any other meta JSON keys.
  @discardableResult
  func setNotebookTranslationStatus(
    _ notebookId: NotebookID,
    status: AITranslationStatus,
    errorMessage: String? = nil
  ) throws -> Notebook {
    let updated = try driver.withDatabase { database in
      try database.transaction { db -> Notebook in
        let notebook = try requireNotebook(notebookId, in: db)
        guard var state = Self.translationState(of: notebook) else {
          throw NoteServiceError.invalidInput(
            "notebook is not a translation notebook: \(notebookId)"
          )
        }
        state.status = status
        state.errorMessage = errorMessage
        let metaJSON = try Self.translationNotebookMetaJSON(
          state: state,
          mergingInto: notebook.metaJSON
        )
        try db.execute(
          "UPDATE notebooks SET meta_json = jsonb(?), updated_at = ?, updated_by = owner_user_id WHERE notebook_id = ?",
          bindings: [
            .text(metaJSON),
            .text(NoteStoreClock.system.now()),
            .id(notebookId)
          ]
        )
        return try requireNotebook(notebookId, in: db)
      }
    }
    publishChange(NoteChangeEvent(
      kind: NoteChangeEventKind.noteUpdated,
      notebookId: notebookId
    ))
    return updated
  }

  static func translationNotebookMetaJSON(
    state: AITranslationState,
    mergingInto existingMetaJSON: String? = nil
  ) throws -> String {
    var root: JSONObject = [:]
    if let existingMetaJSON,
      let existing = (try? JSONValue(parsing: existingMetaJSON))?.asObject {
      root = existing
    }
    var translation: JSONObject = [
      "sourceNotebookId": .id(state.sourceNotebookId),
      "targetLanguage": .string(state.targetLanguage),
      "status": .string(state.status.rawValue)
    ]
    translation["error"] = state.errorMessage.map(JSONValue.string)
    root["kaibaTranslation"] = .object(translation)
    do {
      return try JSONValue.object(root).encodedString()
    } catch {
      throw NoteServiceError.invalidInput("translation notebook meta JSON must be UTF-8")
    }
  }

  static func translationNoteMetaJSON(sourceNoteId: NoteID) throws -> String {
    let root: JSONValue = .object(["kaibaTranslation": .object(["sourceNoteId": .id(sourceNoteId)])])
    do {
      return try root.encodedString()
    } catch {
      throw NoteServiceError.invalidInput("translation note meta JSON must be UTF-8")
    }
  }
}

/// Runs a notebook translation against the agent seam. One invocation per
/// source note keeps every prompt bounded; already-translated notes are
/// counted and skipped, so an outbox retry resumes where the failed attempt
/// stopped instead of re-translating (and re-paying for) finished pages.
public struct AITranslationService: Sendable {
  public static let assignedBy = "kaiba-ai-translator"
  /// Per-note cap mirrors the other AI features' context cap.
  static let maximumNoteBytes = 200 * 1024
  static let notePageSize = 100

  public var service: NoteService
  public var invoker: any AgentInvoking
  public var provider: String?
  public var model: String?

  public init(
    service: NoteService,
    invoker: any AgentInvoking,
    provider: String? = nil,
    model: String? = nil
  ) {
    self.service = service
    self.invoker = invoker
    self.provider = provider
    self.model = model
  }

  /// One-shot entry point (the CLI): creates the pending notebook and runs it
  /// to completion.
  public func translateNotebook(
    sourceNotebookId: NotebookID,
    targetLanguage: String,
    title: String? = nil
  ) async throws -> Notebook {
    let pending = try service.startNotebookTranslation(
      sourceNotebookId: sourceNotebookId,
      targetLanguage: targetLanguage,
      title: title
    )
    return try await run(translationNotebookId: pending.notebookId)
  }

  /// Runs (or resumes) the translation for a pending/failed translation
  /// notebook. Completed notebooks return immediately, making dispatch
  /// retries idempotent.
  @discardableResult
  public func run(
    translationNotebookId: NotebookID,
    originatingActionId: AutoActionID? = NoteService.manualTranslationActionId
  ) async throws -> Notebook {
    let notebook = try service.getNotebook(translationNotebookId)
    guard let state = NoteService.translationState(of: notebook) else {
      throw NoteServiceError.invalidInput(
        "notebook is not a translation notebook: \(translationNotebookId)"
      )
    }
    guard state.status != .completed else {
      return notebook
    }
    do {
      let sourceNotes = try allNotes(notebookId: state.sourceNotebookId)
      let alreadyTranslated = try allNotes(notebookId: translationNotebookId).count
      for note in sourceNotes.dropFirst(alreadyTranslated) {
        let translated = try await translate(
          bodyMarkdown: note.bodyMarkdown,
          targetLanguage: state.targetLanguage
        )
        _ = try service.createNote(
          notebookId: translationNotebookId,
          bodyMarkdown: translated,
          provenance: .ai,
          assignedBy: Self.assignedBy,
          metaJSON: try NoteService.translationNoteMetaJSON(sourceNoteId: note.noteId),
          originatingActionId: originatingActionId
        )
      }
      return try service.setNotebookTranslationStatus(
        translationNotebookId,
        status: .completed
      )
    } catch {
      _ = try? service.setNotebookTranslationStatus(
        translationNotebookId,
        status: .failed,
        errorMessage: "\(error)"
      )
      throw error
    }
  }

  // MARK: - Prompt

  static func systemPrompt(targetLanguage: String) -> String {
    """
    You are a professional translator for a note-taking system. Translate the \
    user's markdown document into \(targetLanguage).
    - Preserve the markdown structure exactly: headings, lists, tables, links, \
    images, and code blocks stay where they are.
    - Never translate code blocks, inline code, URLs, or file paths.
    - Keep proper nouns that are conventionally left untranslated.
    - Reply with ONLY the translated markdown document: no preamble, no \
    explanations, no code fence around the document.
    """
  }

  /// Strips a single code fence wrapping the whole reply (a common model
  /// habit) while leaving documents that legitimately contain fences alone.
  static func normalizedReply(_ reply: String) -> String {
    let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
    var lines = trimmed.components(separatedBy: "\n")
    guard lines.count >= 2,
      lines[0].hasPrefix("```"),
      lines[lines.count - 1] == "```"
    else {
      return trimmed
    }
    lines.removeFirst()
    lines.removeLast()
    guard !lines.contains(where: { $0.hasPrefix("```") }) else {
      return trimmed
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Internals

  private func translate(
    bodyMarkdown: String,
    targetLanguage: String
  ) async throws -> String {
    guard !bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return bodyMarkdown
    }
    let request = AgentInvocationRequest(
      purpose: .translation,
      systemPrompt: Self.systemPrompt(targetLanguage: targetLanguage),
      turns: [AgentInvocationTurn(role: .user, markdown: Self.capped(bodyMarkdown))],
      contextMarkdown: nil,
      provider: provider,
      model: model
    )
    let reply = try await invoker.invoke(request)
    let normalized = Self.normalizedReply(reply.markdown)
    guard !normalized.isEmpty else {
      throw AgentInvocationError.failed("translation reply is empty")
    }
    return normalized
  }

  private func allNotes(notebookId: NotebookID) throws -> [Note] {
    var all: [Note] = []
    var offset = 0
    while true {
      let page = try service.listNotes(
        notebookId: notebookId,
        limit: Self.notePageSize,
        offset: offset
      )
      all.append(contentsOf: page)
      if page.count < Self.notePageSize {
        return all
      }
      offset += page.count
    }
  }

  private static func capped(_ markdown: String) -> String {
    guard markdown.utf8.count > maximumNoteBytes else {
      return markdown
    }
    return String(markdown.prefix(maximumNoteBytes))
  }
}
