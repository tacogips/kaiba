import Foundation

/// Routes claimed auto-action dispatches to the AI services
/// (`design-docs/specs/ai-agent-integration.md`, AI4/AI8). Failures return
/// `.failed` so the existing outbox lease/retry machinery (3 attempts) owns
/// recovery; this type adds no retry logic of its own.
///
/// The dispatcher holds its own `NoteService` value (built over the same
/// driver, without a dispatcher installed) for the writes it performs;
/// completion writes carry `originatingActionId`, which suppresses follow-up
/// auto-action enqueueing, so no dispatch loops are possible.
public struct KaibaAutoActionDispatcher: FinalAutoActionReconciliationDispatching {
  private enum PrincipalResolution {
    case service(NoteService)
    case outcome(AutoActionDispatchOutcome)
  }

  public var service: NoteService
  /// The server-configured gateway runtime. Nil when `ai.agent` is absent; a
  /// dispatcher can still exist for personal-agent chats (UA5).
  public var invoker: (any AgentInvoking)?
  public var provider: String?
  public var model: String?
  /// Translation-only vendor overrides (`ai.translate` in config.json);
  /// nil falls back to the agent defaults above.
  public var translateProvider: String?
  public var translateModel: String?
  /// When serving, the stream hub that fans incremental chat-reply chunks out
  /// to long-polling web clients. Nil outside serve (no streaming surface).
  public var streamPublisher: (any AgentReplyStreamPublishing)?
  /// Builds the personal-agent runtime for a chat turn whose principal has an
  /// enabled credential (`design-docs/specs/user-agent-tools.md`, UA5). Nil
  /// disables the feature.
  public var userAgentRuntime: UserAgentRuntimeFactory?

  public init(
    service: NoteService,
    invoker: (any AgentInvoking)?,
    provider: String? = nil,
    model: String? = nil,
    translateProvider: String? = nil,
    translateModel: String? = nil,
    streamPublisher: (any AgentReplyStreamPublishing)? = nil,
    userAgentRuntime: UserAgentRuntimeFactory? = nil
  ) {
    self.service = service
    self.invoker = invoker
    self.provider = provider
    self.model = model
    self.translateProvider = translateProvider
    self.translateModel = translateModel
    self.streamPublisher = streamPublisher
    self.userAgentRuntime = userAgentRuntime
  }

  public func dispatch(
    _ record: AutoActionDispatchRecord
  ) async throws -> AutoActionDispatchOutcome {
    try await dispatchInternal(record, dispatchId: nil, leaseToken: nil)
  }

  func dispatch(
    _ record: AutoActionDispatchRecord,
    dispatchId: AutoActionDispatchID,
    leaseToken: String
  ) async throws -> AutoActionDispatchOutcome {
    return try await dispatchInternal(record, dispatchId: dispatchId, leaseToken: leaseToken)
  }

  func reconcile(
    _ record: AutoActionDispatchRecord,
    dispatchId: AutoActionDispatchID,
    leaseToken: String
  ) async throws -> AutoActionDispatchOutcome {
    // Final reconciliation must never reinterpret an already committed
    // success through the current principal. The account may have been
    // disabled after the provider result was safely stored but before the
    // outbox acknowledgement. In that case this is acknowledgement-only;
    // calling the normal cancellation path would destroy the durable answer.
    if let outcome = try await reconcileDurableTerminalWorkflow(
      record,
      dispatchId: dispatchId,
      leaseToken: leaseToken
    ) {
      return outcome
    }
    return try await dispatchInternal(record, dispatchId: dispatchId, leaseToken: leaseToken)
  }

