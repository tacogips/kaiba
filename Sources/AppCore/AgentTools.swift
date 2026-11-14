import Foundation

/// A tool the model may call, described with a JSON Schema object for its
/// input (`design-docs/specs/user-agent-tools.md`, UA3). Provider clients
/// translate this into their own tool declaration shape.
public struct AgentToolDefinition: Equatable, Sendable {
  public var name: String
  public var description: String
  public var inputSchema: JSONValue

  public init(name: String, description: String, inputSchema: JSONValue) {
    self.name = name
    self.description = description
    self.inputSchema = inputSchema
  }
}

/// One tool invocation requested by the model. `id` is the provider's call
/// identifier and is echoed back with the result.
public struct AgentToolCall: Equatable, Sendable {
  public var id: String
  public var name: String
  public var input: JSONValue

  public init(id: String, name: String, input: JSONValue) {
    self.id = id
    self.name = name
    self.input = input
  }
}

/// The outcome of one tool call, sent back to the model.
public struct AgentToolResult: Equatable, Sendable {
  public var callId: String
  public var content: String
  public var isError: Bool

  public init(callId: String, content: String, isError: Bool = false) {
    self.callId = callId
    self.content = content
    self.isError = isError
  }
}

/// Executes tool calls inside the server process. Implementations must be
/// safe to call from any task; they receive one call at a time.
public protocol AgentToolExecuting: Sendable {
  var definitions: [AgentToolDefinition] { get }
  func execute(_ call: AgentToolCall) async -> AgentToolResult
}

/// Thrown by tool bodies; the executor turns it into an error result.
public enum AgentToolError: Error, Equatable, Sendable {
  case unknownTool(String)
  case invalidInput(String)
  case rejected(String)
}

extension AgentToolError: CustomStringConvertible {
  public var description: String {
    switch self {
    case .unknownTool(let name): return "unknown tool: \(name)"
    case .invalidInput(let message): return "invalid tool input: \(message)"
    case .rejected(let message): return message
    }
  }
}

/// Shared bounds and helpers for tool output.
public enum AgentToolOutputLimits {
  /// Per-result cap on what is sent back to the model.
  public static let maximumResultBytes = 48 * 1024
  /// Note bodies inside a tool result are cut at this size with a marker.
  /// Kept well under `maximumResultBytes` so a `get_note` payload carrying a
  /// large body stays complete JSON (tags, comments, links intact) instead of
  /// being cut mid-document by the outer bound.
  public static let maximumNoteBodyBytes = 32 * 1024
  public static let truncationMarker = "\n[truncated by kaiba: output exceeded the tool result limit]"

  /// Truncates on a character boundary so the result stays valid UTF-8.
  public static func bounded(_ text: String, maximumBytes: Int = maximumResultBytes) -> String {
    guard text.utf8.count > maximumBytes else {
      return text
    }
    let budget = max(0, maximumBytes - truncationMarker.utf8.count)
    var kept = ""
    var used = 0
    for character in text {
      let size = character.utf8.count
      guard used + size <= budget else {
        break
      }
      kept.append(character)
      used += size
    }
    return kept + truncationMarker
  }
}
