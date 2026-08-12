import Foundation

/// Reconciles the AI auto-actions with configuration at serve startup
/// (`design-docs/specs/ai-agent-integration.md`, AI4). `seedAutoActions` only
/// runs on fresh stores, so the idempotent `configureAutoAction` upsert is the
/// mechanism that keeps existing stores in sync with `config.json`.
public enum AIAutoActionReconciliation {
  public static let taggingActions: [(actionId: String, trigger: NoteAutoActionTrigger)] = [
    ("default-ai-tagging-note-created", .noteCreated),
    ("default-ai-tagging-note-updated", .noteUpdated),
    ("default-ai-tagging-notebook-created", .notebookCreated)
  ]

  public static let chatReplyFilterJSON =
    "{\"notebookKindTag\":\"\(NoteStoreSchema.agentConversationNotebookKindTag)\"}"

  /// Returns human-readable log lines describing what was reconciled.
  @discardableResult
  public static func reconcile(
    service: NoteService,
    aiConfiguration: KaibaAIConfiguration?,
    invokerAvailable: Bool
  ) throws -> [String] {
    var lines: [String] = []
    let tagging = invokerAvailable && (aiConfiguration?.autoTagEnabled ?? false)
    for action in taggingActions {
      _ = try service.configureAutoAction(
        actionId: action.actionId,
        trigger: action.trigger,
        workflowId: NoteStoreSchema.autoTaggingWorkflowId,
        filterJSON: nil,
        enabled: tagging
      )
    }
    lines.append("autoTag=\(tagging ? "on" : "off")")
    let chat = invokerAvailable
    _ = try service.configureAutoAction(
      actionId: NoteStoreSchema.agentChatReplyActionId,
      trigger: .noteCreated,
      workflowId: NoteStoreSchema.agentChatReplyWorkflowId,
      filterJSON: chatReplyFilterJSON,
      enabled: chat
    )
    lines.append("agentChatReplies=\(chat ? "on" : "off")")
    if !invokerAvailable, aiConfiguration != nil {
      lines.append(AgentInvokerFactory.describeAvailability(configuration: aiConfiguration))
    }
    return lines
  }
}
