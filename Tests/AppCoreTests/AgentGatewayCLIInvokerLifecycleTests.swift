import Foundation
@testable import AppCore
import XCTest

#if os(Linux)
import Glibc
#else
import Darwin
#endif

final class AgentGatewayCLIInvokerLifecycleTests: XCTestCase {
  func testProductionPostReapCleanupWithoutDescendantsSkipsGraceAndSIGKILL() async throws {
    let identifier = UUID().uuidString
    let leaderMarker = lifecycleFixtureURL("gateway-leader-\(identifier)")
    let scriptURL = try makeLifecycleGatewayScript("""
    #!/bin/sh
    echo $$ > "$GATEWAY_LEADER_PID_MARKER"
    cat > /dev/null
    exit 0
    """)
    defer {
      try? FileManager.default.removeItem(at: scriptURL)
      try? FileManager.default.removeItem(at: leaderMarker)
    }
    let signals = GatewayLifecycleSignalRecorder()
    var environment = ProcessInfo.processInfo.environment
    environment["GATEWAY_LEADER_PID_MARKER"] = leaderMarker.path
    let clock = ContinuousClock()
    let started = clock.now
    let execution = try await runLifecycleGateway(
      scriptURL, environment: environment, grace: 2_000_000_000, signals: signals
    )

    XCTAssertEqual(execution.exitCode, 0)
    XCTAssertLessThan(
      clock.now - started,
      .seconds(1),
      "a descendant-free process group must not wait through its two-second grace period"
    )
    try assertSignalsUseWitness(signals, gatewayLeaderFrom: leaderMarker)
    XCTAssertEqual(signals.terminationSignals.map(\.1), [SIGTERM])
  }

  func testZombieOnlyPostReapGroupWaitsForDisappearanceWithoutSIGKILL() async throws {
    let statusSequence = LifecycleDescendantStatusSequence([.zombies, .none])
    try await assertPostReapCleanupResolvesStatus(statusSequence, expectedSignals: [SIGTERM])
  }

  func testUnavailablePostReapInspectionDoesNotCompleteAsAnEmptyGroup() async throws {
    let statusSequence = LifecycleDescendantStatusSequence([.unavailable, .none])
    try await assertPostReapCleanupResolvesStatus(statusSequence, expectedSignals: [SIGTERM])
  }

  func testTimeoutAfterLeaderReapSignalsOnlyWitnessOwnedGroup() async throws {
    let identifier = UUID().uuidString
    let leaderMarker = lifecycleFixtureURL("gateway-leader-\(identifier)")
    let scriptURL = try makeLifecycleGatewayScript("""
    #!/bin/sh
    echo $$ > "$GATEWAY_LEADER_PID_MARKER"
    cat > /dev/null
    exit 0
    """)
    defer {
      try? FileManager.default.removeItem(at: scriptURL)
      try? FileManager.default.removeItem(at: leaderMarker)
    }
    let publicationGate = GatewayReapPublicationGate()
    let signals = GatewayLifecycleSignalRecorder()
    var environment = ProcessInfo.processInfo.environment
    environment["GATEWAY_LEADER_PID_MARKER"] = leaderMarker.path
    let task = Task {
      try await AgentGatewayCLIInvoker.run(
        binary: scriptURL.path, arguments: [], stdin: Data("hello".utf8), environment: environment,
        timeoutNanoseconds: 1_000_000_000, terminationGraceNanoseconds: 20_000_000,
        signalObserver: { signals.record(processIdentifier: $0, signal: $1) },
        leaderReapedObserver: { publicationGate.pauseAfterReap() }
      )
    }

    let didReapLeader = await waitForLifecycleCondition { publicationGate.hasReapedLeader }
    XCTAssertTrue(didReapLeader)
    let didSignalWitness = await waitForLifecycleCondition {
      signals.terminationSignals.contains { $0.1 == SIGTERM }
    }
    XCTAssertTrue(didSignalWitness)
    publicationGate.releaseCompletionPublication()
    do {
      _ = try await task.value
      XCTFail("expected timeout after the reaped leader publication pause")
    } catch AgentInvocationError.failed(let message) {
      XCTAssertEqual(message, "agent-gateway invocation timed out")
    }
    try assertSignalsUseWitness(signals, gatewayLeaderFrom: leaderMarker)
  }

