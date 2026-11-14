import Foundation

/// Shared mutable engine state for NoteService values and their scoped copies.
public final class SearchEngineSlot: @unchecked Sendable {
  private let lock = NSLock()
  private var storedEngine: (any SearchEngine)?
  private var storedManagedConfiguration: KaibaSearchEngineConfiguration?
  private var storedEnvironment: [String: String] = [:]
  private var storedReloadHandler: (@Sendable () async -> SearchEngineReloadOutcome)?

  public init(engine: (any SearchEngine)? = nil) {
    storedEngine = engine
  }

  public var engine: (any SearchEngine)? {
    lock.withLock { storedEngine }
  }

  public func replace(_ engine: (any SearchEngine)?) {
    lock.withLock { storedEngine = engine }
  }

  public var managedConfiguration: KaibaSearchEngineConfiguration? {
    lock.withLock { storedManagedConfiguration }
  }

  public func setManagedConfiguration(_ configuration: KaibaSearchEngineConfiguration?) {
    lock.withLock { storedManagedConfiguration = configuration }
  }

  public var environment: [String: String] {
    lock.withLock { storedEnvironment }
  }

  public func setEnvironment(_ environment: [String: String]) {
    lock.withLock { storedEnvironment = environment }
  }

  public func setReloadHandler(_ handler: (@Sendable () async -> SearchEngineReloadOutcome)?) {
    lock.withLock { storedReloadHandler = handler }
  }

  public func reload() async -> SearchEngineReloadOutcome? {
    let handler = lock.withLock { storedReloadHandler }
    guard let handler else { return nil }
    return await handler()
  }
}
