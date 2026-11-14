import Foundation

extension AgentGatewayCLIInvoker {
  static func servedNoReplyDiagnostic(exitCode: Int32, stderr: Data) -> String {
    let stderrText = (String(bytes: stderr, encoding: .utf8) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if stderrText.hasPrefix("sandbox-exec:") {
      return "agent-gateway could not start inside the server sandbox (exit \(exitCode))"
    }
    return "agent-gateway produced no reply (exit \(exitCode))"
  }

  /// Maps every served gateway failure that can cross into durable AI workflow
  /// state to a diagnostic which contains neither a configured executable path
  /// nor server-local process details. Existing served `.failed` values are
  /// already constructed from fixed diagnostics or `sanitizedDiagnostic`.
  static func sanitizedInvocationError(
    _ error: Error,
    executionMode: AgentGatewayExecutionMode
  ) -> Error {
    guard executionMode != .local else { return error }
    guard !(error is CancellationError) else { return error }
    if let invocationError = error as? AgentInvocationError {
      switch invocationError {
      case .failed:
        return invocationError
      case .notConfigured:
        return AgentInvocationError.notConfigured
      case .unavailable:
        return AgentInvocationError.unavailable("server agent-gateway is unavailable")
      }
    }
    return AgentInvocationError.failed("agent-gateway request failed")
  }
}

public extension AgentInvocationError {
  var publicDiagnostic: String {
    switch self {
    case .notConfigured:
      return "agent runtime is not configured"
    case .unavailable:
      return "agent runtime is unavailable"
    case .failed(let message):
      let fixedReasons: Set<String> = [
        "agent-gateway request failed",
        "agent-gateway invocation timed out",
        "agent-gateway output exceeds the 256 KiB process limit",
        "agent reply exceeds the 256 KiB or 256-chunk output limit",
        "server agent-gateway is unavailable"
      ]
      if fixedReasons.contains(message)
        || Self.matchesNumericTemplate(message, prefix: "agent-gateway produced no reply (exit ", suffix: ")")
        || Self.matchesNumericTemplate(message, prefix: "agent-gateway could not start inside the server sandbox (exit ", suffix: ")")
        || Self.matchesNumericTemplate(message, prefix: "agent-gateway exited with status ", suffix: "") {
        return message
      }
      return "agent request failed"
    }
  }

  private static func matchesNumericTemplate(_ message: String, prefix: String, suffix: String) -> Bool {
    guard message.hasPrefix(prefix), message.hasSuffix(suffix) else { return false }
    let start = message.index(message.startIndex, offsetBy: prefix.count)
    let end = message.index(message.endIndex, offsetBy: -suffix.count)
    guard start <= end else { return false }
    var number = message[start..<end]
    if number.first == "-" {
      number = number.dropFirst()
    }
    return (1...10).contains(number.count) && number.utf8.allSatisfy { (48...57).contains($0) }
  }
}
