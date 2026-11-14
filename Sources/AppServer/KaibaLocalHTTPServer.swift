import Foundation

#if canImport(Network)
import Network

public enum KaibaLocalHTTPServerState: Equatable, Sendable {
  case stopped
  case starting(port: Int)
  case running(port: Int)
  case stopping(port: Int?)
  case failed(message: String)

  public var boundPort: Int? {
    if case let .running(port) = self {
      return port
    }
    return nil
  }
}

public enum KaibaLocalHTTPServerError: LocalizedError, Equatable, Sendable {
  case invalidPort(Int)
  case invalidHost(String)
  case unexpectedBoundPort(requested: Int, actual: Int)
  case listenerFailed(String)
  case cancelledBeforeReady

  public var errorDescription: String? {
    switch self {
    case let .invalidPort(port):
      "HTTP listener port must be between 1 and 65535; received \(port)."
    case let .invalidHost(host):
      "HTTP listener host must be an IPv4 address or localhost; received '\(host)'."
    case let .unexpectedBoundPort(requested, actual):
      "HTTP listener bound unexpected port \(actual); requested \(requested)."
    case let .listenerFailed(message):
      "HTTP listener failed: \(message)"
    case .cancelledBeforeReady:
      "HTTP listener stopped before it became ready."
    }
  }
}

public final class KaibaLocalHTTPServer: @unchecked Sendable {
  public typealias StateHandler = @Sendable (KaibaLocalHTTPServerState) -> Void

  private let routeHandler: any KaibaHTTPRouteHandling
  private let queue: DispatchQueue
  private let incompleteRequestTimeoutNanoseconds: UInt64
  private let scheduleIncompleteRequestTimeout: (@escaping @Sendable () -> Void) -> Void
  private let lock = NSLock()
  /// Every accepted connection owns a socket, a parsing buffer, and often a
  /// long-poll task.  Keep a hard server-wide ceiling independent of route
  /// admission so malformed or unauthenticated requests cannot exhaust them.
  public static let maximumConcurrentConnections = 256
  /// Long-poll routes begin only after a complete request. Headers and bodies
  /// have one non-extendable lifetime so a slow peer cannot retain capacity
  /// forever by periodically sending a byte.
  public static let defaultIncompleteRequestTimeout: UInt64 = 15_000_000_000

  /// Extracted so connection-capacity admission can be exercised without
  /// opening hundreds of sockets in a unit test.
  static func hasConnectionCapacity(activeConnectionCount: Int) -> Bool {
    activeConnectionCount < maximumConcurrentConnections
  }
  private var listener: NWListener?
  private var connections: [UUID: NWConnection] = [:]
  private var incompleteRequestTimeoutGenerations: [UUID: UInt64] = [:]
  private var generation: UInt64 = 0
  private var state = KaibaLocalHTTPServerState.stopped
  private var stateHandler: StateHandler?
  private var startContinuation: CheckedContinuation<Int, Error>?
  private var stopContinuations: [CheckedContinuation<Void, Never>] = []

  public init(
    routeHandler: any KaibaHTTPRouteHandling,
    queue: DispatchQueue = DispatchQueue(label: "dev.kaiba.local-http-server", qos: .userInitiated),
    incompleteRequestTimeoutNanoseconds: UInt64 = defaultIncompleteRequestTimeout,
    incompleteRequestTimeoutScheduler: ((@escaping @Sendable () -> Void) -> Void)? = nil
  ) {
    self.routeHandler = routeHandler
    self.queue = queue
    self.incompleteRequestTimeoutNanoseconds = incompleteRequestTimeoutNanoseconds
    if let incompleteRequestTimeoutScheduler {
      scheduleIncompleteRequestTimeout = incompleteRequestTimeoutScheduler
    } else {
      let timeout = incompleteRequestTimeoutNanoseconds
      scheduleIncompleteRequestTimeout = { work in
        queue.asyncAfter(
          deadline: .now() + .nanoseconds(Int(clamping: timeout)),
          execute: work
        )
      }
    }
  }

  public func setStateHandler(_ handler: StateHandler?) {
    let current: KaibaLocalHTTPServerState
    lock.lock()
    stateHandler = handler
    current = state
    lock.unlock()
    handler?(current)
  }

  public var currentState: KaibaLocalHTTPServerState {
    lock.lock()
    defer { lock.unlock() }
    return state
  }

  /// Internal observability for deterministic connection-capacity tests.
  var activeConnectionCountForTesting: Int {
    lock.lock()
    defer { lock.unlock() }
    return connections.count
  }

  @discardableResult
  public func start(port: Int) async throws -> Int {
    try await start(host: "127.0.0.1", port: port)
  }

  @discardableResult
  public func start(host: String, port: Int) async throws -> Int {
    try await start(host: host, port: port, allowsEphemeralPort: false)
  }

  @discardableResult
  func startForTesting() async throws -> Int {
    try await start(host: "127.0.0.1", port: 0, allowsEphemeralPort: true)
  }

