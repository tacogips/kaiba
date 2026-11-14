import Foundation
@testable import AppCore
import XCTest

// MARK: - Fakes

/// Replays scripted provider turns and records every request it saw.
private final class ScriptedModelClient: ToolLoopModelClient, @unchecked Sendable {
  private let lock = NSLock()
  private var script: [ToolLoopModelTurn]
  private(set) var requests: [ToolLoopModelRequest] = []
  /// Characters per text delta; the default delivers a turn's text whole.
  private let deltaSize: Int

  init(_ script: [ToolLoopModelTurn], deltaSize: Int = Int.max) {
    self.script = script
    self.deltaSize = max(1, deltaSize)
  }

  func complete(
    _ request: ToolLoopModelRequest,
    onTextDelta: @escaping @Sendable (String) -> Bool
  ) async throws -> ToolLoopModelTurn {
    let turn: ToolLoopModelTurn = lock.withLock {
      requests.append(request)
      return script.isEmpty ? ToolLoopModelTurn(text: "", toolCalls: [], stopReason: .endTurn) : script.removeFirst()
    }
    var remaining = Substring(turn.text)
    while !remaining.isEmpty {
      let piece = String(remaining.prefix(deltaSize))
      remaining = remaining.dropFirst(piece.count)
      guard onTextDelta(piece) else {
        throw ToolLoopModelClientError.aborted
      }
    }
    return turn
  }
}

private final class RecordingTools: AgentToolExecuting, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var calls: [AgentToolCall] = []
  var results: [String: AgentToolResult] = [:]

  let definitions: [AgentToolDefinition] = [
    AgentToolDefinition(
      name: "search_notes",
      description: "search",
      inputSchema: .object(["type": .string("object"), "properties": .object([:])])
    )
  ]

  func execute(_ call: AgentToolCall) async -> AgentToolResult {
    lock.withLock { calls.append(call) }
    return results[call.id] ?? AgentToolResult(callId: call.id, content: "{\"results\":[]}")
  }
}

private struct ScriptedResponse {
  var status: Int
  var lines: [String]
}

/// Serves canned SSE bodies and records the requests it received.
private final class ScriptedHTTPStreamer: AgentHTTPStreaming, @unchecked Sendable {
  private let lock = NSLock()
  private var responses: [ScriptedResponse]
  private(set) var requests: [AgentHTTPStreamRequest] = []

  init(_ responses: [(Int, [String])]) {
    self.responses = responses.map { ScriptedResponse(status: $0.0, lines: $0.1) }
  }

  func stream(_ request: AgentHTTPStreamRequest) async throws -> AgentHTTPStreamResponse {
    let next: ScriptedResponse = lock.withLock {
      requests.append(request)
      return responses.isEmpty ? ScriptedResponse(status: 200, lines: []) : responses.removeFirst()
    }
    return AgentHTTPStreamResponse(statusCode: next.status, lines: AsyncThrowingStream { continuation in
      for line in next.lines {
        continuation.yield(line)
      }
      continuation.finish()
    })
  }

  func requestBody(at index: Int) throws -> JSONValue {
    try JSONValue(parsing: requests[index].body)
  }
}

private final class ChunkRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var chunks: [String] = []
  var acceptLimit = Int.max

  func accept(_ chunk: String) -> Bool {
    lock.withLock {
      guard chunks.count < acceptLimit else { return false }
      chunks.append(chunk)
      return true
    }
  }

  var joined: String { lock.withLock { chunks.joined() } }
}

private struct AnthropicToolUseFixture {
  var id: String
  var name: String
  var json: String
}