  func testScheduledEscalationAfterLeaderReapSkipsEmptyWitnessGroup() async throws {
    let identifier = UUID().uuidString
    let fixtureDirectory = lifecycleFixtureURL("")
    let readyMarker = fixtureDirectory.appendingPathComponent("gateway-ready-\(identifier)")
    let termMarker = fixtureDirectory.appendingPathComponent("gateway-term-\(identifier)")
    let leaderMarker = fixtureDirectory.appendingPathComponent("gateway-leader-\(identifier)")
    let scriptURL = try makeLifecycleGatewayScript("""
    #!/bin/sh
    exec /usr/bin/python3 -c '
    import os
    import signal
    def handle_term(_signum, _frame):
        open(os.environ["GATEWAY_TERM_MARKER"], "w").close()
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, handle_term)
    open(os.environ["GATEWAY_LEADER_PID_MARKER"], "w").write(str(os.getpid()))
    open(os.environ["GATEWAY_READY_MARKER"], "w").close()
    signal.pause()
    '
    """)
    defer {
      [scriptURL, readyMarker, termMarker, leaderMarker].forEach { try? FileManager.default.removeItem(at: $0) }
    }
    let waitpidGate = GatewayWaitpidPublicationGate()
    let signals = GatewayLifecycleSignalRecorder()
    var environment = ProcessInfo.processInfo.environment
    environment["GATEWAY_READY_MARKER"] = readyMarker.path
    environment["GATEWAY_TERM_MARKER"] = termMarker.path
    environment["GATEWAY_LEADER_PID_MARKER"] = leaderMarker.path
    let task = Task {
      try await AgentGatewayCLIInvoker.run(
        binary: scriptURL.path, arguments: [], stdin: Data("hello".utf8), environment: environment,
        timeoutNanoseconds: 1_000_000_000, terminationGraceNanoseconds: 500_000_000,
        signalObserver: { signals.record(processIdentifier: $0, signal: $1) },
        leaderWaitpidReturnedObserver: { waitpidGate.pauseBeforeReapPublication() }
      )
    }

    let didBecomeReady = await waitForLifecycleCondition {
      FileManager.default.fileExists(atPath: readyMarker.path)
    }
    XCTAssertTrue(didBecomeReady)
    let didSignalTERM = await waitForLifecycleCondition {
      signals.terminationSignals.contains { $0.1 == SIGTERM }
    }
    XCTAssertTrue(didSignalTERM)
    let didHandleTERM = await waitForLifecycleCondition {
      FileManager.default.fileExists(atPath: termMarker.path)
    }
    XCTAssertTrue(didHandleTERM)
    let didReturnFromWaitpid = await waitForLifecycleCondition { waitpidGate.didReturnFromWaitpid }
    XCTAssertTrue(didReturnFromWaitpid)
    try? await Task.sleep(for: .milliseconds(600))
    XCTAssertEqual(signals.terminationSignals.map(\.1), [SIGTERM])
    waitpidGate.releaseReapPublication()
    do {
      _ = try await task.value
      XCTFail("expected timeout after the waitpid publication pause")
    } catch AgentInvocationError.failed(let message) {
      XCTAssertEqual(message, "agent-gateway invocation timed out")
    }
    XCTAssertEqual(signals.terminationSignals.map(\.1), [SIGTERM])
    try assertSignalsUseWitness(signals, gatewayLeaderFrom: leaderMarker)
  }

  func testPostReapCleanupKillsIgnoringDescendantThatClosedInheritedDescriptors() async throws {
    let identifier = UUID().uuidString
    let fixtureDirectory = lifecycleFixtureURL("")
    let childMarker = fixtureDirectory.appendingPathComponent("gateway-descendant-\(identifier)")
    let readyMarker = fixtureDirectory.appendingPathComponent("gateway-descendant-ready-\(identifier)")
    let leaderMarker = fixtureDirectory.appendingPathComponent("gateway-leader-\(identifier)")
    let scriptURL = try makeLifecycleGatewayScript("""
    #!/bin/sh
    echo $$ > "$GATEWAY_LEADER_PID_MARKER"
    (
      trap '' TERM
      echo $$ > "$GATEWAY_DESCENDANT_PID_MARKER"
      : > "$GATEWAY_DESCENDANT_READY_MARKER"
      exec 1>&-
      exec 2>&-
      while :; do sleep 1; done
    ) &
    while [ ! -f "$GATEWAY_DESCENDANT_READY_MARKER" ]; do sleep 0.01; done
    exit 0
    """)
    defer {
      [scriptURL, childMarker, readyMarker, leaderMarker].forEach { try? FileManager.default.removeItem(at: $0) }
    }
    let signals = GatewayLifecycleSignalRecorder()
    var environment = ProcessInfo.processInfo.environment
    environment["GATEWAY_DESCENDANT_PID_MARKER"] = childMarker.path
    environment["GATEWAY_DESCENDANT_READY_MARKER"] = readyMarker.path
    environment["GATEWAY_LEADER_PID_MARKER"] = leaderMarker.path
    let execution = try await runLifecycleGateway(
      scriptURL, environment: environment, grace: 20_000_000, signals: signals
    )

    XCTAssertEqual(execution.exitCode, 0)
    let childPID = try readLifecyclePID(from: childMarker)
    let didTerminateDescendant = await waitForLifecycleCondition {
      !gatewayLifecycleProcessExists(childPID)
    }
    XCTAssertTrue(didTerminateDescendant)
    try assertSignalsUseWitness(signals, gatewayLeaderFrom: leaderMarker)
  }

