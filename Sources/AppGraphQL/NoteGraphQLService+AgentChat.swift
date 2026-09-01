import Foundation

import AppCore

/// Small, service-owned cache for expensive gateway model discovery.  The
/// in-flight task is deliberately shared so a burst of clients cannot fan out
/// into one subprocess per request.  A short TTL still lets configuration
/// changes become visible without a restart.
public actor AgentModelCatalogCache {
  private let lifetime: TimeInterval
  private var cached: (catalog: AgentGatewayModelCatalogResult, expiresAt: Date)?
  private var inFlight: Task<AgentGatewayModelCatalogResult, Error>?

  public init(lifetime: TimeInterval = 30) {
    self.lifetime = lifetime
  }

  public func catalog(
    principalId: String,
    admission: AgentExecutionAdmission,
    loading loader: @escaping @Sendable () async throws -> AgentGatewayModelCatalogResult
  ) async throws -> AgentGatewayModelCatalogResult {
    if let cached, cached.expiresAt > Date() {
      return cached.catalog
    }
    if let inFlight {
      return try await inFlight.value
    }
    guard let lease = admission.acquire(principalId: principalId) else {
      throw AgentExecutionAdmissionError.overloaded
    }
    let task = Task {
      defer { admission.release(lease) }
      return try await loader()
    }
    inFlight = task
    do {
      let catalog = try await task.value
      cached = (catalog, Date().addingTimeInterval(lifetime))
      inFlight = nil
      return catalog
    } catch {
      inFlight = nil
      throw error
    }
  }
}

/// Agent-chat GraphQL operations are kept apart from the general note service
/// so model discovery, untrusted attachment decoding, and turn creation stay
/// cohesive and independently testable.
public extension GraphQLNoteGraphQLService {
  /// Authenticated callers receive models for the configured provider.
  /// Discovery failure is non-fatal: the configured model remains the
  /// server-authoritative fallback and the status reports the degradation.
  func agentModels() async -> GraphQLAgentModelsResult {
    // A user with an enabled personal credential chats through their own
    // provider, so their default model is the configured model for them
    // (`design-docs/specs/user-agent-tools.md`, UA5). No discovery runs.
    if let personal = personalAgentModel() {
      return GraphQLAgentModelsResult(
        result: GraphQLControlPlaneResult(accepted: true, status: "ok"),
        models: [GraphQLAgentModelDTO(modelId: personal)],
        discoveryAvailable: false, configuredModel: personal
      )
    }
    let configured = agentModel?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let configured, !configured.isEmpty else {
      return GraphQLAgentModelsResult(
        result: GraphQLControlPlaneResult(accepted: true, status: "agent-unavailable"),
        models: [], discoveryAvailable: false, configuredModel: nil
      )
    }
    guard let agentModelCatalog else {
      return GraphQLAgentModelsResult(
        result: GraphQLControlPlaneResult(accepted: true, status: "fallback"),
        models: [GraphQLAgentModelDTO(modelId: configured)],
        discoveryAvailable: false, configuredModel: configured
      )
    }
    do {
      let catalog = try await agentModelCatalogCache.catalog(
        principalId: service.agentExecutionPrincipalId(),
        admission: service.agentExecutionAdmission,
        loading: agentModelCatalog
      )
      var models = catalog.models.map(GraphQLAgentModelDTO.init)
      if !models.contains(where: { $0.modelId == configured }) {
        models.insert(GraphQLAgentModelDTO(modelId: configured), at: 0)
      }
      return GraphQLAgentModelsResult(
        result: GraphQLControlPlaneResult(accepted: true, status: "ok"),
        models: models, discoveryAvailable: true, configuredModel: configured
      )
    } catch AgentExecutionAdmissionError.overloaded {
      return GraphQLAgentModelsResult(
        result: GraphQLControlPlaneResult(accepted: false, status: "overloaded"),
        models: [GraphQLAgentModelDTO(modelId: configured)],
        discoveryAvailable: false, configuredModel: configured
      )
    } catch {
      return GraphQLAgentModelsResult(
        result: GraphQLControlPlaneResult(accepted: true, status: "fallback"),
        models: [GraphQLAgentModelDTO(modelId: configured)],
        discoveryAvailable: false, configuredModel: configured
      )
    }
  }

