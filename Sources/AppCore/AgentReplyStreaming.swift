import Foundation

/// Receives incremental agent output while a chat reply is being generated.
/// AppCore publishes through this seam; the serve layer's stream hub
/// implements it and fans chunks out to long-polling web clients, giving the
/// memo pane its streaming chat UX over the single-write HTTP server.
public protocol AgentReplyStreamPublishing: Sendable {
  func publishAgentReplyChunk(turnNoteId: String, text: String)
  /// `status` is the final turn status ("answered" / "failed").
  func finishAgentReplyStream(turnNoteId: String, status: String, message: String?)
}

/// An invoker that can surface the reply incrementally as the agent produces
/// it. `AgentGatewayCLIInvoker` conforms by parsing the ACP JSONL stream's
/// `agent_message_chunk` updates as they arrive on stdout.
public protocol AgentStreamingInvoking: AgentInvoking {
  func invoke(
    _ request: AgentInvocationRequest,
    onChunk: @escaping @Sendable (String) -> Void
  ) async throws -> AgentInvocationResult
}
