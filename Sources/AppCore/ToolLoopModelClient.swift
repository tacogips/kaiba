import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One message in the provider conversation the tool loop maintains
/// (`design-docs/specs/user-agent-tools.md`, UA3). Provider clients render
/// these into their own wire shapes.
enum ToolLoopMessage: Equatable, Sendable {
  case user(String)
  case assistant(text: String, toolCalls: [AgentToolCall])
  case toolResults([AgentToolResult])
}

enum ToolLoopStopReason: Equatable, Sendable {
  case endTurn
  case toolUse
  case maxTokens
  case refusal
}

/// What one provider round trip produced.
struct ToolLoopModelTurn: Equatable, Sendable {
  var text: String
  var toolCalls: [AgentToolCall]
  var stopReason: ToolLoopStopReason
}

struct ToolLoopModelRequest: Equatable, Sendable {
  var model: String
  var systemPrompt: String
  var messages: [ToolLoopMessage]
  var tools: [AgentToolDefinition]
}

/// The provider seam: one streamed completion per call. Text deltas are
/// delivered through `onTextDelta` as they arrive; returning false asks the
/// client to stop reading and throw `ToolLoopModelClientError.aborted`.
protocol ToolLoopModelClient: Sendable {
  func complete(
    _ request: ToolLoopModelRequest,
    onTextDelta: @escaping @Sendable (String) -> Bool
  ) async throws -> ToolLoopModelTurn
}

enum ToolLoopModelClientError: Error, Equatable, Sendable {
  case transport(String)
  case httpStatus(Int, String)
  /// An error the provider reported inside an otherwise successful stream
  /// (an SSE `error` event or an `error` chunk).
  case providerError(String)
  case malformedResponse(String)
  case aborted
}

extension ToolLoopModelClientError: CustomStringConvertible {
  var description: String {
    switch self {
    case .transport(let message): return "provider request failed: \(message)"
    case .httpStatus(let status, let message): return "provider returned HTTP \(status): \(message)"
    case .providerError(let message): return "provider reported an error: \(message)"
    case .malformedResponse(let message): return "provider response was malformed: \(message)"
    case .aborted: return "provider stream was aborted"
    }
  }
}

// MARK: - HTTP streaming seam

struct AgentHTTPStreamRequest: Equatable, Sendable {
  var url: URL
  var headers: [String: String]
  var body: Data
}

struct AgentHTTPStreamResponse: Sendable {
  var statusCode: Int
  /// Response body lines without their terminators. For an SSE body every
  /// `data:` line arrives as its own element; for an error body the JSON
  /// arrives as one or more lines.
  var lines: AsyncThrowingStream<String, Error>
}

/// Issues one POST and exposes the body incrementally. Injected so tests can
/// script provider streams without a network.
protocol AgentHTTPStreaming: Sendable {
  func stream(_ request: AgentHTTPStreamRequest) async throws -> AgentHTTPStreamResponse
}

/// Production streamer over `URLSession`. Requests time out after ten
/// minutes without bytes, which bounds a stalled provider.
struct URLSessionAgentHTTPStreamer: AgentHTTPStreaming {
  static let requestTimeout: TimeInterval = 600

  func stream(_ request: AgentHTTPStreamRequest) async throws -> AgentHTTPStreamResponse {
    var urlRequest = URLRequest(url: request.url, timeoutInterval: Self.requestTimeout)
    urlRequest.httpMethod = "POST"
    urlRequest.httpBody = request.body
    for (name, value) in request.headers {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }
    #if canImport(FoundationNetworking)
    // swift-corelibs-foundation has no byte stream; read the whole body and
    // replay it line by line so callers see one code path.
    let (data, response): (Data, URLResponse)
    do {
      (data, response) = try await URLSession.shared.data(for: urlRequest)
    } catch {
      throw ToolLoopModelClientError.transport("\(error)")
    }
    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
    let text = String(bytes: data, encoding: .utf8) ?? ""
    let lines = AsyncThrowingStream<String, Error> { continuation in
      for line in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" }) {
        continuation.yield(String(line).trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
      }
      continuation.finish()
    }
    return AgentHTTPStreamResponse(statusCode: statusCode, lines: lines)
    #else
    let (bytes, response): (URLSession.AsyncBytes, URLResponse)
    do {
      (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
    } catch {
      throw ToolLoopModelClientError.transport("\(error)")
    }
    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
    let lines = AsyncThrowingStream<String, Error> { continuation in
      let task = Task {
        do {
          for try await line in bytes.lines {
            continuation.yield(line)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: ToolLoopModelClientError.transport("\(error)"))
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
    return AgentHTTPStreamResponse(statusCode: statusCode, lines: lines)
    #endif
  }
}

// MARK: - Shared helpers for SSE-speaking clients

enum ToolLoopSSE {
  /// The payload of a `data:` line, or nil for comments, event names, and
  /// blank separators.
  static func dataPayload(of line: String) -> String? {
    guard line.hasPrefix("data:") else {
      return nil
    }
    var payload = line.dropFirst("data:".count)
    if payload.first == " " {
      payload = payload.dropFirst()
    }
    return String(payload)
  }

  /// Collects an error body (non-SSE) into one string bounded for messages.
  static func collectBody(_ lines: AsyncThrowingStream<String, Error>, limit: Int = 4096) async -> String {
    var collected = ""
    do {
      for try await line in lines {
        collected += line
        if collected.utf8.count >= limit {
          break
        }
      }
    } catch {
      // The status code already describes the failure; a truncated body is fine.
    }
    return String(collected.prefix(limit))
  }

  /// Extracts a human-readable message from a provider error body when it is
  /// JSON of the common `{ "error": { "message": ... } }` shape.
  static func errorMessage(fromBody body: String) -> String {
    guard let value = try? JSONValue(parsing: body) else {
      return body.isEmpty ? "(empty body)" : body
    }
    if let message = value["error"]?["message"]?.asString {
      return message
    }
    if let message = value["error"]?.asString {
      return message
    }
    if let message = value["message"]?.asString {
      return message
    }
    return body
  }
}