  func sendAgentChatMessage(
    _ input: GraphQLSendAgentChatMessageInput
  ) async -> GraphQLAgentChatMessageResult {
    do {
      // An authorized idempotent replay is a persisted response; it must not
      // validate new payload material or spawn model-discovery work first.
      if let conversationNotebookId = input.conversationNotebookId,
        let idempotencyKey = input.idempotencyKey,
        let replay = try service.existingAgentChatTurn(
          conversationNotebookId: conversationNotebookId,
          idempotencyKey: idempotencyKey
        ) {
        return GraphQLAgentChatMessageResult(
          result: GraphQLControlPlaneResult(accepted: true, status: "ok"),
          conversationNotebookId: conversationNotebookId,
          turnNoteId: replay.noteId,
          agentStatus: agentStatus(for: replay)
        )
      }
      let attachments = try validatedAgentChatAttachments(input.attachments ?? [])
      let selectedModel = try await selectedAgentChatModel(input.model)
      let mode = try agentChatTurnMode(input.mode)
      let conversationNotebookId = try conversationNotebookId(for: input, mode: mode)
      let turn = try service.appendPendingAgentChatTurn(
        conversationNotebookId: conversationNotebookId,
        userMarkdown: input.userMarkdown,
        agentAvailable: chatAgentAvailable(),
        idempotencyKey: input.idempotencyKey,
        model: selectedModel,
        mode: mode,
        attachments: attachments
      )
      return GraphQLAgentChatMessageResult(
        result: GraphQLControlPlaneResult(accepted: true, status: "ok"),
        conversationNotebookId: conversationNotebookId,
        turnNoteId: turn.noteId,
        agentStatus: agentStatus(for: turn)
      )
    } catch {
      return GraphQLAgentChatMessageResult(
        result: graphQLNoteResult(for: error),
        agentStatus: "error"
      )
    }
  }

  private func selectedAgentChatModel(_ input: String?) async throws -> String? {
    let catalog = await agentModels()
    guard let requested = input?.trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty else {
      return catalog.configuredModel
    }
    guard catalog.models.contains(where: { $0.modelId == requested }) else {
      throw GraphQLNoteServiceError.invalidRequest("unsupported agent model")
    }
    return requested
  }

