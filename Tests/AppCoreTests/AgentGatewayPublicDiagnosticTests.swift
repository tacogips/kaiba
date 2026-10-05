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
      "/home/example/bin/agent-gateway failed",
      "agent-gateway request failed "
    ]
    for message in rejected {
      XCTAssertEqual(AgentInvocationError.failed(message).publicDiagnostic, "agent request failed")
    }
  }

  #if os(macOS)
  func testServedInvokerClassifiesSandboxExecStderrPrefix() async throws {
    let script = try makeExecutableGatewayScript("#!/bin/sh\necho 'sandbox-exec: fake failure' >&2\nexit 3\n")
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
      XCTFail("expected fake gateway to produce no reply")
    } catch let error as AgentInvocationError {
      XCTAssertEqual(error, .failed("agent-gateway could not start inside the server sandbox (exit 3)"))
    }
  }
  #endif

  private func makeExecutableGatewayScript(_ script: String) throws -> URL {
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/AppCoreTests", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let scriptURL = directory.appendingPathComponent("diagnostic-gateway-\(UUID().uuidString).sh")
    try Data(script.utf8).write(to: scriptURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    return scriptURL
  }
}
