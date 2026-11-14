import Foundation

/// The personal-agent runtime (`design-docs/specs/user-agent-tools.md`, UA3):
/// drives a provider round trip, executes requested tools in-process, feeds
/// the results back, and repeats until the model ends its turn or the round
/// budget is spent. Conforms to the same seams as the gateway adapter so the
/// chat reply path is unchanged.
struct UserAgentToolLoopRunner: AgentStreamingInvoking {
  static let maxTokensMarker = "\n\n> kaiba: the model hit its output limit; the reply above may be incomplete."
  static let roundBudgetMarker = "\n\n> kaiba: the tool round budget was reached before the agent finished."
  static let refusalReply = "The model declined to continue this request."
  static let emptyUserMessage = "(empty message)"
  static let activitySummaryLimit = 160

  /// Provider text deltas are a few tokens each, while the reply relay admits
  /// at most `AgentReplyOutputLimits.maximumChunks` chunks per turn. Deltas
  /// are therefore buffered and released as chunks of at least this many
  /// bytes (the byte budget divided by the chunk budget), so the chunk limit
  /// cannot be reached before the byte limit is.
  static let chunkFlushBytes = AgentReplyOutputLimits.maximumBytes / AgentReplyOutputLimits.maximumChunks
  /// While fewer than this many chunks have been sent, a buffer older than
  /// `promptFlushNanoseconds` is released on the next delta regardless of
  /// size, so short replies still stream word by word.
  static let promptFlushChunkAllowance = AgentReplyOutputLimits.maximumChunks / 4
  static let promptFlushNanoseconds: UInt64 = 500_000_000

  let client: any ToolLoopModelClient
  let tools: any AgentToolExecuting
  let model: String
  let maxToolRounds: Int
  /// Monotonic nanoseconds; injectable so chunk timing is testable.
  let now: @Sendable () -> UInt64

  init(
    client: any ToolLoopModelClient,
    tools: any AgentToolExecuting,
    model: String,
    maxToolRounds: Int,
    now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
  ) {
    self.client = client
    self.tools = tools
    self.model = model
    self.maxToolRounds = max(1, maxToolRounds)
    self.now = now
  }

  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    try await invoke(request) { _ in true }
  }

  func invoke(
    _ request: AgentInvocationRequest,
    onChunk: @escaping @Sendable (String) -> Bool
  ) async throws -> AgentInvocationResult {
    var messages = Self.initialMessages(for: request)
    let definitions = request.allowsTools ? tools.definitions : []
    let systemPrompt = Self.systemPrompt(for: request, toolCount: definitions.count)
    var transcript = ""
    let sink = CoalescingChunkSink(onChunk: onChunk, now: now)
    for round in 1...maxToolRounds {
      let turn: ToolLoopModelTurn
      do {
        turn = try await client.complete(
          ToolLoopModelRequest(
            model: model,
            systemPrompt: systemPrompt,
            messages: messages,
            tools: definitions
          ),
          onTextDelta: { piece in sink.append(piece) }
        )
      } catch ToolLoopModelClientError.aborted {
        throw AgentInvocationError.failed("agent reply exceeded the output budget")
      } catch let error as ToolLoopModelClientError {
        throw AgentInvocationError.failed(error.description)
      }
      transcript += turn.text
      switch turn.stopReason {
      case .refusal:
        if transcript.isEmpty {
          transcript = Self.refusalReply
          try sink.appendOrThrow(Self.refusalReply)
        }
        try sink.flushOrThrow()
        return AgentInvocationResult(markdown: transcript)
      case .maxTokens:
        transcript += Self.maxTokensMarker
        try sink.appendOrThrow(Self.maxTokensMarker)
        try sink.flushOrThrow()
        return AgentInvocationResult(markdown: transcript)
      case .endTurn, .toolUse:
        if turn.toolCalls.isEmpty {
          try sink.flushOrThrow()
          return AgentInvocationResult(markdown: transcript)
        }
      }
      messages.append(.assistant(text: turn.text, toolCalls: turn.toolCalls))
      var results: [AgentToolResult] = []
      for call in turn.toolCalls {
        let result = await tools.execute(call)
        results.append(result)
        let activity = Self.activityLine(for: call, result: result)
        transcript += activity
        try sink.appendOrThrow(activity)
      }
      // Everything the round produced reaches the client before the next
      // provider request, which may take a while to answer.
      try sink.flushOrThrow()
      messages.append(.toolResults(results))
      if round == maxToolRounds {
        transcript += Self.roundBudgetMarker
        try sink.appendOrThrow(Self.roundBudgetMarker)
        try sink.flushOrThrow()
        return AgentInvocationResult(markdown: transcript)
      }
    }
    try sink.flushOrThrow()
    return AgentInvocationResult(markdown: transcript)
  }

  // MARK: - Prompt assembly

  static func systemPrompt(for request: AgentInvocationRequest, toolCount: Int) -> String {
    var parts: [String] = []
    let base = request.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    if !base.isEmpty {
      parts.append(base)
    }
    if toolCount > 0 {
      parts.append(
        """
        You are kaiba's personal agent for the signed-in user. You can act on the user's notes \
        through the provided tools, which run inside the kaiba server under the user's own \
        permissions. Use tools whenever the request needs information you do not already have \
        or asks you to change something. Prefer searching before creating duplicates. Report \
        what you changed, with note or notebook ids, in the final answer. Never invent ids.
        """
      )
    }
    if let context = request.contextMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines), !context.isEmpty {
      parts.append("The conversation is about the following document:\n<document>\n\(context)\n</document>")
    }
    return parts.joined(separator: "\n\n")
  }

  static func initialMessages(for request: AgentInvocationRequest) -> [ToolLoopMessage] {
    var messages: [ToolLoopMessage] = []
    for turn in request.turns {
      switch turn.role {
      case .user:
        messages.append(.user(turn.markdown))
      case .assistant:
        messages.append(.assistant(text: turn.markdown, toolCalls: []))
      }
    }
    // Providers require the conversation to start with a user message and to
    // alternate; a leading assistant turn (a recovered transcript) is folded
    // into the first user message.
    if case .assistant = messages.first {
      messages.insert(.user("(conversation resumed)"), at: 0)
    }
    // Providers reject empty text content; a turn without user text still
    // needs one user message.
    if messages.isEmpty {
      messages.append(.user(Self.emptyUserMessage))
    }
    return messages.map { message in
      if case .user(let text) = message, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return .user(Self.emptyUserMessage)
      }
      return message
    }
  }

  /// The visible trace of one tool call, appended to both the stream and the
  /// persisted reply so both views agree.
  static func activityLine(for call: AgentToolCall, result: AgentToolResult) -> String {
    let summary = (try? call.input.encodedString()) ?? "{}"
    let bounded = summary.count > activitySummaryLimit
      ? String(summary.prefix(activitySummaryLimit)) + "..."
      : summary
    let status: String
    if result.isError {
      let message = result.content.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? "error"
      status = "error: \(message.prefix(activitySummaryLimit))"
    } else {
      status = "ok"
    }
    return "\n\n> tool `\(call.name)` \(bounded) -- \(status)\n\n"
  }
}