  /// Normalizes to nil for the default so turns without a stored mode and memo
  /// turns persist identical metadata; the writability of an edit turn's
  /// subject is enforced by `appendPendingAgentChatTurn`.
  private func agentChatTurnMode(_ input: String?) throws -> AgentChatTurnMode? {
    guard let raw = input?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return nil
    }
    guard let mode = AgentChatTurnMode(rawValue: raw) else {
      throw GraphQLNoteServiceError.invalidRequest("unsupported agent chat mode")
    }
    return mode == .memo ? nil : mode
  }

  private func conversationNotebookId(
    for input: GraphQLSendAgentChatMessageInput,
    mode: AgentChatTurnMode?
  ) throws -> NotebookID {
    if let existing = input.conversationNotebookId {
      guard let existingSubject = try service.chatSubject(notebookId: existing) else {
        throw GraphQLNoteServiceError.invalidRequest(
          "notebook is not an agent chat conversation: \(existing)"
        )
      }
      let requestedSubject = try requestedAgentChatSubject(input)
      guard requestedSubject == nil || requestedSubject == existingSubject else {
        throw GraphQLNoteServiceError.invalidRequest("conversation does not belong to the requested subject")
      }
      try validateEditModeSubject(mode, subject: existingSubject)
      return existing
    }
    guard let subject = try requestedAgentChatSubject(input) else {
      throw GraphQLNoteServiceError.invalidRequest(
        "subjectNoteId or subjectNotebookId is required to start a conversation"
      )
    }
    try validateEditModeSubject(mode, subject: subject)
    switch subject {
    case let .note(noteId):
      return try service.startAgentConversation(subjectNoteId: noteId).notebookId
    case let .notebook(notebookId):
      return try service.startAgentConversation(subjectNotebookId: notebookId).notebookId
    }
  }

  /// Pre-checks an edit-mode subject so a rejected request never leaves an
  /// orphan conversation notebook behind (the attachment validators keep the
  /// same ordering guarantee). `appendPendingAgentChatTurn` re-enforces this
  /// authoritatively inside its transaction.
  private func validateEditModeSubject(
    _ mode: AgentChatTurnMode?,
    subject: AgentChatSubject?
  ) throws {
    guard mode == .edit else {
      return
    }
    guard case let .note(noteId)? = subject else {
      throw GraphQLNoteServiceError.invalidRequest("note edit mode requires a note subject")
    }
    let note = try service.getNote(noteId)
    let notebook = try service.getNotebook(note.notebookId)
    guard !note.readOnly, !notebook.readOnly else {
      throw NoteServiceError.readOnly(noteId.rawValue)
    }
  }

  private func requestedAgentChatSubject(
    _ input: GraphQLSendAgentChatMessageInput
  ) throws -> AgentChatSubject? {
    switch (input.subjectNoteId, input.subjectNotebookId) {
    case (let noteId?, nil): return .note(noteId)
    case (nil, let notebookId?): return .notebook(notebookId)
    case (nil, nil): return nil
    case (_?, _?):
      throw GraphQLNoteServiceError.invalidRequest(
        "provide subjectNoteId or subjectNotebookId, not both"
      )
    }
  }

  private func agentStatus(for turn: Note) -> String {
    switch NoteService.chatTurnState(of: turn)?.status ?? .pending {
    case .pending: return "pending"
    case .unavailable: return "agent-unavailable"
    case .answered: return "answered"
    case .failed: return "failed"
    case .cancelled: return "cancelled"
    }
  }

  private func validatedAgentChatAttachments(
    _ inputs: [GraphQLAgentChatAttachmentInput]
  ) throws -> [AgentChatAttachment] {
    guard inputs.count <= AgentChatAttachmentValidation.maximumFiles else {
      throw GraphQLNoteServiceError.invalidRequest("at most four chat attachments are allowed")
    }
    let attachments = try inputs.map { input -> AgentChatAttachment in
      guard input.contentBase64.utf8.count <= ((AgentChatAttachmentValidation.maximumAggregateBytes + 2) / 3) * 4,
        let data = Data(base64Encoded: input.contentBase64, options: []),
        data.base64EncodedString() == input.contentBase64
      else {
        throw GraphQLNoteServiceError.invalidRequest("invalid or oversized chat attachment encoding")
      }
      return try AgentChatAttachmentValidation.validate(
        data: data,
        declaredMediaType: normalizedAgentChatAttachmentMediaType(
          declared: input.mediaType,
          filename: input.originalFilename
        ),
        originalFilename: input.originalFilename
      )
    }
    try AgentChatAttachmentValidation.validate(attachments)
    return attachments
  }

  private func normalizedAgentChatAttachmentMediaType(
    declared: String,
    filename: String
  ) -> String {
    let mediaType = declared.split(separator: ";", maxSplits: 1).first
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
    guard ["", "application/octet-stream", "binary/octet-stream"].contains(mediaType) else {
      return mediaType
    }
    let extensionName = filename.split(separator: ".").last?.lowercased()
    return [
      "txt": "text/plain", "md": "text/markdown", "csv": "text/csv",
      "tsv": "text/tab-separated-values", "json": "application/json",
      "xml": "application/xml", "yaml": "application/yaml", "yml": "application/x-yaml"
    ][extensionName ?? ""] ?? mediaType
  }
}

// MARK: - Personal agent credential (design-docs/specs/user-agent-tools.md, UA7)

public extension GraphQLNoteGraphQLService {
  func userAgentCredential() async -> GraphQLUserAgentCredentialResult {
    guard userAgentConfiguration.isEnabled else {
      return userAgentCredentialResult(status: "feature-disabled", accepted: true, credential: nil)
    }
    do {
      let summary = try service.userAgentCredentialSummary()
      return userAgentCredentialResult(status: "ok", accepted: true, credential: summary)
    } catch {
      return GraphQLUserAgentCredentialResult(
        result: graphQLNoteResult(for: error),
        featureEnabled: true,
        customBaseURLAllowed: userAgentConfiguration.customBaseURLAllowed
      )
    }
  }

