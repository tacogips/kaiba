import Foundation
@testable import AppCore
import XCTest

final class AgentGatewayPublicDiagnosticTests: NoteTestCase {
  func testServedNoReplyDiagnosticClassifiesSandboxStartWithoutLeakingStderr() {
    let diagnostic = AgentGatewayCLIInvoker.servedNoReplyDiagnostic(
      exitCode: 71,
      stderr: Data("sandbox-exec: execvp() of '/srv/example/agent-gateway' failed: Operation not permitted\n".utf8)
    )
    XCTAssertEqual(diagnostic, "agent-gateway could not start inside the server sandbox (exit 71)")
    XCTAssertFalse(diagnostic.contains("/srv/example"))
    XCTAssertFalse(diagnostic.contains("Operation"))
    XCTAssertEqual(
      AgentGatewayCLIInvoker.servedNoReplyDiagnostic(exitCode: 3, stderr: Data(" \n sandbox-exec: denied".utf8)),
      "agent-gateway could not start inside the server sandbox (exit 3)"
    )
  }

  func testServedNoReplyDiagnosticKeepsGenericReasonForOtherStderr() {
    XCTAssertEqual(
      AgentGatewayCLIInvoker.servedNoReplyDiagnostic(exitCode: 1, stderr: Data("gateway stderr: FIXTURE-secret".utf8)),
      "agent-gateway produced no reply (exit 1)"
    )
    XCTAssertEqual(
      AgentGatewayCLIInvoker.servedNoReplyDiagnostic(exitCode: 0, stderr: Data()),
      "agent-gateway produced no reply (exit 0)"
    )
  }

  func testPublicDiagnosticPassesOnlyPinnedReasonsAndNumericTemplates() {
    let reasons = [
      "agent-gateway request failed",
      "agent-gateway produced no reply (exit 0)",
      "agent-gateway produced no reply (exit 1)",
      "agent-gateway produced no reply (exit 71)",
      "agent-gateway produced no reply (exit -9)",
      "agent-gateway could not start inside the server sandbox (exit 0)",
      "agent-gateway could not start inside the server sandbox (exit 1)",
      "agent-gateway could not start inside the server sandbox (exit 71)",
      "agent-gateway could not start inside the server sandbox (exit -9)",
      "agent-gateway exited with status 0",
      "agent-gateway exited with status 1",
      "agent-gateway exited with status 71",
      "agent-gateway exited with status -9",
      "agent-gateway invocation timed out",
      "agent-gateway output exceeds the 256 KiB process limit",
      "agent reply exceeds the 256 KiB or 256-chunk output limit",
      "server agent-gateway is unavailable"
    ]
    for reason in reasons {
      XCTAssertEqual(AgentInvocationError.failed(reason).publicDiagnostic, reason)
    }
    XCTAssertEqual(AgentInvocationError.notConfigured.publicDiagnostic, "agent runtime is not configured")
    XCTAssertEqual(AgentInvocationError.unavailable("binary missing: /srv/example/x").publicDiagnostic,
                   "agent runtime is unavailable")
    XCTAssertEqual(AgentInvocationError.unavailable("server agent-gateway is unavailable").publicDiagnostic,
                   "agent runtime is unavailable")
  }

  func testPublicDiagnosticRejectsUnknownAndMalformedMessages() {
    let rejected = [
      "agent-gateway produced no reply (exit 1): FIXTURE-secret",
      "agent-gateway produced no reply (exit x)",
      "agent-gateway produced no reply (exit 12345678901)",
      "provider-key-FIXTURE-secret",
      "/opt/example/bin/agent-gateway failed",
      "agent-gateway request failed "
    ]
    for message in rejected {
      XCTAssertEqual(AgentInvocationError.failed(message).publicDiagnostic, "agent request failed")
    }
  }

  #if os(macOS)
  func testServedInvokerClassifiesSandboxExecStderrPrefix() async throws {
    let script = try makeExecutableGatewayScript()
    defer { try? FileManager.default.removeItem(at: script) }
    let invoker = AgentGatewayCLIInvoker(
      commandPath: script.path,
      vendor: "openrouter",
      model: "test-model",
      apiKeyEnvironment: "PROVIDER_TOKEN",
      environment: ["PROVIDER_TOKEN": "FIXTURE-token"],
      executionMode: .served
    )
    do {
      _ = try await invoker.invoke(AgentInvocationRequest(
        purpose: .search,
        systemPrompt: "system",
        turns: [AgentInvocationTurn(role: .user, markdown: "query")]
      ))
      XCTFail("expected fake gateway launch to fail")
    } catch let error as AgentInvocationError {
      guard case .failed(let message) = error else {
        XCTFail("expected failed error, got a different AgentInvocationError case")
        return
      }
      let expectedPattern = "^agent-gateway could not start inside the server sandbox \\(exit -?[0-9]+\\)$"
      XCTAssertNotNil(message.range(of: expectedPattern, options: .regularExpression))
      XCTAssertEqual(AgentInvocationError.failed(message).publicDiagnostic, message)
      XCTAssertFalse(message.contains(script.path))
      XCTAssertFalse(message.contains(script.lastPathComponent))
      XCTAssertFalse(message.contains("execvp"))
      XCTAssertFalse(message.contains("No such file"))
      XCTAssertFalse(message.contains("Operation not permitted"))
    } catch {
      XCTFail("expected AgentInvocationError")
    }
  }
  #endif

  private func makeExecutableGatewayScript() throws -> URL {
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/AppCoreTests", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let missingInterpreter = directory.appendingPathComponent("missing-interpreter-\(UUID().uuidString)")
    let scriptURL = directory.appendingPathComponent("diagnostic-gateway-\(UUID().uuidString).sh")
    try Data("#!\(missingInterpreter.path)\nexit 0\n".utf8).write(to: scriptURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    return scriptURL
  }
}
