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
public struct KaibaAutoActionDispatcher: AutoActionDispatching {
  public var service: NoteService
  public var invoker: any AgentInvoking
  public var provider: String?
  public var model: String?
  /// Translation-only vendor overrides (`ai.translate` in config.json);
  /// nil falls back to the agent defaults above.
  public var translateProvider: String?
  public var translateModel: String?

  public init(
    service: NoteService,
    invoker: any AgentInvoking,
    provider: String? = nil,
    model: String? = nil,
    translateProvider: String? = nil,
    translateModel: String? = nil
  ) {
    self.service = service
    self.invoker = invoker
    self.provider = provider
    self.model = model
    self.translateProvider = translateProvider
    self.translateModel = translateModel
  }

  public func dispatch(
    _ record: AutoActionDispatchRecord
  ) async throws -> AutoActionDispatchOutcome {
    switch record.action.workflowId {
    case NoteStoreSchema.autoTaggingWorkflowId:
      return await dispatchTagExtraction(record)
    case NoteStoreSchema.agentChatReplyWorkflowId:
      return await dispatchChatReply(record)
    case NoteStoreSchema.notebookTranslationWorkflowId:
      return await dispatchTranslation(record)
    default:
      return .failed("unknown auto-action workflow id: \(record.action.workflowId)")
    }
  }

  private func dispatchTagExtraction(
    _ record: AutoActionDispatchRecord
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
      return .failed("tag extraction failed: \(error)")
    }
  }

  private func dispatchTranslation(
    _ record: AutoActionDispatchRecord
  ) async -> AutoActionDispatchOutcome {
    guard let notebookId = record.event.notebookId else {
      return .failed("translation event carries no notebookId")
    }
    let translation = AITranslationService(
      service: service,
      invoker: invoker,
      provider: translateProvider ?? provider,
      model: translateModel ?? model
    )
    do {
      _ = try await translation.run(
        translationNotebookId: notebookId,
        originatingActionId: record.action.actionId
      )
      return .succeeded
    } catch {
      return .failed("notebook translation failed: \(error)")
    }
  }

  private func dispatchChatReply(
    _ record: AutoActionDispatchRecord
  ) async -> AutoActionDispatchOutcome {
    guard let noteId = record.event.noteId else {
      return .failed("chat-reply event carries no noteId")
    }
    do {
      try await service.generateAgentChatReply(
        turnNoteId: noteId,
        invoker: invoker,
        provider: provider,
        model: model,
        originatingActionId: record.action.actionId
      )
      return .succeeded
    } catch {
      return .failed("chat reply failed: \(error)")
    }
  }
}