  /// Reconciles terminal work without resolving the originating principal or
  /// invoking the provider. Chat uses its idempotent answered-turn path so a
  /// recovered stream generation still receives a terminal marker.
  private func reconcileDurableTerminalWorkflow(
    _ record: AutoActionDispatchRecord,
    dispatchId: AutoActionDispatchID,
    leaseToken: String
  ) async throws -> AutoActionDispatchOutcome? {
    let reconciliationService = terminalizationService(
      dispatchId: dispatchId,
      leaseToken: leaseToken
    )
    switch record.action.workflowId {
    case NoteStoreSchema.agentChatReplyWorkflowId:
      guard let turnNoteId = record.event.noteId else { return nil }
      do {
        let turn = try reconciliationService.getNote(turnNoteId)
        guard NoteService.chatTurnState(of: turn)?.status == .answered else {
          return nil
        }
        try await reconciliationService.generateAgentChatReply(
          turnNoteId: turnNoteId,
          invoker: invoker ?? UnavailableAgentInvoker(),
          provider: provider,
          model: model,
          originatingActionId: record.action.actionId,
          streamPublisher: streamPublisher
        )
        return .succeeded
      } catch NoteServiceError.notFound {
        return nil
      }
    case NoteStoreSchema.notebookTranslationWorkflowId:
      guard let notebookId = record.event.notebookId else { return nil }
      do {
        let notebook = try reconciliationService.getNotebook(notebookId)
        return NoteService.translationState(of: notebook)?.status == .completed ? .succeeded : nil
      } catch NoteServiceError.notFound {
        return nil
      }
    default:
      return nil
    }
  }

  private func dispatchInternal(
    _ record: AutoActionDispatchRecord,
    dispatchId: AutoActionDispatchID?,
    leaseToken: String?
  ) async throws -> AutoActionDispatchOutcome {
    guard [
      NoteStoreSchema.autoTaggingWorkflowId,
      NoteStoreSchema.agentChatReplyWorkflowId,
      NoteStoreSchema.notebookTranslationWorkflowId
    ].contains(record.action.workflowId) else {
      return .failed("unknown auto-action workflow id: \(record.action.workflowId)")
    }
    let dispatchService: NoteService
    switch resolveDispatchService(for: record.event) {
    case .service(let service):
      dispatchService = service
    case .outcome(let outcome):
    if case let .cancelled(reason) = outcome {
        do {
          let terminalizationService = terminalizationService(
            dispatchId: dispatchId,
            leaseToken: leaseToken
          )
          if record.action.workflowId == NoteStoreSchema.agentChatReplyWorkflowId,
             let turnNoteId = record.event.noteId,
             let lease = try terminalizationService.activeAgentReplyStreamLease() {
            await streamPublisher?.beginLeasedAgentReplyStream(turnNoteId: turnNoteId, lease: lease)
          }
          try await terminalizeCancelledWorkflow(
            record,
            reason: reason,
            dispatchId: dispatchId,
            leaseToken: leaseToken,
            service: terminalizationService
          )
        } catch {
          return .failed("auto action could not terminalize cancelled work: \(error)")
        }
      }
      return outcome
    }
    let fencedDispatchService: NoteService
    if let dispatchId, let leaseToken {
      fencedDispatchService = dispatchService.scoped(
        toAutoActionDispatch: dispatchId,
        leaseToken: leaseToken
      )
    } else {
      fencedDispatchService = dispatchService
    }
    if record.action.workflowId == NoteStoreSchema.agentChatReplyWorkflowId,
       let turnNoteId = record.event.noteId,
       let lease = try fencedDispatchService.activeAgentReplyStreamLease() {
      await streamPublisher?.beginLeasedAgentReplyStream(turnNoteId: turnNoteId, lease: lease)
    }
    let outcome: AutoActionDispatchOutcome
    switch record.action.workflowId {
    case NoteStoreSchema.autoTaggingWorkflowId:
      outcome = await dispatchTagExtraction(record, service: fencedDispatchService)
    case NoteStoreSchema.agentChatReplyWorkflowId:
      outcome = await dispatchChatReply(record, service: fencedDispatchService)
    case NoteStoreSchema.notebookTranslationWorkflowId:
      outcome = await dispatchTranslation(record, service: fencedDispatchService)
    default:
      outcome = .failed("unreachable auto-action workflow id: \(record.action.workflowId)")
    }
      if case let .cancelled(reason) = outcome {
      do {
        try await terminalizeCancelledWorkflow(
          record,
          reason: reason,
          dispatchId: dispatchId,
          leaseToken: leaseToken,
          service: terminalizationService(dispatchId: dispatchId, leaseToken: leaseToken)
        )
      } catch {
        return .failed("auto action could not terminalize cancelled work: \(error)")
      }
    }
    return outcome
  }

