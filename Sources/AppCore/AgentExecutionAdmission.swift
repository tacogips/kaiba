import Foundation

public enum AgentExecutionAdmissionError: Error, Equatable, Sendable {
  case overloaded
}

/// Shared, non-blocking admission control for work that can invoke an external
/// agent process or provider. Callers that cannot acquire a permit leave their
/// durable work pending (or return a transient overload response) instead of
/// creating an unbounded task or subprocess backlog.
public final class AgentExecutionAdmission: @unchecked Sendable {
  public struct Lease: Equatable, Sendable {
    fileprivate let id: UUID
    public let principalId: String
  }

  public let maximumConcurrentExecutions: Int
  public let maximumConcurrentExecutionsPerPrincipal: Int

  private let lock = NSLock()
  private var leases: [UUID: String] = [:]

  public init(
    maximumConcurrentExecutions: Int = 16,
    maximumConcurrentExecutionsPerPrincipal: Int = 4
  ) {
    self.maximumConcurrentExecutions = max(1, maximumConcurrentExecutions)
    self.maximumConcurrentExecutionsPerPrincipal = max(1, maximumConcurrentExecutionsPerPrincipal)
  }

  /// Returns nil when global or principal capacity is exhausted. This method
  /// deliberately never waits: request paths can surface backpressure and
  /// durable outbox work remains pending for a later maintenance pass.
  public func acquire(principalId: String) -> Lease? {
    lock.lock()
    defer { lock.unlock() }
    guard leases.count < maximumConcurrentExecutions,
      leases.values.filter({ $0 == principalId }).count < maximumConcurrentExecutionsPerPrincipal
    else {
      return nil
    }
    let id = UUID()
    leases[id] = principalId
    return Lease(id: id, principalId: principalId)
  }

  public func release(_ lease: Lease) {
    lock.lock()
    leases.removeValue(forKey: lease.id)
    lock.unlock()
  }

  public var activeExecutionCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return leases.count
  }
}

public extension NoteService {
  /// Stable tenant key for admission accounting. The unscoped local operator
  /// remains distinct from the unauthenticated default-user principal.
  func agentExecutionPrincipalId() -> String {
    if isUnauthenticatedPrincipal {
      return "unauthenticated:\((actingUserId ?? NoteStoreSchema.defaultUserId).rawValue)"
    }
    if let actingUserId {
      return "user:\(actingUserId.rawValue)"
    }
    return "operator"
  }
}