  private func start(host: String, port: Int, allowsEphemeralPort: Bool) async throws -> Int {
    guard (1...65_535).contains(port) || (allowsEphemeralPort && port == 0) else {
      throw KaibaLocalHTTPServerError.invalidPort(port)
    }
    if let runningPort = currentState.boundPort {
      return runningPort
    }
    let bindingHost = try Self.bindingHost(for: host)
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(
      host: NWEndpoint.Host(bindingHost),
      port: NWEndpoint.Port(rawValue: UInt16(port))!
    )
    let newListener: NWListener
    do {
      newListener = try NWListener(using: parameters)
    } catch {
      throw KaibaLocalHTTPServerError.listenerFailed(Self.sanitized(error))
    }

    return try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      if listener != nil {
        lock.unlock()
        continuation.resume(throwing: KaibaLocalHTTPServerError.listenerFailed("already starting"))
        return
      }
      generation &+= 1
      let currentGeneration = generation
      listener = newListener
      startContinuation = continuation
      updateStateLocked(.starting(port: port))
      lock.unlock()

      newListener.stateUpdateHandler = { [weak self, weak newListener] listenerState in
        guard let self, let newListener else { return }
        self.handleListenerState(
          listenerState,
          listener: newListener,
          generation: currentGeneration,
          requestedPort: port,
          allowsEphemeralPort: allowsEphemeralPort
        )
      }
      newListener.newConnectionHandler = { [weak self] connection in
        self?.accept(connection, generation: currentGeneration)
      }
      newListener.start(queue: queue)
    }
  }

  public func stop() async {
    await withCheckedContinuation { continuation in
      let listenerToCancel: NWListener?
      let connectionsToCancel: [NWConnection]
      lock.lock()
      guard let activeListener = listener else {
        updateStateLocked(.stopped)
        lock.unlock()
        continuation.resume()
        return
      }
      listenerToCancel = activeListener
      connectionsToCancel = Array(connections.values)
      stopContinuations.append(continuation)
      updateStateLocked(.stopping(port: state.boundPort))
      lock.unlock()
      connectionsToCancel.forEach { $0.cancel() }
      listenerToCancel?.cancel()
    }
  }

  private func handleListenerState(
    _ listenerState: NWListener.State,
    listener sourceListener: NWListener,
    generation sourceGeneration: UInt64,
    requestedPort: Int,
    allowsEphemeralPort: Bool
  ) {
    switch listenerState {
    case .ready:
      let boundPort = Int(sourceListener.port?.rawValue ?? 0)
      guard allowsEphemeralPort || boundPort == requestedPort else {
        finishListener(
          sourceListener,
          generation: sourceGeneration,
          failure: .unexpectedBoundPort(requested: requestedPort, actual: boundPort)
        )
        sourceListener.cancel()
        return
      }
      let continuation: CheckedContinuation<Int, Error>?
      lock.lock()
      guard listener === sourceListener, generation == sourceGeneration else {
        lock.unlock()
        return
      }
      continuation = startContinuation
      startContinuation = nil
      updateStateLocked(.running(port: boundPort))
      lock.unlock()
      continuation?.resume(returning: boundPort)
    case let .failed(error):
      finishListener(
        sourceListener,
        generation: sourceGeneration,
        failure: .listenerFailed(Self.sanitized(error))
      )
      sourceListener.cancel()
    case .cancelled:
      finishListener(sourceListener, generation: sourceGeneration, failure: nil)
    case .setup, .waiting:
      break
    @unknown default:
      break
    }
  }

  private func finishListener(
    _ sourceListener: NWListener,
    generation sourceGeneration: UInt64,
    failure: KaibaLocalHTTPServerError?
  ) {
    let pendingStart: CheckedContinuation<Int, Error>?
    let pendingStops: [CheckedContinuation<Void, Never>]
    lock.lock()
    guard listener === sourceListener, generation == sourceGeneration else {
      lock.unlock()
      return
    }
    listener = nil
    connections.removeAll()
    incompleteRequestTimeoutGenerations.removeAll()
    pendingStart = startContinuation
    startContinuation = nil
    pendingStops = stopContinuations
    stopContinuations.removeAll()
    if let failure {
      updateStateLocked(.failed(message: failure.localizedDescription))
    } else {
      updateStateLocked(.stopped)
    }
    lock.unlock()
    if let pendingStart {
      pendingStart.resume(throwing: failure ?? .cancelledBeforeReady)
    }
    pendingStops.forEach { $0.resume() }
  }

  private static func bindingHost(for host: String) throws -> String {
    if host.caseInsensitiveCompare("localhost") == .orderedSame {
      return "127.0.0.1"
    }
    guard IPv4Address(host) != nil else {
      throw KaibaLocalHTTPServerError.invalidHost(host)
    }
    return host
  }

  private func accept(_ connection: NWConnection, generation sourceGeneration: UInt64) {
    let connectionID = UUID()
    lock.lock()
    guard generation == sourceGeneration, listener != nil else {
      lock.unlock()
      connection.cancel()
      return
    }
    guard Self.hasConnectionCapacity(activeConnectionCount: connections.count) else {
      lock.unlock()
      let response = KaibaHTTPResponse.text(status: 429, "Server connection capacity reached")
      connection.start(queue: queue)
      connection.send(content: response.serialized(forMethod: "GET"), completion: .contentProcessed { _ in
        connection.cancel()
      })
      return
    }
    connections[connectionID] = connection
    lock.unlock()
    connection.stateUpdateHandler = { [weak self, weak connection] connectionState in
      guard let self, let connection else { return }
      switch connectionState {
      case .ready:
        self.refreshIncompleteRequestDeadline(for: connection, id: connectionID)
        self.receive(from: connection, id: connectionID, buffer: Data())
      case .failed, .cancelled:
        self.removeConnection(id: connectionID)
      default:
        break
      }
    }
    connection.start(queue: queue)
  }

  private func receive(from connection: NWConnection, id: UUID, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      var nextBuffer = buffer
      if let data {
        nextBuffer.append(data)
      }
      do {
        switch try KaibaHTTPRequestParser().parse(nextBuffer) {
        case .incomplete:
          if isComplete || error != nil {
            self.send(.text(status: 400, "Incomplete HTTP request"), method: "GET", through: connection, id: id)
          } else {
            self.refreshIncompleteRequestDeadline(for: connection, id: id)
            self.receive(from: connection, id: id, buffer: nextBuffer)
          }
        case let .complete(request):
          self.clearIncompleteRequestDeadline(id: id)
          Task {
            let response = await self.routeHandler.response(for: request)
            self.send(response, method: request.method, through: connection, id: id)
          }
        }
      } catch let parserError as KaibaHTTPRequestParserError {
        self.send(
          .text(status: parserError.status, parserError.localizedDescription),
          method: "GET",
          through: connection,
          id: id
        )
      } catch {
        self.send(.text(status: 400, "Bad Request"), method: "GET", through: connection, id: id)
      }
    }
  }

  private func send(
    _ response: KaibaHTTPResponse,
    method: String,
    through connection: NWConnection,
    id: UUID
  ) {
    connection.send(content: response.serialized(forMethod: method), completion: .contentProcessed { [weak self] _ in
      connection.cancel()
      self?.removeConnection(id: id)
    })
  }

  private func removeConnection(id: UUID) {
    lock.lock()
    connections[id] = nil
    incompleteRequestTimeoutGenerations[id] = nil
    lock.unlock()
  }

  private func refreshIncompleteRequestDeadline(for connection: NWConnection, id: UUID) {
    let timeoutGeneration: UInt64
    lock.lock()
    guard connections[id] === connection else {
      lock.unlock()
      return
    }
    guard incompleteRequestTimeoutGenerations[id] == nil else {
      lock.unlock()
      return
    }
    timeoutGeneration = 1
    incompleteRequestTimeoutGenerations[id] = timeoutGeneration
    lock.unlock()
    scheduleIncompleteRequestTimeout { [weak self, weak connection] in
      guard let self, let connection else { return }
      self.expireIncompleteRequest(
        for: connection,
        id: id,
        timeoutGeneration: timeoutGeneration
      )
    }
  }

  private func clearIncompleteRequestDeadline(id: UUID) {
    lock.lock()
    incompleteRequestTimeoutGenerations[id] = nil
    lock.unlock()
  }

  private func expireIncompleteRequest(
    for connection: NWConnection,
    id: UUID,
    timeoutGeneration: UInt64
  ) {
    lock.lock()
    guard connections[id] === connection,
      incompleteRequestTimeoutGenerations[id] == timeoutGeneration
    else {
      lock.unlock()
      return
    }
    connections[id] = nil
    incompleteRequestTimeoutGenerations[id] = nil
    lock.unlock()
    connection.cancel()
  }

  private func updateStateLocked(_ newState: KaibaLocalHTTPServerState) {
    state = newState
    let callback = stateHandler
    if let callback {
      queue.async {
        callback(newState)
      }
    }
  }

  private static func sanitized(_ error: Error) -> String {
    let message = error.localizedDescription
    return message.count <= 240 ? message : String(message.prefix(240))
  }
}
#endif

public enum KaibaWebAssetLocator {
  public static func locate(
    bundle: Bundle = .main,
    executableURL: URL? = Bundle.main.executableURL,
    currentDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
  ) -> URL? {
    var candidates: [URL] = []
    if let resourceURL = bundle.resourceURL {
      candidates.append(resourceURL.appendingPathComponent("Web", isDirectory: true))
    }
    if let executableURL {
      candidates.append(
        executableURL.deletingLastPathComponent()
          .appendingPathComponent("../Resources/Web", isDirectory: true)
          .standardizedFileURL
      )
    }
    candidates.append(currentDirectoryURL.appendingPathComponent("web/dist", isDirectory: true))
    return candidates.first { candidate in
      FileManager.default.fileExists(atPath: candidate.appendingPathComponent("index.html").path)
    }
  }
}
