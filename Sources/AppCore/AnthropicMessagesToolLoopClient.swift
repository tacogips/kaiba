import Foundation

/// Anthropic Messages API client for the tool loop
/// (`design-docs/specs/user-agent-tools.md`, UA2). Streams `POST
/// /v1/messages` and reassembles text and `tool_use` blocks from SSE events.
struct AnthropicMessagesToolLoopClient: ToolLoopModelClient {
  static let apiVersion = "2023-06-01"
  /// Output budget per round. Models with a smaller output cap reject it
  /// with HTTP 400 naming `max_tokens`; the request is then retried once
  /// with the cap the provider quoted (or `fallbackOutputTokens`), which
  /// keeps the model user-chosen without a per-model table or a setting.
  static let maxOutputTokens = 16_000
  static let fallbackOutputTokens = 4096

  let baseURL: URL
  let apiKey: String
  let streamer: any AgentHTTPStreaming

  func complete(
    _ request: ToolLoopModelRequest,
    onTextDelta: @escaping @Sendable (String) -> Bool
  ) async throws -> ToolLoopModelTurn {
    var maxTokens = Self.maxOutputTokens
    for attempt in 0..<2 {
      let response = try await streamer.stream(AgentHTTPStreamRequest(
        url: Self.messagesURL(baseURL: baseURL),
        headers: [
          "Content-Type": "application/json",
          "Accept": "text/event-stream",
          "x-api-key": apiKey,
          "anthropic-version": Self.apiVersion
        ],
        body: try Self.requestBody(request, maxTokens: maxTokens)
      ))
      guard (200..<300).contains(response.statusCode) else {
        let body = await ToolLoopSSE.collectBody(response.lines)
        let message = ToolLoopSSE.errorMessage(fromBody: body)
        if attempt == 0, response.statusCode == 400,
          let cap = Self.outputTokenCap(fromErrorMessage: message), cap < maxTokens {
          maxTokens = cap
          continue
        }
        throw ToolLoopModelClientError.httpStatus(response.statusCode, message)
      }
      return try await Self.parseStream(response.lines, onTextDelta: onTextDelta)
    }
    throw ToolLoopModelClientError.malformedResponse("max_tokens retry did not produce a response")
  }

  /// The output cap a `max_tokens` rejection names, e.g. `max_tokens: 16000
  /// > 8192, which is the maximum allowed number of output tokens for ...`;
  /// `fallbackOutputTokens` when the message names the parameter but quotes
  /// no usable number; nil when the error is about something else.
  static func outputTokenCap(fromErrorMessage message: String) -> Int? {
    guard message.contains("max_tokens") else {
      return nil
    }
    if let range = message.range(of: #">\s*([0-9]+)"#, options: .regularExpression) {
      let digits = message[range].drop(while: { !$0.isNumber })
      if let cap = Int(digits), cap > 0 {
        return cap
      }
    }
    return fallbackOutputTokens
  }

  /// `POST /v1/messages` under `baseURL`. A custom base that already names
  /// the `/v1` prefix (`https://proxy.example/v1`) is not doubled.
  static func messagesURL(baseURL: URL) -> URL {
    let path = baseURL.path.hasSuffix("/") ? String(baseURL.path.dropLast()) : baseURL.path
    if path.hasSuffix("/v1") {
      return baseURL.appendingPathComponent("messages")
    }
    return baseURL.appendingPathComponent("v1/messages")
  }

  /// Prompt-cache breakpoint. The request is rendered tools, system, then
  /// messages; a breakpoint at the end of the system prompt caches the
  /// tool declarations and instructions for the whole conversation, and one
  /// on the last message lets each tool round reuse the previous round's
  /// prefix instead of re-reading the entire history.
  static let cacheControl: JSONValue = .object(["type": .string("ephemeral")])

  static func requestBody(_ request: ToolLoopModelRequest, maxTokens: Int = maxOutputTokens) throws -> Data {
    let lastIndex = request.messages.indices.last
    var body: JSONObject = [
      "model": .string(request.model),
      "max_tokens": .integer(Int64(maxTokens)),
      "stream": .bool(true),
      "messages": .array(request.messages.enumerated().map { index, message in
        messageJSON(message, cacheBreakpoint: index == lastIndex)
      })
    ]
    if !request.systemPrompt.isEmpty {
      body["system"] = .array([
        .object([
          "type": .string("text"),
          "text": .string(request.systemPrompt),
          "cache_control": cacheControl
        ])
      ])
    }
    if !request.tools.isEmpty {
      body["tools"] = .array(request.tools.map { tool in
        .object([
          "name": .string(tool.name),
          "description": .string(tool.description),
          "input_schema": tool.inputSchema
        ])
      })
    }
    return try JSONValue.object(body).encodedData()
  }

