import Foundation

/// OpenAI Chat Completions client for the tool loop, also used for OpenRouter
/// and any `openai-compatible` endpoint (`design-docs/specs/user-agent-tools.md`,
/// UA2). Streams `POST {base}/chat/completions` and reassembles text and
/// `tool_calls` from the delta chunks.
struct OpenAIChatCompletionsToolLoopClient: ToolLoopModelClient {
  let baseURL: URL
  let apiKey: String
  let streamer: any AgentHTTPStreaming

  func complete(
    _ request: ToolLoopModelRequest,
    onTextDelta: @escaping @Sendable (String) -> Bool
  ) async throws -> ToolLoopModelTurn {
    let response = try await streamer.stream(AgentHTTPStreamRequest(
      url: baseURL.appendingPathComponent("chat/completions"),
      headers: [
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
        "Authorization": "Bearer \(apiKey)"
      ],
      body: try Self.requestBody(request)
    ))
    guard (200..<300).contains(response.statusCode) else {
      let body = await ToolLoopSSE.collectBody(response.lines)
      throw ToolLoopModelClientError.httpStatus(
        response.statusCode,
        ToolLoopSSE.errorMessage(fromBody: body)
      )
    }
    return try await Self.parseStream(response.lines, onTextDelta: onTextDelta)
  }

  static func requestBody(_ request: ToolLoopModelRequest) throws -> Data {
    var messages: [JSONValue] = []
    if !request.systemPrompt.isEmpty {
      messages.append(.object(["role": .string("system"), "content": .string(request.systemPrompt)]))
    }
    for message in request.messages {
      messages.append(contentsOf: try messageJSON(message))
    }
    var body: JSONObject = [
      "model": .string(request.model),
      "stream": .bool(true),
      "messages": .array(messages)
    ]
    if !request.tools.isEmpty {
      body["tools"] = .array(request.tools.map { tool in
        .object([
          "type": .string("function"),
          "function": .object([
            "name": .string(tool.name),
            "description": .string(tool.description),
            "parameters": tool.inputSchema
          ])
        ])
      })
    }
    return try JSONValue.object(body).encodedData()
  }

  private static func messageJSON(_ message: ToolLoopMessage) throws -> [JSONValue] {
    switch message {
    case .user(let text):
      return [.object(["role": .string("user"), "content": .string(text)])]
    case let .assistant(text, toolCalls):
      var object: JSONObject = ["role": .string("assistant")]
      object["content"] = text.isEmpty ? .null : .string(text)
      if !toolCalls.isEmpty {
        object["tool_calls"] = .array(try toolCalls.map { call in
          .object([
            "id": .string(call.id),
            "type": .string("function"),
            "function": .object([
              "name": .string(call.name),
              "arguments": .string(try call.input.encodedString())
            ])
          ])
        })
      }
      return [.object(object)]
    case .toolResults(let results):
      return results.map { result in
        .object([
          "role": .string("tool"),
          "tool_call_id": .string(result.callId),
          "content": .string(result.isError ? "Error: \(result.content)" : result.content)
        ])
      }
    }
  }

  // MARK: - Streaming parse

  private struct PendingToolCall {
    var id: String
    var name: String
    var arguments: String
  }

  static func parseStream(
    _ lines: AsyncThrowingStream<String, Error>,
    onTextDelta: @escaping @Sendable (String) -> Bool
  ) async throws -> ToolLoopModelTurn {
    var text = ""
    var pending: [Int: PendingToolCall] = [:]
    var finishReason: String?
    for try await line in lines {
      guard let payload = ToolLoopSSE.dataPayload(of: line), !payload.isEmpty else {
        continue
      }
      if payload == "[DONE]" {
        break
      }
      let chunk: JSONValue
      do {
        chunk = try JSONValue(parsing: payload)
      } catch {
        throw ToolLoopModelClientError.malformedResponse("non-JSON chunk: \(payload.prefix(200))")
      }
      if let error = chunk["error"] {
        throw ToolLoopModelClientError.providerError(error["message"]?.asString ?? payload)
      }
      guard let choice = chunk["choices"]?.asArray?.first else {
        continue
      }
      if let reason = choice["finish_reason"]?.asString {
        finishReason = reason
      }
      guard let delta = choice["delta"] else {
        continue
      }
      if let piece = delta["content"]?.asString, !piece.isEmpty {
        text += piece
        guard onTextDelta(piece) else { throw ToolLoopModelClientError.aborted }
      }
      for call in delta["tool_calls"]?.asArray ?? [] {
        let index = call["index"]?.asInt ?? pending.count
        var entry = pending[index] ?? PendingToolCall(id: "", name: "", arguments: "")
        if let id = call["id"]?.asString, !id.isEmpty {
          entry.id = id
        }
        if let name = call["function"]?["name"]?.asString, !name.isEmpty {
          entry.name += name
        }
        entry.arguments += call["function"]?["arguments"]?.asString ?? ""
        pending[index] = entry
      }
    }
    let toolCalls = try pending.keys.sorted().map { index -> AgentToolCall in
      guard let entry = pending[index] else {
        throw ToolLoopModelClientError.malformedResponse("tool call index \(index) vanished")
      }
      let raw = entry.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
      let input: JSONValue
      if raw.isEmpty {
        input = .object([:])
      } else {
        do {
          input = try JSONValue(parsing: raw)
        } catch {
          throw ToolLoopModelClientError.malformedResponse("tool call arguments for \(entry.name) are not JSON")
        }
      }
      let id = entry.id.isEmpty ? "call_\(index)" : entry.id
      guard !entry.name.isEmpty else {
        throw ToolLoopModelClientError.malformedResponse("tool call \(id) has no function name")
      }
      return AgentToolCall(id: id, name: entry.name, input: input)
    }
    let stopReason: ToolLoopStopReason
    switch finishReason {
    case "tool_calls", "function_call": stopReason = .toolUse
    case "length": stopReason = .maxTokens
    case "content_filter": stopReason = .refusal
    default: stopReason = toolCalls.isEmpty ? .endTurn : .toolUse
    }
    return ToolLoopModelTurn(text: text, toolCalls: toolCalls, stopReason: stopReason)
  }
}