private func anthropicSSE(text: String, toolUse: AnthropicToolUseFixture? = nil, stop: String) -> [String] {
  var lines = [
    "event: message_start",
    #"data: {"type":"message_start","message":{"id":"msg_1"}}"#,
    "",
    #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#
  ]
  for piece in text.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
    let chunk = (piece.offset == 0 ? "" : " ") + piece.element
    let escaped = chunk.replacingOccurrences(of: "\"", with: "\\\"")
    lines.append(#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(escaped)"}}"#)
  }
  lines.append(#"data: {"type":"content_block_stop","index":0}"#)
  if let toolUse {
    let half = toolUse.json.index(toolUse.json.startIndex, offsetBy: toolUse.json.count / 2)
    let first = String(toolUse.json[..<half]).replacingOccurrences(of: "\"", with: "\\\"")
    let second = String(toolUse.json[half...]).replacingOccurrences(of: "\"", with: "\\\"")
    lines += [
      #"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"\#(toolUse.id)","name":"\#(toolUse.name)","input":{}}}"#,
      #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\#(first)"}}"#,
      #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\#(second)"}}"#,
      #"data: {"type":"content_block_stop","index":1}"#
    ]
  }
  lines += [
    #"data: {"type":"message_delta","delta":{"stop_reason":"\#(stop)"},"usage":{"output_tokens":5}}"#,
    #"data: {"type":"message_stop"}"#
  ]
  return lines
}

// MARK: - Runner

final class UserAgentToolLoopRunnerTests: XCTestCase {
  private func request(_ text: String = "Find my plan") -> AgentInvocationRequest {
    AgentInvocationRequest(
      purpose: .chat,
      systemPrompt: "You are helpful.",
      turns: [
        AgentInvocationTurn(role: .user, markdown: "earlier question"),
        AgentInvocationTurn(role: .assistant, markdown: "earlier answer"),
        AgentInvocationTurn(role: .user, markdown: text)
      ],
      contextMarkdown: "# Subject\nDoc body"
    )
  }

  func testExecutesToolsAndFeedsResultsBackUntilEndTurn() async throws {
    let toolCall = AgentToolCall(id: "toolu_1", name: "search_notes", input: .object(["query": .string("plan")]))
    let client = ScriptedModelClient([
      ToolLoopModelTurn(text: "Let me look.", toolCalls: [toolCall], stopReason: .toolUse),
      ToolLoopModelTurn(text: "Found it in note-1.", toolCalls: [], stopReason: .endTurn)
    ])
    let tools = RecordingTools()
    tools.results["toolu_1"] = AgentToolResult(callId: "toolu_1", content: "{\"results\":[{\"note_id\":\"note-1\"}]}")
    let runner = UserAgentToolLoopRunner(client: client, tools: tools, model: "test-model", maxToolRounds: 5)
    let recorder = ChunkRecorder()

    let result = try await runner.invoke(request()) { recorder.accept($0) }

    XCTAssertEqual(tools.calls, [toolCall])
    XCTAssertEqual(client.requests.count, 2)
    XCTAssertEqual(client.requests[0].model, "test-model")
    XCTAssertEqual(client.requests[0].tools.map(\.name), ["search_notes"])
    XCTAssertTrue(client.requests[0].systemPrompt.contains("You are helpful."))
    XCTAssertTrue(client.requests[0].systemPrompt.contains("<document>\n# Subject\nDoc body\n</document>"))
    XCTAssertEqual(client.requests[0].messages, [
      .user("earlier question"),
      .assistant(text: "earlier answer", toolCalls: []),
      .user("Find my plan")
    ])
    XCTAssertEqual(client.requests[1].messages.suffix(2), [
      .assistant(text: "Let me look.", toolCalls: [toolCall]),
      .toolResults([AgentToolResult(callId: "toolu_1", content: "{\"results\":[{\"note_id\":\"note-1\"}]}")])
    ])
    XCTAssertTrue(result.markdown.hasPrefix("Let me look."))
    XCTAssertTrue(result.markdown.contains("> tool `search_notes` {\"query\":\"plan\"} -- ok"))
    XCTAssertTrue(result.markdown.hasSuffix("Found it in note-1."))
    // The stream and the persisted reply are the same text (UA3).
    XCTAssertEqual(recorder.joined, result.markdown)
  }

  func testToolErrorsAreVisibleAndTheLoopContinues() async throws {
    let toolCall = AgentToolCall(id: "c1", name: "search_notes", input: .object([:]))
    let client = ScriptedModelClient([
      ToolLoopModelTurn(text: "", toolCalls: [toolCall], stopReason: .toolUse),
      ToolLoopModelTurn(text: "Sorry, that failed.", toolCalls: [], stopReason: .endTurn)
    ])
    let tools = RecordingTools()
    tools.results["c1"] = AgentToolResult(callId: "c1", content: "invalid tool input: query is required\nmore", isError: true)
    let runner = UserAgentToolLoopRunner(client: client, tools: tools, model: "m", maxToolRounds: 3)
    let result = try await runner.invoke(request())
    XCTAssertTrue(result.markdown.contains("-- error: invalid tool input: query is required"))
    XCTAssertFalse(result.markdown.contains("more"))
    guard case let .toolResults(results)? = client.requests[1].messages.last else {
      return XCTFail("expected tool results to be sent back")
    }
    XCTAssertEqual(results.first?.isError, true)
  }

  func testRoundBudgetStopsARunawayLoop() async throws {
    let toolCall = AgentToolCall(id: "c", name: "search_notes", input: .object([:]))
    let client = ScriptedModelClient(Array(repeating: ToolLoopModelTurn(text: "", toolCalls: [toolCall], stopReason: .toolUse), count: 10))
    let runner = UserAgentToolLoopRunner(client: client, tools: RecordingTools(), model: "m", maxToolRounds: 3)
    let result = try await runner.invoke(request())
    XCTAssertEqual(client.requests.count, 3)
    XCTAssertTrue(result.markdown.hasSuffix(UserAgentToolLoopRunner.roundBudgetMarker))
  }

  func testMaxTokensAndRefusalAreTerminal() async throws {
    let truncated = UserAgentToolLoopRunner(
      client: ScriptedModelClient([ToolLoopModelTurn(text: "partial", toolCalls: [], stopReason: .maxTokens)]),
      tools: RecordingTools(), model: "m", maxToolRounds: 3
    )
    let truncatedResult = try await truncated.invoke(request())
    XCTAssertEqual(truncatedResult.markdown, "partial" + UserAgentToolLoopRunner.maxTokensMarker)

    let refused = UserAgentToolLoopRunner(
      client: ScriptedModelClient([ToolLoopModelTurn(text: "", toolCalls: [], stopReason: .refusal)]),
      tools: RecordingTools(), model: "m", maxToolRounds: 3
    )
    let recorder = ChunkRecorder()
    let refusedResult = try await refused.invoke(request()) { recorder.accept($0) }
    XCTAssertEqual(refusedResult.markdown, UserAgentToolLoopRunner.refusalReply)
    XCTAssertEqual(recorder.joined, UserAgentToolLoopRunner.refusalReply)
  }

  func testChunkBackpressureAbortsTheTurn() async throws {
    let toolCall = AgentToolCall(id: "c", name: "search_notes", input: .object([:]))
    let client = ScriptedModelClient([
      ToolLoopModelTurn(text: "first", toolCalls: [toolCall], stopReason: .toolUse),
      ToolLoopModelTurn(text: "never streamed", toolCalls: [], stopReason: .endTurn)
    ])
    let runner = UserAgentToolLoopRunner(client: client, tools: RecordingTools(), model: "m", maxToolRounds: 3)
    let recorder = ChunkRecorder()
    recorder.acceptLimit = 1
    do {
      _ = try await runner.invoke(request()) { recorder.accept($0) }
      XCTFail("expected the runner to stop when the consumer refuses chunks")
    } catch AgentInvocationError.failed(let message) {
      XCTAssertTrue(message.contains("output budget"))
    }
    // The first round (text plus its activity line) is one chunk; the second
    // round's text was refused and nothing after it was offered.
    XCTAssertEqual(recorder.chunks.count, 1)
    XCTAssertTrue(recorder.chunks[0].hasPrefix("first\n\n> tool `search_notes`"))
    XCTAssertFalse(recorder.joined.contains("never streamed"))
  }

  /// The reply relay admits at most 256 chunks per turn while providers emit
  /// a delta every few tokens, so deltas must be coalesced (UA3).
  func testSmallDeltasAreCoalescedIntoBoundedChunks() async throws {
    let text = String(repeating: "x", count: UserAgentToolLoopRunner.chunkFlushBytes * 3 - 100)
    let client = ScriptedModelClient(
      [ToolLoopModelTurn(text: text, toolCalls: [], stopReason: .endTurn)],
      deltaSize: 1
    )
    // A frozen clock never triggers the prompt flush, so only size does.
    let runner = UserAgentToolLoopRunner(client: client, tools: RecordingTools(), model: "m", maxToolRounds: 3, now: { 0 })
    let recorder = ChunkRecorder()
    let result = try await runner.invoke(request()) { recorder.accept($0) }
    XCTAssertEqual(result.markdown, text)
    XCTAssertEqual(recorder.joined, text)
    XCTAssertEqual(recorder.chunks.count, 3)
    XCTAssertEqual(recorder.chunks[0].utf8.count, UserAgentToolLoopRunner.chunkFlushBytes)
    XCTAssertEqual(recorder.chunks[1].utf8.count, UserAgentToolLoopRunner.chunkFlushBytes)
    XCTAssertLessThan(recorder.chunks[2].utf8.count, UserAgentToolLoopRunner.chunkFlushBytes)
    XCTAssertLessThanOrEqual(recorder.chunks.count, AgentReplyOutputLimits.maximumChunks)
  }

  func testEarlyDeltasFlushPromptlyThenFallBackToSizeBasedChunks() async throws {
    let allowance = UserAgentToolLoopRunner.promptFlushChunkAllowance
    let text = String(repeating: "y", count: allowance + 40)
    let client = ScriptedModelClient(
      [ToolLoopModelTurn(text: text, toolCalls: [], stopReason: .endTurn)],
      deltaSize: 1
    )
    // Every clock read advances past the prompt-flush interval, so each delta
    // is old enough to flush while the allowance lasts.
    let ticks = ChunkRecorder()
    let runner = UserAgentToolLoopRunner(
      client: client, tools: RecordingTools(), model: "m", maxToolRounds: 3,
      now: {
        _ = ticks.accept("t")
        return UInt64(ticks.chunks.count) * UserAgentToolLoopRunner.promptFlushNanoseconds
      }
    )
    let recorder = ChunkRecorder()
    let result = try await runner.invoke(request()) { recorder.accept($0) }
    XCTAssertEqual(result.markdown, text)
    XCTAssertEqual(recorder.joined, text)
    // `allowance` single-character chunks, then the rest held until the end.
    XCTAssertEqual(recorder.chunks.count, allowance + 1)
    XCTAssertTrue(recorder.chunks.prefix(allowance).allSatisfy { $0 == "y" })
    XCTAssertEqual(recorder.chunks.last?.count, 40)
  }

  func testEachRoundReachesTheClientBeforeTheNextProviderRequest() async throws {
    let toolCall = AgentToolCall(id: "c", name: "search_notes", input: .object([:]))
    let client = ScriptedModelClient([
      ToolLoopModelTurn(text: "looking", toolCalls: [toolCall], stopReason: .toolUse),
      ToolLoopModelTurn(text: "done", toolCalls: [], stopReason: .endTurn)
    ])
    let runner = UserAgentToolLoopRunner(client: client, tools: RecordingTools(), model: "m", maxToolRounds: 3, now: { 0 })
    let recorder = ChunkRecorder()
    let result = try await runner.invoke(request()) { recorder.accept($0) }
    XCTAssertEqual(recorder.chunks.count, 2)
    XCTAssertTrue(recorder.chunks[0].hasPrefix("looking\n\n> tool `search_notes` {} -- ok"))
    XCTAssertEqual(recorder.chunks[1], "done")
    XCTAssertEqual(recorder.joined, result.markdown)
  }

  func testProviderFailuresBecomeInvocationFailures() async throws {
    struct FailingClient: ToolLoopModelClient {
      func complete(_ request: ToolLoopModelRequest, onTextDelta: @escaping @Sendable (String) -> Bool) async throws -> ToolLoopModelTurn {
        throw ToolLoopModelClientError.httpStatus(401, "invalid x-api-key")
      }
    }
    let runner = UserAgentToolLoopRunner(client: FailingClient(), tools: RecordingTools(), model: "m", maxToolRounds: 3)
    do {
      _ = try await runner.invoke(request())
      XCTFail("expected failure")
    } catch AgentInvocationError.failed(let message) {
      XCTAssertEqual(message, "provider returned HTTP 401: invalid x-api-key")
    }
  }

  func testEditModeRequestsOfferNoToolsAndNoToolGuidance() async throws {
    let client = ScriptedModelClient([ToolLoopModelTurn(text: "<kaiba-note-body>x</kaiba-note-body>", toolCalls: [], stopReason: .endTurn)])
    let tools = RecordingTools()
    let runner = UserAgentToolLoopRunner(client: client, tools: tools, model: "m", maxToolRounds: 3)
    var edit = request("Fix the typo")
    edit.allowsTools = false
    let result = try await runner.invoke(edit)
    XCTAssertEqual(result.markdown, "<kaiba-note-body>x</kaiba-note-body>")
    let sent = try XCTUnwrap(client.requests.first)
    XCTAssertTrue(sent.tools.isEmpty)
    XCTAssertFalse(sent.systemPrompt.contains("personal agent"))
    XCTAssertTrue(sent.systemPrompt.hasPrefix("You are helpful."))
    XCTAssertTrue(tools.calls.isEmpty)
  }

  func testBlankUserTurnsBecomeAPlaceholderMessage() {
    let blank = AgentInvocationRequest(
      purpose: .chat, systemPrompt: "",
      turns: [AgentInvocationTurn(role: .user, markdown: "  \n")]
    )
    XCTAssertEqual(UserAgentToolLoopRunner.initialMessages(for: blank), [.user(UserAgentToolLoopRunner.emptyUserMessage)])
    let none = AgentInvocationRequest(purpose: .chat, systemPrompt: "", turns: [])
    XCTAssertEqual(UserAgentToolLoopRunner.initialMessages(for: none), [.user(UserAgentToolLoopRunner.emptyUserMessage)])
  }

  func testLeadingAssistantTurnIsFoldedIntoAUserMessage() {
    let messages = UserAgentToolLoopRunner.initialMessages(for: AgentInvocationRequest(
      purpose: .chat, systemPrompt: "", turns: [AgentInvocationTurn(role: .assistant, markdown: "recovered")]
    ))
    XCTAssertEqual(messages, [.user("(conversation resumed)"), .assistant(text: "recovered", toolCalls: [])])
  }
}

// MARK: - Provider clients

final class AnthropicMessagesToolLoopClientTests: XCTestCase {
  private let tool = AgentToolDefinition(
    name: "search_notes", description: "search",
    inputSchema: .object(["type": .string("object"), "properties": .object([:])])
  )

  func testRequestShapeAndStreamingParse() async throws {
    let streamer = ScriptedHTTPStreamer([(200, anthropicSSE(
      text: "Checking notes",
      toolUse: AnthropicToolUseFixture(id: "toolu_9", name: "search_notes", json: #"{"query":"plan","limit":5}"#),
      stop: "tool_use"
    ))])
    let client = AnthropicMessagesToolLoopClient(
      baseURL: URL(string: "https://api.anthropic.com")!, apiKey: "sk-ant-1", streamer: streamer
    )
    let recorder = ChunkRecorder()
    let turn = try await client.complete(ToolLoopModelRequest(
      model: "claude-opus-5",
      systemPrompt: "sys",
      messages: [
        .user("hi"),
        .assistant(text: "prev", toolCalls: [AgentToolCall(id: "t0", name: "search_notes", input: .object([:]))]),
        .toolResults([AgentToolResult(callId: "t0", content: "r", isError: true)]),
        .user("again")
      ],
      tools: [tool]
    )) { recorder.accept($0) }

    let request = try XCTUnwrap(streamer.requests.first)
    XCTAssertEqual(request.url.absoluteString, "https://api.anthropic.com/v1/messages")
    XCTAssertEqual(request.headers["x-api-key"], "sk-ant-1")
    XCTAssertEqual(request.headers["anthropic-version"], "2023-06-01")
    let body = try streamer.requestBody(at: 0)
    XCTAssertEqual(body["model"]?.asString, "claude-opus-5")
    // The system prompt is a text block carrying a prompt-cache breakpoint,
    // so tools plus instructions are cached for the conversation.
    let system = try XCTUnwrap(body["system"]?.asArray?.first)
    XCTAssertEqual(system["text"]?.asString, "sys")
    XCTAssertEqual(system["cache_control"]?["type"]?.asString, "ephemeral")
    XCTAssertEqual(body["stream"]?.asBool, true)
    XCTAssertEqual(body["tools"]?.asArray?.first?["input_schema"]?["type"]?.asString, "object")
    let messages = try XCTUnwrap(body["messages"]?.asArray)
    XCTAssertEqual(messages.count, 4)
    XCTAssertEqual(messages[0]["content"]?.asArray?.first?["text"]?.asString, "hi")
    XCTAssertNil(messages[0]["content"]?.asArray?.first?["cache_control"])
    XCTAssertEqual(messages[1]["content"]?.asArray?.last?["type"]?.asString, "tool_use")
    XCTAssertEqual(messages[2]["content"]?.asArray?.first?["tool_use_id"]?.asString, "t0")
    XCTAssertEqual(messages[2]["content"]?.asArray?.first?["is_error"]?.asBool, true)
    XCTAssertNil(messages[2]["content"]?.asArray?.first?["cache_control"])
    // Only the last message carries the moving breakpoint.
    XCTAssertEqual(messages[3]["content"]?.asArray?.last?["cache_control"]?["type"]?.asString, "ephemeral")

    XCTAssertEqual(turn.text, "Checking notes")
    XCTAssertEqual(recorder.joined, "Checking notes")
    XCTAssertEqual(turn.stopReason, .toolUse)
    XCTAssertEqual(turn.toolCalls, [
      AgentToolCall(id: "toolu_9", name: "search_notes", input: .object(["query": .string("plan"), "limit": .integer(5)]))
    ])
  }

  func testCustomBaseURLWithV1PrefixIsNotDoubledAndToolResultsCarryTheBreakpoint() async throws {
    let streamer = ScriptedHTTPStreamer([(200, anthropicSSE(text: "ok", stop: "end_turn"))])
    let client = AnthropicMessagesToolLoopClient(
      baseURL: URL(string: "https://proxy.example/anthropic/v1")!, apiKey: "k", streamer: streamer
    )
    _ = try await client.complete(ToolLoopModelRequest(
      model: "m", systemPrompt: "",
      messages: [
        .user("hi"),
        .assistant(text: "", toolCalls: [AgentToolCall(id: "t0", name: "search_notes", input: .object([:]))]),
        .toolResults([
          AgentToolResult(callId: "t0", content: "a"),
          AgentToolResult(callId: "t1", content: "b")
        ])
      ],
      tools: []
    )) { _ in true }
    let request = try XCTUnwrap(streamer.requests.first)
    XCTAssertEqual(request.url.absoluteString, "https://proxy.example/anthropic/v1/messages")
    let body = try streamer.requestBody(at: 0)
    XCTAssertNil(body["system"])
    XCTAssertNil(body["tools"])
    let results = try XCTUnwrap(body["messages"]?.asArray?.last?["content"]?.asArray)
    XCTAssertEqual(results.count, 2)
    XCTAssertNil(results[0]["cache_control"])
    XCTAssertEqual(results[1]["cache_control"]?["type"]?.asString, "ephemeral")
    XCTAssertEqual(
      AnthropicMessagesToolLoopClient.messagesURL(baseURL: URL(string: "https://api.anthropic.com/")!).absoluteString,
      "https://api.anthropic.com/v1/messages"
    )
  }

  func testOutputCapRejectionIsRetriedOnceWithTheQuotedCap() async throws {
    let rejection = #"{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens: 16000 > 8192, which is the maximum allowed number of output tokens for claude-3-haiku-20240307"}}"#
    let streamer = ScriptedHTTPStreamer([
      (400, [rejection]),
      (200, anthropicSSE(text: "fits", stop: "end_turn"))
    ])
    let client = AnthropicMessagesToolLoopClient(baseURL: URL(string: "https://api.anthropic.com")!, apiKey: "k", streamer: streamer)
    let turn = try await client.complete(ToolLoopModelRequest(model: "m", systemPrompt: "", messages: [.user("hi")], tools: [])) { _ in true }
    XCTAssertEqual(turn.text, "fits")
    XCTAssertEqual(streamer.requests.count, 2)
    XCTAssertEqual(try streamer.requestBody(at: 0)["max_tokens"]?.asInt, AnthropicMessagesToolLoopClient.maxOutputTokens)
    XCTAssertEqual(try streamer.requestBody(at: 1)["max_tokens"]?.asInt, 8192)

    // A second rejection is reported, not retried again.
    let stubborn = ScriptedHTTPStreamer([(400, [rejection]), (400, [rejection])])
    let failing = AnthropicMessagesToolLoopClient(baseURL: URL(string: "https://api.anthropic.com")!, apiKey: "k", streamer: stubborn)
    do {
      _ = try await failing.complete(ToolLoopModelRequest(model: "m", systemPrompt: "", messages: [.user("hi")], tools: [])) { _ in true }
      XCTFail("expected failure")
    } catch ToolLoopModelClientError.httpStatus(let status, let message) {
      XCTAssertEqual(status, 400)
      XCTAssertTrue(message.hasPrefix("max_tokens: 16000 > 8192"))
    }
    XCTAssertEqual(stubborn.requests.count, 2)

    // Other 400s are not retried; a max_tokens message without a number
    // falls back to the conservative cap.
    XCTAssertNil(AnthropicMessagesToolLoopClient.outputTokenCap(fromErrorMessage: "messages: text content blocks must be non-empty"))
    XCTAssertEqual(
      AnthropicMessagesToolLoopClient.outputTokenCap(fromErrorMessage: "max_tokens is too large for this model"),
      AnthropicMessagesToolLoopClient.fallbackOutputTokens
    )
  }

  func testHTTPErrorsCarryTheProviderMessage() async throws {
    let streamer = ScriptedHTTPStreamer([(401, [#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#])])
    let client = AnthropicMessagesToolLoopClient(baseURL: URL(string: "https://api.anthropic.com")!, apiKey: "bad", streamer: streamer)
    do {
      _ = try await client.complete(ToolLoopModelRequest(model: "m", systemPrompt: "", messages: [.user("hi")], tools: [])) { _ in true }
      XCTFail("expected failure")
    } catch ToolLoopModelClientError.httpStatus(let status, let message) {
      XCTAssertEqual(status, 401)
      XCTAssertEqual(message, "invalid x-api-key")
    }
  }

  func testEndTurnWithoutToolsAndStreamErrorEvents() async throws {
    let plain = ScriptedHTTPStreamer([(200, anthropicSSE(text: "Done", stop: "end_turn"))])
    let client = AnthropicMessagesToolLoopClient(baseURL: URL(string: "https://api.anthropic.com")!, apiKey: "k", streamer: plain)
    let turn = try await client.complete(ToolLoopModelRequest(model: "m", systemPrompt: "", messages: [.user("hi")], tools: [])) { _ in true }
    XCTAssertEqual(turn, ToolLoopModelTurn(text: "Done", toolCalls: [], stopReason: .endTurn))

    let erroring = ScriptedHTTPStreamer([(200, [#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#])])
    let failing = AnthropicMessagesToolLoopClient(baseURL: URL(string: "https://api.anthropic.com")!, apiKey: "k", streamer: erroring)
    do {
      _ = try await failing.complete(ToolLoopModelRequest(model: "m", systemPrompt: "", messages: [.user("hi")], tools: [])) { _ in true }
      XCTFail("expected failure")
    } catch ToolLoopModelClientError.providerError(let message) {
      XCTAssertEqual(message, "Overloaded")
      XCTAssertEqual(ToolLoopModelClientError.providerError(message).description, "provider reported an error: Overloaded")
    }
  }
}

final class OpenAIChatCompletionsToolLoopClientTests: XCTestCase {
  private let tool = AgentToolDefinition(
    name: "search_notes", description: "search",
    inputSchema: .object(["type": .string("object"), "properties": .object([:])])
  )

  func testRequestShapeAndStreamingParse() async throws {
    let streamer = ScriptedHTTPStreamer([(200, [
      #"data: {"id":"c","choices":[{"index":0,"delta":{"role":"assistant","content":"Let me "},"finish_reason":null}]}"#,
      #"data: {"id":"c","choices":[{"index":0,"delta":{"content":"check."},"finish_reason":null}]}"#,
      #"data: {"id":"c","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"search_notes","arguments":""}}]},"finish_reason":null}]}"#,
      #"data: {"id":"c","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"query\":"}}]},"finish_reason":null}]}"#,
      #"data: {"id":"c","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"plan\"}"}}]},"finish_reason":null}]}"#,
      #"data: {"id":"c","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
      "data: [DONE]"
    ])])
    let client = OpenAIChatCompletionsToolLoopClient(
      baseURL: URL(string: "https://openrouter.ai/api/v1")!, apiKey: "or-key", streamer: streamer
    )
    let turn = try await client.complete(ToolLoopModelRequest(
      model: "openai/gpt-5",
      systemPrompt: "sys",
      messages: [
        .user("hi"),
        .assistant(text: "", toolCalls: [AgentToolCall(id: "t0", name: "search_notes", input: .object(["q": .string("x")]))]),
        .toolResults([AgentToolResult(callId: "t0", content: "boom", isError: true)])
      ],
      tools: [tool]
    )) { _ in true }

    let request = try XCTUnwrap(streamer.requests.first)
    XCTAssertEqual(request.url.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
    XCTAssertEqual(request.headers["Authorization"], "Bearer or-key")
    let body = try streamer.requestBody(at: 0)
    let messages = try XCTUnwrap(body["messages"]?.asArray)
    XCTAssertEqual(messages[0]["role"]?.asString, "system")
    XCTAssertEqual(messages[2]["tool_calls"]?.asArray?.first?["function"]?["arguments"]?.asString, "{\"q\":\"x\"}")
    XCTAssertEqual(messages[3]["role"]?.asString, "tool")
    XCTAssertEqual(messages[3]["tool_call_id"]?.asString, "t0")
    XCTAssertEqual(messages[3]["content"]?.asString, "Error: boom")
    XCTAssertEqual(body["tools"]?.asArray?.first?["function"]?["name"]?.asString, "search_notes")

    XCTAssertEqual(turn.text, "Let me check.")
    XCTAssertEqual(turn.stopReason, .toolUse)
    XCTAssertEqual(turn.toolCalls, [AgentToolCall(id: "call_1", name: "search_notes", input: .object(["query": .string("plan")]))])
  }

  func testLengthAndErrorsAreMapped() async throws {
    let streamer = ScriptedHTTPStreamer([
      (200, [#"data: {"choices":[{"index":0,"delta":{"content":"cut"},"finish_reason":"length"}]}"#, "data: [DONE]"]),
      (429, [#"{"error":{"message":"Rate limit exceeded","type":"rate_limit"}}"#])
    ])
    let client = OpenAIChatCompletionsToolLoopClient(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "k", streamer: streamer)
    let turn = try await client.complete(ToolLoopModelRequest(model: "m", systemPrompt: "", messages: [.user("hi")], tools: [])) { _ in true }
    XCTAssertEqual(turn, ToolLoopModelTurn(text: "cut", toolCalls: [], stopReason: .maxTokens))
    do {
      _ = try await client.complete(ToolLoopModelRequest(model: "m", systemPrompt: "", messages: [.user("hi")], tools: [])) { _ in true }
      XCTFail("expected failure")
    } catch ToolLoopModelClientError.httpStatus(let status, let message) {
      XCTAssertEqual(status, 429)
      XCTAssertEqual(message, "Rate limit exceeded")
    }
  }
}

// MARK: - Dispatcher routing

private struct GatewayStubInvoker: AgentInvoking {
  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    AgentInvocationResult(markdown: "gateway reply")
  }
}

final class UserAgentDispatchRoutingTests: NoteTestCase {
  private func pendingTurn(
    in service: NoteService
  ) throws -> (turn: Note, record: AutoActionDispatchRecord) {
    let subject = try service.createNote(bodyMarkdown: "# Subject\nBody.")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "What is in my notes?",
      agentAvailable: true
    )
    let record = AutoActionDispatchRecord(
      action: AutoAction(
        actionId: NoteStoreSchema.agentChatReplyActionId,
        trigger: .noteCreated,
        workflowId: NoteStoreSchema.agentChatReplyWorkflowId,
        createdAt: NoteStoreClock.system.now()
      ),
      event: NoteAutoActionEvent(
        trigger: .noteCreated,
        notebookId: conversation.notebookId,
        noteId: turn.noteId,
        originatingUserId: service.actingUserId,
        originatingIsUnauthenticatedPrincipal: false
      )
    )
    return (turn, record)
  }

  private func assistantReply(_ service: NoteService, turnNoteId: NoteID) throws -> (status: AgentChatTurnStatus?, markdown: String?) {
    let note = try service.getNote(turnNoteId)
    return (NoteService.chatTurnState(of: note)?.status, NoteService.assistantMarkdown(fromTurnBody: note.bodyMarkdown))
  }

  func testUserWithCredentialIsAnsweredByThePersonalRuntimeWithTools() async throws {
    let bare = try makeService()
    let alice = try bare.createUser(email: "alice@example.com", displayName: "Alice")
    let aliceService = bare.scoped(to: alice.userId)
    _ = try aliceService.setUserAgentCredential(UserAgentCredentialInput(
      provider: .anthropic, apiKey: "sk-ant-alice", defaultModel: "claude-opus-5"
    ))
    let plan = try aliceService.createNote(bodyMarkdown: "# Roadmap\nLaunch the personal agent in September.")
    let (turn, record) = try pendingTurn(in: aliceService)

    let streamer = ScriptedHTTPStreamer([
      (200, anthropicSSE(
        text: "Searching.",
        toolUse: AnthropicToolUseFixture(id: "toolu_1", name: "search_notes", json: #"{"query":"personal agent"}"#),
        stop: "tool_use"
      )),
      (200, anthropicSSE(text: "Your roadmap says September.", stop: "end_turn"))
    ])
    let dispatcher = KaibaAutoActionDispatcher(
      service: bare,
      invoker: GatewayStubInvoker(),
      userAgentRuntime: UserAgentRuntimeFactory(configuration: KaibaUserAgentConfiguration(), streamer: streamer)
    )

    let outcome = try await dispatcher.dispatch(record)
    XCTAssertEqual(outcome, .succeeded)
    let reply = try assistantReply(bare, turnNoteId: turn.noteId)
    XCTAssertEqual(reply.status, .answered)
    let markdown = try XCTUnwrap(reply.markdown)
    XCTAssertTrue(markdown.contains("Searching."), markdown)
    XCTAssertTrue(markdown.contains("> tool `search_notes`"), markdown)
    XCTAssertTrue(markdown.hasSuffix("Your roadmap says September."), markdown)
    XCTAssertFalse(markdown.contains("gateway reply"))

    // The user's key went to the provider, and the tool result carried the
    // user's own note back on the second request.
    XCTAssertEqual(streamer.requests.count, 2)
    XCTAssertEqual(streamer.requests[0].headers["x-api-key"], "sk-ant-alice")
    let second = try streamer.requestBody(at: 1)
    XCTAssertEqual(second["model"]?.asString, "claude-opus-5")
    let lastMessage = try XCTUnwrap(second["messages"]?.asArray?.last)
    let toolResult = try XCTUnwrap(lastMessage["content"]?.asArray?.first?["content"]?.asString)
    XCTAssertTrue(toolResult.contains(plan.noteId.rawValue), toolResult)
  }

  func testDisabledCredentialFallsBackToTheGateway() async throws {
    let bare = try makeService()
    let alice = try bare.createUser(email: "alice@example.com", displayName: "Alice")
    let aliceService = bare.scoped(to: alice.userId)
    _ = try aliceService.setUserAgentCredential(UserAgentCredentialInput(
      provider: .openai, apiKey: "sk-openai", defaultModel: "gpt-5", enabled: false
    ))
    let (turn, record) = try pendingTurn(in: aliceService)
    let streamer = ScriptedHTTPStreamer([])
    let dispatcher = KaibaAutoActionDispatcher(
      service: bare,
      invoker: GatewayStubInvoker(),
      userAgentRuntime: UserAgentRuntimeFactory(configuration: KaibaUserAgentConfiguration(), streamer: streamer)
    )
    let outcome = try await dispatcher.dispatch(record)
    XCTAssertEqual(outcome, .succeeded)
    XCTAssertEqual(try assistantReply(bare, turnNoteId: turn.noteId).markdown, "gateway reply")
    XCTAssertTrue(streamer.requests.isEmpty)
  }

  func testFeatureDisabledIgnoresCredentials() async throws {
    let bare = try makeService()
    let alice = try bare.createUser(email: "alice@example.com", displayName: "Alice")
    let aliceService = bare.scoped(to: alice.userId)
    _ = try aliceService.setUserAgentCredential(UserAgentCredentialInput(
      provider: .anthropic, apiKey: "sk-ant-alice", defaultModel: "claude-opus-5"
    ))
    let (turn, record) = try pendingTurn(in: aliceService)
    let streamer = ScriptedHTTPStreamer([])
    let dispatcher = KaibaAutoActionDispatcher(
      service: bare,
      invoker: GatewayStubInvoker(),
      userAgentRuntime: UserAgentRuntimeFactory(configuration: KaibaUserAgentConfiguration(enabled: false), streamer: streamer)
    )
    let outcome = try await dispatcher.dispatch(record)
    XCTAssertEqual(outcome, .succeeded)
    XCTAssertEqual(try assistantReply(bare, turnNoteId: turn.noteId).markdown, "gateway reply")
    XCTAssertTrue(streamer.requests.isEmpty)
  }

  func testNoRuntimeAtAllFailsTheTurnWithAClearMessage() async throws {
    let bare = try makeService()
    let alice = try bare.createUser(email: "alice@example.com", displayName: "Alice")
    let (turn, record) = try pendingTurn(in: bare.scoped(to: alice.userId))
    let dispatcher = KaibaAutoActionDispatcher(
      service: bare,
      invoker: nil,
      userAgentRuntime: UserAgentRuntimeFactory(configuration: KaibaUserAgentConfiguration(), streamer: ScriptedHTTPStreamer([]))
    )
    let outcome = try await dispatcher.dispatch(record)
    guard case .failed(let message) = outcome else {
      return XCTFail("expected failure, got \(outcome)")
    }
    XCTAssertTrue(message.contains("no agent runtime"), message)
    let state = NoteService.chatTurnState(of: try bare.getNote(turn.noteId))
    XCTAssertEqual(state?.status, .failed)
  }

  func testTaggingWithoutGatewayFailsInsteadOfUsingAUserKey() async throws {
    let bare = try makeService()
    let dispatcher = KaibaAutoActionDispatcher(
      service: bare,
      invoker: nil,
      userAgentRuntime: UserAgentRuntimeFactory(configuration: KaibaUserAgentConfiguration(), streamer: ScriptedHTTPStreamer([]))
    )
    let note = try bare.createNote(bodyMarkdown: "# Note\nBody.")
    let outcome = try await dispatcher.dispatch(AutoActionDispatchRecord(
      action: AutoAction(
        actionId: AutoActionID("tagging"),
        trigger: .noteCreated,
        workflowId: NoteStoreSchema.autoTaggingWorkflowId,
        createdAt: NoteStoreClock.system.now()
      ),
      event: NoteAutoActionEvent(
        trigger: .noteCreated, notebookId: note.notebookId, noteId: note.noteId,
        originatingUserId: nil, originatingIsUnauthenticatedPrincipal: false
      )
    ))
    guard case .failed(let message) = outcome else {
      return XCTFail("expected failure, got \(outcome)")
    }
    XCTAssertTrue(message.contains("server agent runtime"), message)
  }
}