/// Buffers streamed text into bounded chunks for the reply relay, serializes
/// emission, and remembers when the consumer refused a chunk so later
/// emissions stop immediately. The concatenation of every emitted chunk is
/// exactly the text appended, so the stream and the persisted reply agree.
private final class CoalescingChunkSink: @unchecked Sendable {
  private let lock = NSLock()
  private let onChunk: @Sendable (String) -> Bool
  private let now: @Sendable () -> UInt64
  private var buffer = ""
  private var bufferedBytes = 0
  private var bufferedSince: UInt64?
  private var emittedChunks = 0
  private var refused = false

  init(onChunk: @escaping @Sendable (String) -> Bool, now: @escaping @Sendable () -> UInt64) {
    self.onChunk = onChunk
    self.now = now
  }

  /// Buffers `text`, emitting a chunk when the buffer is large enough (or,
  /// early in the reply, old enough). Returns false once the consumer has
  /// refused a chunk.
  func append(_ text: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !refused else {
      return false
    }
    if buffer.isEmpty {
      bufferedSince = now()
    }
    buffer += text
    bufferedBytes += text.utf8.count
    guard shouldFlushLocked() else {
      return true
    }
    return flushLocked()
  }

  /// Emits whatever is buffered. Returns false once the consumer has refused.
  func flush() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !refused else {
      return false
    }
    return flushLocked()
  }

  func appendOrThrow(_ text: String) throws {
    guard append(text) else {
      throw AgentInvocationError.failed("agent reply exceeded the output budget")
    }
  }

  func flushOrThrow() throws {
    guard flush() else {
      throw AgentInvocationError.failed("agent reply exceeded the output budget")
    }
  }

  private func shouldFlushLocked() -> Bool {
    if bufferedBytes >= UserAgentToolLoopRunner.chunkFlushBytes {
      return true
    }
    guard emittedChunks < UserAgentToolLoopRunner.promptFlushChunkAllowance,
      let bufferedSince
    else {
      return false
    }
    return now() &- bufferedSince >= UserAgentToolLoopRunner.promptFlushNanoseconds
  }

  private func flushLocked() -> Bool {
    guard !buffer.isEmpty else {
      return true
    }
    let chunk = buffer
    buffer = ""
    bufferedBytes = 0
    bufferedSince = nil
    guard onChunk(chunk) else {
      refused = true
      return false
    }
    emittedChunks += 1
    return true
  }
}
