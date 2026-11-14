import Foundation

/// The converter protocol is synchronous. Async request handlers must dispatch
/// it to a blocking worker, keeping Swift's cooperative executor free.
final class SynchronousGatewayResult: @unchecked Sendable {
  private let condition = NSCondition()
  private var result: Result<AgentGatewayCLIInvoker.Execution, Error>?

  func finish(_ result: Result<AgentGatewayCLIInvoker.Execution, Error>) {
    condition.lock()
    self.result = result
    condition.signal()
    condition.unlock()
  }

  func wait() throws -> AgentGatewayCLIInvoker.Execution {
    condition.lock()
    defer { condition.unlock() }
    while result == nil { condition.wait() }
    guard let result else { throw DocumentConversionError.failed("gateway execution did not finish") }
    return try result.get()
  }
}