  func setUserAgentCredential(_ input: GraphQLSetUserAgentCredentialInput) async -> GraphQLUserAgentCredentialResult {
    guard userAgentConfiguration.isEnabled else {
      return userAgentCredentialResult(status: "feature-disabled", accepted: false, credential: nil)
    }
    guard let provider = UserAgentProvider(rawValue: input.provider.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      return GraphQLUserAgentCredentialResult(
        result: GraphQLControlPlaneResult(
          accepted: false,
          status: "invalid_request",
          diagnostics: ["provider must be one of \(UserAgentProvider.allCases.map(\.rawValue).joined(separator: ", "))"]
        ),
        featureEnabled: true,
        customBaseURLAllowed: userAgentConfiguration.customBaseURLAllowed
      )
    }
    do {
      let summary = try service.setUserAgentCredential(
        UserAgentCredentialInput(
          provider: provider,
          apiKey: input.apiKey,
          defaultModel: input.defaultModel,
          baseURL: input.baseURL,
          enabled: input.enabled ?? true
        ),
        customBaseURLAllowed: userAgentConfiguration.customBaseURLAllowed
      )
      return userAgentCredentialResult(status: "ok", accepted: true, credential: summary)
    } catch {
      return GraphQLUserAgentCredentialResult(
        result: graphQLNoteResult(for: error),
        featureEnabled: true,
        customBaseURLAllowed: userAgentConfiguration.customBaseURLAllowed
      )
    }
  }

  func setUserAgentCredentialEnabled(_ enabled: Bool) async -> GraphQLUserAgentCredentialResult {
    guard userAgentConfiguration.isEnabled else {
      return userAgentCredentialResult(status: "feature-disabled", accepted: false, credential: nil)
    }
    do {
      guard let summary = try service.setUserAgentCredentialEnabled(enabled) else {
        return userAgentCredentialResult(status: "not_found", accepted: false, credential: nil)
      }
      return userAgentCredentialResult(status: "ok", accepted: true, credential: summary)
    } catch {
      return GraphQLUserAgentCredentialResult(
        result: graphQLNoteResult(for: error),
        featureEnabled: true,
        customBaseURLAllowed: userAgentConfiguration.customBaseURLAllowed
      )
    }
  }

  func clearUserAgentCredential() async -> GraphQLUserAgentCredentialResult {
    guard userAgentConfiguration.isEnabled else {
      return userAgentCredentialResult(status: "feature-disabled", accepted: false, credential: nil)
    }
    do {
      _ = try service.clearUserAgentCredential()
      return userAgentCredentialResult(status: "ok", accepted: true, credential: nil)
    } catch {
      return GraphQLUserAgentCredentialResult(
        result: graphQLNoteResult(for: error),
        featureEnabled: true,
        customBaseURLAllowed: userAgentConfiguration.customBaseURLAllowed
      )
    }
  }

  /// A turn is `pending` only when some runtime can answer it. The production
  /// dispatcher knows both runtimes; any other dispatcher (tests, embedders)
  /// is trusted to answer.
  internal func chatAgentAvailable() -> Bool {
    guard let dispatcher = service.autoActionDispatcher else {
      return false
    }
    guard let production = dispatcher as? KaibaAutoActionDispatcher else {
      return true
    }
    return production.canAnswerChat(for: service)
  }

  /// The acting user's personal-agent model when they chat through their own
  /// credential; nil otherwise (including when the feature is off).
  internal func personalAgentModel() -> String? {
    guard userAgentConfiguration.isEnabled,
      service.actingUserId != nil,
      !service.isUnauthenticatedPrincipal,
      let summary = try? service.userAgentCredentialSummary(),
      summary.enabled
    else {
      return nil
    }
    return summary.defaultModel
  }

  private func userAgentCredentialResult(
    status: String,
    accepted: Bool,
    credential: UserAgentCredentialSummary?
  ) -> GraphQLUserAgentCredentialResult {
    GraphQLUserAgentCredentialResult(
      result: GraphQLControlPlaneResult(accepted: accepted, status: status),
      featureEnabled: userAgentConfiguration.isEnabled,
      customBaseURLAllowed: userAgentConfiguration.customBaseURLAllowed,
      credential: credential
    )
  }
}
