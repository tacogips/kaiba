import Foundation

extension AgentGatewayCLIInvoker {
  /// Maps every served gateway failure that can cross into durable AI workflow
  /// state to a diagnostic which contains neither a configured executable path
  /// nor server-local process details. Existing served `.failed` values are
  /// already constructed from fixed diagnostics or `sanitizedDiagnostic`.
  static func sanitizedInvocationError(
    _ error: Error,
    executionMode: AgentGatewayExecutionMode
  ) -> Error {
    guard executionMode == .served else { return error }
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
