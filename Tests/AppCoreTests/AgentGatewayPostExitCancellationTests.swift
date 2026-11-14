import Foundation
@testable import AppCore
import XCTest

#if os(Linux)
import Glibc
#else
import Darwin
#endif

final class AgentGatewayPostExitCancellationTests: XCTestCase {
  func testProductionCancellationAfterLeaderExitWaitsForDescendantCleanup() async throws {
    let childPIDURL = postExitFixtureURL("gateway-child-\(UUID().uuidString).pid")
    let scriptURL = try makeGatewayScript("""
    #!/bin/sh
    cat > /dev/null
    (
      trap '' TERM
      while :; do sleep 0.05; done
    ) &
    echo "$!" > "\(childPIDURL.path)"
    exit 0
    """)
    defer {
      try? FileManager.default.removeItem(at: childPIDURL)
      try? FileManager.default.removeItem(at: scriptURL)
    }

    let signals = GatewayProcessSignalRecorder()
    let task = Task {
      try await AgentGatewayCLIInvoker.run(
        binary: scriptURL.path,
        arguments: [],
        stdin: Data("hello".utf8),
        environment: ProcessInfo.processInfo.environment,
        terminationGraceNanoseconds: 100_000_000,
        signalObserver: { processIdentifier, signal in
          signals.record(processIdentifier: processIdentifier, signal: signal)
        }
      )
    }

    let writtenChildPID = await processIDWritten(to: childPIDURL)
    let childPID = try XCTUnwrap(writtenChildPID)
    defer { _ = kill(childPID, SIGKILL) }
    let didBeginCleanup = await waitForCondition { signals.contains(SIGTERM) }
    XCTAssertTrue(didBeginCleanup)
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("expected cancellation during production post-exit cleanup")
    } catch is CancellationError {
      // Expected: cancellation remains observable after cleanup completes.
    }
    XCTAssertFalse(
      processExists(childPID),
      "CancellationError must not return while the post-exit descendant remains alive"
    )
    XCTAssertTrue(signals.contains(SIGKILL))
  }
}

private func postExitFixtureURL(_ name: String) -> URL {
  URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    .appendingPathComponent("tmp/AppCoreTests", isDirectory: true)
    .appendingPathComponent(name)
}

private func makeGatewayScript(_ script: String) throws -> URL {
  let directory = postExitFixtureURL("")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let scriptURL = directory.appendingPathComponent("fake-agent-gateway-\(UUID().uuidString).sh")
  try Data(script.utf8).write(to: scriptURL)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
  return scriptURL
}

private func processIDWritten(to url: URL) async -> pid_t? {
  guard await waitForCondition({ FileManager.default.fileExists(atPath: url.path) }),
    let text = try? String(contentsOf: url, encoding: .utf8),
    let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
  else {
    return nil
  }
  return pid_t(value)
}

private func waitForCondition(_ condition: @escaping @Sendable () -> Bool) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now + .seconds(1)
  while !condition() {
    guard clock.now < deadline else { return false }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return true
}

private func processExists(_ processIdentifier: pid_t) -> Bool {
  kill(processIdentifier, 0) == 0 || errno == EPERM
}

private final class GatewayProcessSignalRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var signals: [Int32] = []

  func record(processIdentifier _: pid_t, signal: Int32) {
    lock.withLock { signals.append(signal) }
  }

  func contains(_ signal: Int32) -> Bool {
    lock.withLock { signals.contains(signal) }
  }
}
