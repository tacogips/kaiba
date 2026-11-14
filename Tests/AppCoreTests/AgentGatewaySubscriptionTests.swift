import Foundation
import XCTest
@testable import AppCore

final class AgentGatewaySubscriptionTests: XCTestCase {
  func testSubscriptionRequiresChatGPTAuthenticationAndRejectsOtherVendors() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("codex")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let environment = ["PATH": directory.path, "CODEX_HOME": directory.path]
    XCTAssertThrowsError(try AgentGatewayCLIInvoker.validateSubscriptionRequirements(vendor: "openai", environment: environment))
    try Data(#"{"auth_mode":"apikey","OPENAI_API_KEY":"fake"}"#.utf8).write(to: directory.appendingPathComponent("auth.json"))
    XCTAssertThrowsError(try AgentGatewayCLIInvoker.validateSubscriptionRequirements(vendor: "codex", environment: environment))
    #if os(macOS)
    try Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"fixture"}}"#.utf8).write(to: directory.appendingPathComponent("auth.json"))
    let context = try AgentGatewayCLIInvoker.subscriptionExecutionContext(
      vendor: "codex", binary: "/usr/bin/true", arguments: ["client", "--vendor", "codex"], environment: environment
    )
    defer { context.cleanUp() }
    XCTAssertEqual(context.binary, "/usr/bin/sandbox-exec")
    XCTAssertNotEqual(context.environment["CODEX_HOME"], directory.path)
    XCTAssertNil(context.environment["OPENAI_API_KEY"])
    XCTAssertTrue(context.arguments.contains("features.shell_tool=false"))
    XCTAssertTrue(context.arguments.contains("--ignore-user-config"))
    XCTAssertTrue(context.arguments.contains("--ignore-rules"))
    XCTAssertTrue(context.arguments.contains("read-only"))
    let home = try XCTUnwrap(context.environment["CODEX_HOME"])
    XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/auth.json"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/config.toml"))
    let sentinel = directory.appendingPathComponent("server-secret")
    try Data("must remain outside the sandbox".utf8).write(to: sentinel)
    let check = try await AgentGatewayCLIInvoker.run(
      binary: context.binary,
      arguments: Array(context.arguments.prefix(2)) + ["/bin/sh", "-c",
        "touch \"$CODEX_HOME/check\" || exit 8; /bin/cat \"$1\" >/dev/null 2>&1 && exit 9; echo isolated", "check", sentinel.path],
      stdin: Data(), environment: context.environment, workingDirectory: context.workingDirectory
    )
    XCTAssertEqual(check.exitCode, 0)
    XCTAssertEqual(String(data: check.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), "isolated")
    #endif
  }

  func testSelectedProviderDoesNotFallBackAfterCredentialChanges() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let base = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: directory.path))
    let user = try base.createUser(email: "runtime@example.com", displayName: "Runtime")
    let scoped = base.scoped(to: user.userId)
    let dispatcher = KaibaAutoActionDispatcher(
      service: base, invoker: UnavailableAgentInvoker(),
      userAgentRuntime: UserAgentRuntimeFactory(configuration: .init(allowCodexSubscription: true))
    )
    try scoped.setUserAgentCredential(.init(provider: .codex, apiKey: "", defaultModel: "model"))
    XCTAssertTrue(try dispatcher.resolveChatRuntime(for: scoped, selectedProvider: "codex").usesPersonalRuntime)
    XCTAssertFalse(try dispatcher.resolveChatRuntime(for: scoped, selectedProvider: "server").usesPersonalRuntime)
    try scoped.clearUserAgentCredential()
    XCTAssertThrowsError(try dispatcher.resolveChatRuntime(for: scoped, selectedProvider: "codex"))
    XCTAssertFalse(try dispatcher.resolveChatRuntime(for: scoped, selectedProvider: "server").usesPersonalRuntime)
  }

  func testLiveSubscriptionReply() async throws {
    guard ProcessInfo.processInfo.environment["KAIBA_LIVE_SUBSCRIPTION_TEST"] == "1" else {
      throw XCTSkip("Set KAIBA_LIVE_SUBSCRIPTION_TEST=1 to verify the server's real Codex login")
    }
    let model = ProcessInfo.processInfo.environment["KAIBA_LIVE_SUBSCRIPTION_MODEL"] ?? "gpt-5.6-luna"
    let invoker = AgentGatewayCLIInvoker(vendor: "codex", model: model, executionMode: .subscription)
    let result = try await invoker.invoke(.init(
      purpose: .chat, systemPrompt: "Answer briefly without using tools.",
      turns: [.init(role: .user, markdown: "Reply with exactly: kaiba subscription ready")], allowsTools: false
    ))
    XCTAssertTrue(result.markdown.lowercased().contains("kaiba subscription ready"))
  }
}