  private static func messageJSON(_ message: ToolLoopMessage, cacheBreakpoint: Bool) -> JSONValue {
    switch message {
    case .user(let text):
      var block: JSONObject = ["type": .string("text"), "text": .string(text)]
      if cacheBreakpoint {
        block["cache_control"] = cacheControl
      }
      return .object(["role": .string("user"), "content": .array([.object(block)])])
    case let .assistant(text, toolCalls):
      var blocks: [JSONValue] = []
      if !text.isEmpty {
        blocks.append(.object(["type": .string("text"), "text": .string(text)]))
      }
      for call in toolCalls {
        blocks.append(.object([
          "type": .string("tool_use"),
          "id": .string(call.id),
          "name": .string(call.name),
          "input": call.input
        ]))
      }
      if blocks.isEmpty {
        // The API rejects empty assistant content; this only happens when a
        // provider returned nothing, which the loop already treats as final.
        blocks.append(.object(["type": .string("text"), "text": .string("(no output)")]))
      }
      return .object(["role": .string("assistant"), "content": .array(withCacheBreakpoint(blocks, cacheBreakpoint))])
    case .toolResults(let results):
      let blocks: [JSONValue] = results.map { result in
        .object([
          "type": .string("tool_result"),
          "tool_use_id": .string(result.callId),
          "content": .string(result.content),
          "is_error": .bool(result.isError)
        ])
      }
      return .object(["role": .string("user"), "content": .array(withCacheBreakpoint(blocks, cacheBreakpoint))])
    }
  }

  private static func withCacheBreakpoint(_ blocks: [JSONValue], _ enabled: Bool) -> [JSONValue] {
    guard enabled, let last = blocks.last, var object = last.asObject else {
      return blocks
    }
    object["cache_control"] = cacheControl
    return blocks.dropLast() + [.object(object)]
  }

  // MARK: - Streaming parse

  private struct PendingToolUse {
    var id: String
    var name: String
    var partialJSON: String
  }

  static func parseStream(
    _ lines: AsyncThrowingStream<String, Error>,
    onTextDelta: @escaping @Sendable (String) -> Bool
  ) async throws -> ToolLoopModelTurn {
    var text = ""
    var toolCalls: [AgentToolCall] = []
    var pending: [Int: PendingToolUse] = [:]
    var stopReason: ToolLoopStopReason?
    for try await line in lines {
      guard let payload = ToolLoopSSE.dataPayload(of: line), !payload.isEmpty else {
        continue
      }
      let event: JSONValue
      do {
        event = try JSONValue(parsing: payload)
      } catch {
        throw ToolLoopModelClientError.malformedResponse("non-JSON event: \(payload.prefix(200))")
      }
      switch event["type"]?.asString {
      case "content_block_start":
        guard let index = event["index"]?.asInt, let block = event["content_block"] else {
          continue
        }
        if block["type"]?.asString == "tool_use",
          let id = block["id"]?.asString, let name = block["name"]?.asString {
          pending[index] = PendingToolUse(id: id, name: name, partialJSON: "")
        } else if block["type"]?.asString == "text", let initial = block["text"]?.asString, !initial.isEmpty {
          text += initial
          guard onTextDelta(initial) else { throw ToolLoopModelClientError.aborted }
        }
      case "content_block_delta":
        guard let index = event["index"]?.asInt, let delta = event["delta"] else {
          continue
        }
        switch delta["type"]?.asString {
        case "text_delta":
          guard let piece = delta["text"]?.asString, !piece.isEmpty else { continue }
          text += piece
          guard onTextDelta(piece) else { throw ToolLoopModelClientError.aborted }
        case "input_json_delta":
          pending[index]?.partialJSON += delta["partial_json"]?.asString ?? ""
        default:
          continue
        }
      case "content_block_stop":
        guard let index = event["index"]?.asInt, let finished = pending.removeValue(forKey: index) else {
          continue
        }
        let raw = finished.partialJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let input: JSONValue
        if raw.isEmpty {
          input = .object([:])
        } else {
          do {
            input = try JSONValue(parsing: raw)
          } catch {
            throw ToolLoopModelClientError.malformedResponse("tool_use input for \(finished.name) is not JSON")
          }
        }
        toolCalls.append(AgentToolCall(id: finished.id, name: finished.name, input: input))
      case "message_delta":
        switch event["delta"]?["stop_reason"]?.asString {
        case "tool_use": stopReason = .toolUse
        case "max_tokens": stopReason = .maxTokens
        case "refusal": stopReason = .refusal
        case "end_turn", "stop_sequence", "pause_turn": stopReason = .endTurn
        default: break
        }
      case "error":
        let message = event["error"]?["message"]?.asString ?? payload
        throw ToolLoopModelClientError.providerError(message)
      default:
        continue
      }
    }
    // A stream may end after tool_use blocks without a stop reason if the
    // provider closed early; tool calls present means the loop must continue.
    let resolvedStop = stopReason ?? (toolCalls.isEmpty ? .endTurn : .toolUse)
    return ToolLoopModelTurn(text: text, toolCalls: toolCalls, stopReason: resolvedStop)
  }
}