  private func dispatchTagExtraction(
    _ record: AutoActionDispatchRecord,
    service: NoteService
  ) async -> AutoActionDispatchOutcome {
    let subject: AITagExtractionSubject
    if record.event.trigger == .notebookCreated {
      guard let notebookId = record.event.notebookId else {
        return .failed("notebook-created event carries no notebookId")
      }
      subject = .notebook(notebookId)
    } else {
      guard let noteId = record.event.noteId else {
        return .failed("\(record.event.trigger.rawValue) event carries no noteId")
      }
      subject = .note(noteId)
    }
    guard let invoker else {
      return .failed("tag extraction needs the server agent runtime (ai.agent is not configured)")
    }
    let extraction = AITagExtractionService(
      service: service,
      invoker: invoker,
      provider: provider,
      model: model
    )
    do {
      _ = try await extraction.extractTags(subject: subject)
      return .succeeded
    } catch {
      if let cancellation = cancellationOutcome(for: error) {
        return cancellation
      }
      return .failed("tag extraction failed: \(error)")
    }
  }

  private func dispatchTranslation(
    _ record: AutoActionDispatchRecord,
    service: NoteService
  ) async -> AutoActionDispatchOutcome {
    guard let notebookId = record.event.notebookId else {
      return .failed("translation event carries no notebookId")
    }
    do {
      let notebook = try service.getNotebook(notebookId)
      if let state = NoteService.translationState(of: notebook), state.status == .cancelled {
        return .cancelled(state.errorMessage ?? "notebook translation was cancelled")
      }
    } catch {
      return .failed("notebook translation could not load pending state: \(error)")
    }
    guard let invoker else {
      return .failed("translation needs the server agent runtime (ai.agent is not configured)")
    }
    let translation = AITranslationService(
      service: service,
      invoker: invoker,
      provider: translateProvider ?? provider,
      model: translateModel ?? model
    )
    do {
      let result = try await translation.runChunk(
        translationNotebookId: notebookId,
        originatingActionId: record.action.actionId
      )
      switch result {
      case .completed:
        return .succeeded
      case let .pending(_, reconciliationRequired):
        // Ordinary keyset pagination is a durable continuation, so refund the
        // claimed attempt and let maintenance resume it. A source revision
        // change instead starts a new reconciliation round that can invoke the
        // provider again; it must consume the durable retry budget.
        if reconciliationRequired {
          return .failed("translation source set did not converge; reconciliation consumes an auto-action retry")
        }
        return .deferred
      }
    } catch {
      if let cancellation = cancellationOutcome(for: error) {
        return cancellation
      }
      return .failed("notebook translation failed: \(error)")
    }
  }

  private func dispatchChatReply(
    _ record: AutoActionDispatchRecord,
    service: NoteService
  ) async -> AutoActionDispatchOutcome {
    guard let noteId = record.event.noteId else {
      return .failed("chat-reply event carries no noteId")
    }
    do {
      let turn = try service.getNote(noteId)
      if let state = NoteService.chatTurnState(of: turn), state.status == .cancelled {
        return .cancelled(state.errorMessage ?? "agent chat reply was cancelled")
      }
      let selection = try resolveChatRuntime(for: service)
      try await service.generateAgentChatReply(
        turnNoteId: noteId,
        invoker: selection.invoker,
        provider: selection.usesPersonalRuntime ? nil : provider,
        model: selection.usesPersonalRuntime ? nil : model,
        originatingActionId: record.action.actionId,
        streamPublisher: streamPublisher
      )
      return .succeeded
    } catch {
      if let cancellation = cancellationOutcome(for: error) {
        return cancellation
      }
      return .failed("chat reply failed: \(error)")
    }
  }

  /// Whether a chat turn from `service`'s principal can be answered at all:
  /// the gateway is configured, or the user has an enabled personal
  /// credential. Lets the request path mark a turn `unavailable` up front
  /// instead of queueing work that would only fail.
  public func canAnswerChat(for service: NoteService) -> Bool {
    if invoker != nil {
      return true
    }
    guard let userAgentRuntime else {
      return false
    }
    return userAgentRuntime.isAvailable(for: service)
  }

  struct ChatRuntimeSelection {
    var invoker: any AgentInvoking
    var usesPersonalRuntime: Bool
  }

  /// UA5 routing: an authenticated principal with an enabled credential gets
  /// the personal runtime built over the already scoped and fenced service;
  /// everyone else gets the gateway; with neither, the turn fails clearly.
  func resolveChatRuntime(for service: NoteService) throws -> ChatRuntimeSelection {
    if let userAgentRuntime, let personal = try userAgentRuntime.makeInvoker(for: service) {
      return ChatRuntimeSelection(invoker: personal, usesPersonalRuntime: true)
    }
    if let invoker {
      return ChatRuntimeSelection(invoker: invoker, usesPersonalRuntime: false)
    }
    return ChatRuntimeSelection(invoker: UnavailableAgentInvoker(), usesPersonalRuntime: false)
  }

