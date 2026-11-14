import Network
@testable import AppServer
import XCTest

private actor ConnectionCapacityGate {
  private var entered = 0
  private var released = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func holdRequest() async {
    entered += 1
    let waiters = entryWaiters
    entryWaiters.removeAll()
    waiters.forEach { $0.resume() }
    guard !released else { return }
    await withCheckedContinuation { releaseWaiters.append($0) }
  }

  func waitUntilEntered(_ expectedCount: Int) async {
    guard entered < expectedCount else { return }
    await withCheckedContinuation { entryWaiters.append($0) }
    await waitUntilEntered(expectedCount)
  }

  func releaseAll() {
    released = true
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }
}

private actor ManualIncompleteRequestDeadlineScheduler {
  private var workItems: [@Sendable () -> Void] = []
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func schedule(_ work: @escaping @Sendable () -> Void) {
    workItems.append(work)
    let waiters = waiters
    self.waiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  func waitUntilScheduled(_ expectedCount: Int) async {
    while workItems.count < expectedCount {
      await withCheckedContinuation { waiters.append($0) }
    }
  }

  var scheduledCount: Int {
    workItems.count
  }

  func fireAll() {
    let workItems = workItems
    self.workItems.removeAll()
    workItems.forEach { $0() }
  }
}

final class KaibaLocalHTTPServerCapacityTests: XCTestCase {
  func testConnectionCapacityRejects257thOpenConnectionAndRecoversAfterRelease() async throws {
    let gate = ConnectionCapacityGate()
    let server = KaibaLocalHTTPServer(routeHandler: AnyKaibaHTTPRouteHandler { _ in
      await gate.holdRequest()
      return .text(status: 200, "released")
    })
    let port = try await server.startForTesting()
    let heldConnections = (0..<KaibaLocalHTTPServer.maximumConcurrentConnections).map { _ in
      openHeldConnection(port: port)
    }
    defer { heldConnections.forEach { $0.cancel() } }

    await gate.waitUntilEntered(KaibaLocalHTTPServer.maximumConcurrentConnections)
    XCTAssertEqual(server.activeConnectionCountForTesting, KaibaLocalHTTPServer.maximumConcurrentConnections)

    let rejectedResponse = try await requestResponse(port: port)
    XCTAssertTrue(rejectedResponse.hasPrefix("HTTP/1.1 429"))
    XCTAssertEqual(server.activeConnectionCountForTesting, KaibaLocalHTTPServer.maximumConcurrentConnections)

    await gate.releaseAll()
    try await waitUntilConnectionCount(server, equals: 0)
    let acceptedResponse = try await requestResponse(port: port)
    XCTAssertTrue(acceptedResponse.hasPrefix("HTTP/1.1 200"))
    await server.stop()
  }

  func testIncompleteRequestsExpireAndReleaseConnectionCapacity() async throws {
    let deadlines = ManualIncompleteRequestDeadlineScheduler()
    let server = KaibaLocalHTTPServer(
      routeHandler: AnyKaibaHTTPRouteHandler { _ in .text(status: 200, "ok") },
      incompleteRequestTimeoutScheduler: { work in
        Task { await deadlines.schedule(work) }
      }
    )
    let port = try await server.startForTesting()
    let partialConnections = (0..<KaibaLocalHTTPServer.maximumConcurrentConnections).map { _ in
      openPartialConnection(port: port)
    }
    defer { partialConnections.forEach { $0.cancel() } }

    try await waitUntilConnectionCount(
      server,
      equals: KaibaLocalHTTPServer.maximumConcurrentConnections,
      timeout: .seconds(10)
    )
    let rejectedResponse = try await requestResponse(port: port)
    XCTAssertTrue(rejectedResponse.hasPrefix("HTTP/1.1 429"))

    await deadlines.waitUntilScheduled(KaibaLocalHTTPServer.maximumConcurrentConnections)
    for connection in partialConnections {
      try await sendPartialProgress(to: connection)
    }
    try await Task.sleep(for: .milliseconds(100))
    let scheduledDeadlineCount = await deadlines.scheduledCount
    XCTAssertEqual(
      scheduledDeadlineCount,
      KaibaLocalHTTPServer.maximumConcurrentConnections,
      "partial progress must not extend the absolute request deadline"
    )
    await deadlines.fireAll()
    try await waitUntilConnectionCount(server, equals: 0)
    let acceptedResponse = try await requestResponse(port: port)
    XCTAssertTrue(acceptedResponse.hasPrefix("HTTP/1.1 200"))
    await server.stop()
  }

  private func openHeldConnection(port: Int) -> NWConnection {
    let connection = makeConnection(port: port)
    connection.start(queue: .global(qos: .userInitiated))
    connection.send(content: requestData, completion: .contentProcessed { _ in })
    return connection
  }

  private func openPartialConnection(port: Int) -> NWConnection {
    let connection = makeConnection(port: port)
    connection.start(queue: .global(qos: .userInitiated))
    connection.send(content: partialRequestData, completion: .contentProcessed { _ in })
    return connection
  }

  private func requestResponse(port: Int) async throws -> String {
    let connection = makeConnection(port: port)
    return try await withCheckedThrowingContinuation { continuation in
      connection.start(queue: .global(qos: .userInitiated))
      connection.send(content: requestData, completion: .contentProcessed { error in
        if let error {
          connection.cancel()
          continuation.resume(throwing: error)
          return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { data, _, _, error in
          connection.cancel()
          if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume(returning: data.flatMap { String(bytes: $0, encoding: .utf8) } ?? "")
          }
        }
      })
    }
  }

  private func sendPartialProgress(to connection: NWConnection) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.send(content: Data("X-Progress: keep-alive".utf8), completion: .contentProcessed { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      })
    }
  }

  private func waitUntilConnectionCount(
    _ server: KaibaLocalHTTPServer,
    equals expectedCount: Int,
    timeout: Duration = .seconds(2)
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while server.activeConnectionCountForTesting != expectedCount {
      guard clock.now < deadline else {
        XCTFail("server connection count did not reach \(expectedCount); current \(server.activeConnectionCountForTesting)")
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func makeConnection(port: Int) -> NWConnection {
    NWConnection(
      host: "127.0.0.1",
      port: NWEndpoint.Port(rawValue: UInt16(port))!,
      using: .tcp
    )
  }

  private var requestData: Data {
    Data("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
  }

  private var partialRequestData: Data {
    Data("GET / HTTP/1.1\r\nHost: localhost\r\n".utf8)
  }
}