  private func assertPostReapCleanupResolvesStatus(
    _ statusSequence: LifecycleDescendantStatusSequence,
    expectedSignals: [Int32]
  ) async throws {
    let identifier = UUID().uuidString
    let leaderMarker = lifecycleFixtureURL("gateway-leader-\(identifier)")
    let scriptURL = try makeLifecycleGatewayScript("""
    #!/bin/sh
    echo $$ > "$GATEWAY_LEADER_PID_MARKER"
    cat > /dev/null
    exit 0
    """)
    defer {
      [scriptURL, leaderMarker].forEach { try? FileManager.default.removeItem(at: $0) }
    }
    let signals = GatewayLifecycleSignalRecorder()
    var environment = ProcessInfo.processInfo.environment
    environment["GATEWAY_LEADER_PID_MARKER"] = leaderMarker.path
    let execution = try await runLifecycleGateway(
      scriptURL,
      environment: environment,
      grace: 1_000_000_000,
      signals: signals,
      processGroupDescendantStatusInspector: { _ in statusSequence.next() }
    )
    XCTAssertEqual(execution.exitCode, 0)
    XCTAssertGreaterThanOrEqual(statusSequence.inspectionCount, 2)
    XCTAssertEqual(signals.terminationSignals.map(\.1), expectedSignals)
  }
}

private func runLifecycleGateway(
  _ scriptURL: URL,
  environment: [String: String],
  grace: UInt64,
  signals: GatewayLifecycleSignalRecorder,
  processGroupDescendantStatusInspector: (@Sendable (pid_t) -> ProcessGroupDescendantStatus)? = nil
) async throws -> AgentGatewayCLIInvoker.Execution {
  try await AgentGatewayCLIInvoker.run(
    binary: scriptURL.path, arguments: [], stdin: Data("hello".utf8), environment: environment,
    terminationGraceNanoseconds: grace,
    processGroupDescendantStatusInspector: processGroupDescendantStatusInspector,
    signalObserver: { signals.record(processIdentifier: $0, signal: $1) }
  )
}

private func assertSignalsUseWitness(
  _ signals: GatewayLifecycleSignalRecorder,
  gatewayLeaderFrom marker: URL
) throws {
  let leaderPID = try readLifecyclePID(from: marker)
  XCTAssertFalse(signals.terminationSignals.isEmpty)
  XCTAssertTrue(
    signals.terminationSignals.allSatisfy { $0.0 != -leaderPID },
    "cleanup must use the unreaped process-group witness, not the reaped gateway"
  )
}

private func makeLifecycleGatewayScript(_ script: String) throws -> URL {
  let directory = lifecycleFixtureURL("")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let scriptURL = directory.appendingPathComponent("fake-agent-gateway-\(UUID().uuidString).sh")
  try Data(script.utf8).write(to: scriptURL)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
  return scriptURL
}

private func lifecycleFixtureURL(_ name: String) -> URL {
  URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    .appendingPathComponent("tmp/AppCoreTests", isDirectory: true)
    .appendingPathComponent(name)
}

private func readLifecyclePID(from marker: URL) throws -> pid_t {
  try XCTUnwrap(pid_t(try String(contentsOf: marker).trimmingCharacters(in: .whitespacesAndNewlines)))
}

private final class GatewayLifecycleSignalRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var signals: [(Int32, Int32)] = []
  var terminationSignals: [(Int32, Int32)] { lock.withLock { signals } }
  func record(processIdentifier: Int32, signal: Int32) {
    lock.withLock { signals.append((processIdentifier, signal)) }
  }
}

private final class LifecycleDescendantStatusSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var statuses: [ProcessGroupDescendantStatus]
  private var calls = 0

  init(_ statuses: [ProcessGroupDescendantStatus]) {
    self.statuses = statuses
  }

  var inspectionCount: Int { lock.withLock { calls } }

  func next() -> ProcessGroupDescendantStatus {
    lock.withLock {
      calls += 1
      guard !statuses.isEmpty else { return .none }
      return statuses.removeFirst()
    }
  }
}

private final class GatewayReapPublicationGate: @unchecked Sendable {
  private let lock = NSLock()
  private let release = DispatchSemaphore(value: 0)
  private var didReapLeader = false
  var hasReapedLeader: Bool { lock.withLock { didReapLeader } }
  func pauseAfterReap() { lock.withLock { didReapLeader = true }; release.wait() }
  func releaseCompletionPublication() { release.signal() }
}

private final class GatewayWaitpidPublicationGate: @unchecked Sendable {
  private let lock = NSLock()
  private let release = DispatchSemaphore(value: 0)
  private var returnedFromWaitpid = false
  var didReturnFromWaitpid: Bool { lock.withLock { returnedFromWaitpid } }
  func pauseBeforeReapPublication() { lock.withLock { returnedFromWaitpid = true }; release.wait() }
  func releaseReapPublication() { release.signal() }
}

private func waitForLifecycleCondition(_ condition: @escaping @Sendable () -> Bool) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now + .seconds(2)
  while !condition() {
    guard clock.now < deadline else { return false }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return true
}

private func gatewayLifecycleProcessExists(_ processIdentifier: pid_t) -> Bool {
  kill(processIdentifier, 0) == 0 || errno == EPERM
}