  private func cancellationOutcome(for error: Error) -> AutoActionDispatchOutcome? {
    guard let serviceError = error as? NoteServiceError,
      case .accountUnavailable = serviceError
    else {
      return nil
    }
    return .cancelled("auto-action originating account is unavailable")
  }

  /// Every recovered workflow must retain the request principal that queued
  /// it. An operator dispatcher is intentionally unscoped, so accepting a
  /// legacy row here would let any AI workflow recover broader access after an
  /// upgrade. Disabled accounts are terminal: no provider call or mutation is
  /// safe once the account is unavailable.
  private func resolveDispatchService(for event: NoteAutoActionEvent) -> PrincipalResolution {
    guard let isUnauthenticatedPrincipal = event.originatingIsUnauthenticatedPrincipal else {
      return .outcome(.failed("auto-action event lacks originating principal metadata"))
    }
    if let originatingUserId = event.originatingUserId {
      do {
        guard let user = try service.user(id: originatingUserId), user.disabledAt == nil else {
          return .outcome(.cancelled("auto-action originating account is unavailable"))
        }
      } catch {
        return .outcome(.failed("auto action could not verify originating account: \(error)"))
      }
    }
    return .service(service
      .scoped(to: event.originatingUserId)
      .unauthenticated(isUnauthenticatedPrincipal))
  }

  /// A disabled principal is a permanent stop, not a retryable provider
  /// failure. Chat and translation terminalize their domain state; tag
  /// extraction has no domain state, so it atomically records the leased
  /// outbox cancellation before returning. Both forms survive a lost later
  /// acknowledgement and cannot be retried after account re-enablement.
  private func terminalizeCancelledWorkflow(
    _ record: AutoActionDispatchRecord,
    reason: String,
    dispatchId: AutoActionDispatchID?,
    leaseToken: String?,
    service: NoteService
  ) async throws {
    switch record.action.workflowId {
    case NoteStoreSchema.agentChatReplyWorkflowId:
      guard let turnNoteId = record.event.noteId else {
        throw NoteServiceError.invalidRow("cancelled chat reply carries no turn note id")
      }
      let turn = try service.getNote(turnNoteId)
      let conversation = try service.getNotebook(turn.notebookId)
      guard let libraryId = conversation.libraryId else {
        throw NoteServiceError.invalidRow("cancelled chat reply has no conversation library")
      }
      _ = try service.cancelAgentChatTurn(turnNoteId: turnNoteId, message: reason)
      if let streamPublisher {
        if let lease = try service.activeAgentReplyStreamLease() {
          await service.agentReplyStreamPostLeaseValidationHook?(lease)
          await streamPublisher.finishLeasedAgentReplyStream(
            turnNoteId: turnNoteId,
            status: "cancelled",
            message: reason,
            libraryId: libraryId,
            lease: lease
          )
        } else if !service.requiresActiveAutoActionDispatchLease {
          streamPublisher.finishAgentReplyStream(
            turnNoteId: turnNoteId,
            status: "cancelled",
            message: reason,
            libraryId: libraryId
          )
        }
      }
    case NoteStoreSchema.notebookTranslationWorkflowId:
      guard let notebookId = record.event.notebookId else {
        throw NoteServiceError.invalidRow("cancelled translation carries no notebook id")
      }
      _ = try service.setNotebookTranslationStatus(
        notebookId,
        status: .cancelled,
        errorMessage: reason
      )
    case NoteStoreSchema.autoTaggingWorkflowId:
      guard let dispatchId, let leaseToken else { return }
      try service.markAutoActionDispatchCancelled(
        dispatchId: dispatchId,
        leaseToken: leaseToken,
        reason: reason
      )
    default:
      break
    }
  }

  /// Cancellation is a provider-derived terminal write too. It must use the
  /// active lease even though it intentionally executes as the unscoped local
  /// operator so a disabled originating user can still be terminalized.
  private func terminalizationService(
    dispatchId: AutoActionDispatchID?,
    leaseToken: String?
  ) -> NoteService {
    guard let dispatchId, let leaseToken else { return service }
    return service.scoped(toAutoActionDispatch: dispatchId, leaseToken: leaseToken)
  }
}
