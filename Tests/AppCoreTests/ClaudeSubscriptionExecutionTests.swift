import Foundation
@testable import AppCore
import XCTest

final class ClaudeSubscriptionExecutionTests: XCTestCase {
  func testLiveClaudeSubscriptionImage() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["KAIBA_TEST_CLAUDE_IMAGE"] else {
      throw XCTSkip("Set KAIBA_TEST_CLAUDE_IMAGE for the authenticated sandbox fixture")
    }
    let gateway = try XCTUnwrap((environment["PATH"] ?? "").split(separator: ":")
      .map { URL(fileURLWithPath: String($0)).appendingPathComponent("agent-gateway").path }
      .first { FileManager.default.isExecutableFile(atPath: $0) })
    var context = try AgentGatewayCLIInvoker.claudeSubscriptionContext(
      binary: gateway, arguments: ["client", "--vendor", "claude-code", "--model", "sonnet", "--prompt", "-"],
      environment: environment
    )
    defer { context.cleanUp() }
    context.arguments += ["--input-format", "stream-json"]
    let result = try await AgentGatewayCLIInvoker.run(
      binary: context.binary, arguments: context.arguments,
      stdin: ClaudeImageInput.encode(prompt: "Return only the visible figure caption.", imageURL: URL(fileURLWithPath: path)),
      environment: context.environment, timeoutNanoseconds: 120_000_000_000, workingDirectory: context.workingDirectory
    )
    let diagnostics = (String(data: result.stderr, encoding: .utf8) ?? "unreadable gateway diagnostic")
      .replacingOccurrences(of: environment["CLAUDE_CODE_OAUTH_TOKEN"] ?? "not-a-token", with: "[redacted]")
    XCTAssertEqual(result.exitCode, 0, diagnostics)
    let parsed = AgentGatewayCLIInvoker.parseACPOutput(result.stdout)
    XCTAssertNil(parsed.errorMessage)
    XCTAssertFalse((parsed.resultText ?? parsed.streamedText).isEmpty)
  }

  func testDocumentClaudeSubscriptionRequiresItsOwnOptIn() throws {
    let provider = KaibaOCRConfiguration(vendor: "claude-code", model: "sonnet")
    for requested in [AgentGatewayExecutionMode.served, .subscription] {
      let disabled = KaibaImportConfiguration(analysis: provider)
      let analyzer = try XCTUnwrap(disabled.makePageAnalyzer(executionMode: requested) as? StructuredDocumentPageAnalyzer)
      XCTAssertEqual((analyzer.converter as? AgentGatewayImageOCRConverter)?.executionMode, .served)
      let enabled = KaibaImportConfiguration(analysis: provider, allowClaudeSubscription: true)
      let enabledAnalyzer = try XCTUnwrap(enabled.makePageAnalyzer(executionMode: requested) as? StructuredDocumentPageAnalyzer)
      XCTAssertEqual((enabledAnalyzer.converter as? AgentGatewayImageOCRConverter)?.executionMode, .subscription)
    }
  }

  func testSubscriptionContextKeepsOnlySelectedTokenAndRestrictedWorkspace() throws {
    #if os(macOS)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let claude = root.appendingPathComponent("claude")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: claude)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: claude.path)
    let environment = ["PATH": root.path, "CLAUDE_CODE_OAUTH_TOKEN": "fake-token", "ANTHROPIC_API_KEY": "unrelated", "HOME": "/private-user-home"]
    let context = try AgentGatewayCLIInvoker.claudeSubscriptionContext(
      binary: "/bin/sh", arguments: ["client"], environment: environment
    )
    defer { context.cleanUp() }
    XCTAssertEqual(context.environment["CLAUDE_CODE_OAUTH_TOKEN"], "fake-token")
    XCTAssertNil(context.environment["ANTHROPIC_API_KEY"])
    XCTAssertNotEqual(context.environment["HOME"], environment["HOME"])
    XCTAssertEqual(context.environment["HOME"], context.workspace?.path)
    XCTAssertEqual(context.binary, "/usr/bin/sandbox-exec")
    XCTAssertTrue(context.arguments.contains("--strict-mcp-config"))
    XCTAssertTrue(context.arguments.contains("--disable-slash-commands"))
    XCTAssertTrue(context.arguments.contains("{\"disableAllHooks\":true}"))
    XCTAssertThrowsError(try AgentGatewayCLIInvoker.validateClaudeSubscription(environment: ["PATH": root.path]))
    #else
    throw XCTSkip("Claude subscription sandbox requires macOS")
    #endif
  }
}
