import Foundation
import XCTest
@testable import AppCore

final class AgentGatewayServedSandboxProfileTests: XCTestCase {
  func testServedContextResolvesSymlinkAndKeepsProfileAndEnvironmentConfined() throws {
    #if os(macOS)
    let fixture = try makeSymlinkedGateway()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let environment = [
      "PROVIDER_TOKEN": "fixture-token",
      "PATH": "/usr/bin:/bin",
      "LANG": "en_US.UTF-8"
    ]

    let context = try AgentGatewayCLIInvoker.executionContext(
      mode: .served,
      vendor: "openrouter",
      binary: fixture.symlink.path,
      arguments: ["client"],
      environment: environment,
      apiKeyEnvironment: "PROVIDER_TOKEN"
    )
    defer { context.cleanUp() }
    let workspace = try XCTUnwrap(context.workspace)

    XCTAssertEqual(context.binary, "/usr/bin/sandbox-exec")
    XCTAssertEqual(context.arguments[0], "-p")
    XCTAssertEqual(context.arguments[2], fixture.real.path)
    let profile = context.arguments[1]
    XCTAssertTrue(profile.hasPrefix("(version 1)\n(deny default)\n"))
    XCTAssertTrue(profile.contains("(import \"system.sb\")"))
    XCTAssertTrue(profile.contains("(literal \"\(fixture.real.path)\")"))
    XCTAssertFalse(profile.contains(fixture.symlink.path))
    XCTAssertFalse(profile.contains("(subpath \"\(fixture.real.deletingLastPathComponent().path)\")"))
    XCTAssertFalse(profile.contains("(subpath \"\(fixture.symlink.deletingLastPathComponent().path)\")"))
    XCTAssertTrue(profile.contains("(subpath \"/private/etc\")"))
    XCTAssertTrue(profile.contains("(allow file-read-metadata)"))
    XCTAssertTrue(profile.contains("(literal \"/private/var/run/resolv.conf\")"))
    for service in [
      "com.apple.trustd",
      "com.apple.SecurityServer",
      "com.apple.SystemConfiguration.configd",
      "com.apple.networkd",
      "com.apple.dnssd.service"
    ] {
      XCTAssertTrue(profile.contains("(global-name \"\(service)\")"), "Missing mach lookup rule for \(service)")
    }
    XCTAssertEqual(profile.components(separatedBy: "(allow file-write*").count - 1, 1)
    XCTAssertTrue(profile.contains("(subpath \"\(workspace.path)\")"))
    XCTAssertTrue(profile.contains("(literal \"/dev/null\")"))

    XCTAssertEqual(Set(context.environment.keys), [
      "HOME", "TMPDIR", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "PROVIDER_TOKEN", "PATH", "LANG"
    ])
    XCTAssertEqual(context.environment["HOME"], workspace.path)
    XCTAssertEqual(context.environment["TMPDIR"], workspace.path)
    XCTAssertTrue(context.environment["XDG_CONFIG_HOME"]?.hasPrefix(workspace.path) == true)
    XCTAssertTrue(context.environment["XDG_CACHE_HOME"]?.hasPrefix(workspace.path) == true)
    XCTAssertNil(context.environment["LC_ALL"])
    #else
    throw XCTSkip("Served filesystem profile is available only on macOS")
    #endif
  }

  func testServedContextRejectsMissingGatewayBinary() throws {
    #if os(macOS)
    let missingBinary = FileManager.default.currentDirectoryPath + "/tmp/AppCoreTests/missing-\(UUID().uuidString)/agent-gateway"
    XCTAssertThrowsError(try AgentGatewayCLIInvoker.executionContext(
      mode: .served,
      vendor: "openrouter",
      binary: missingBinary,
      arguments: ["client"],
      environment: ["PROVIDER_TOKEN": "fixture-token"],
      apiKeyEnvironment: "PROVIDER_TOKEN"
    )) { error in
      guard case AgentInvocationError.unavailable(let message) = error else {
        return XCTFail("Expected unavailable error, got \(error)")
      }
      XCTAssertEqual(message, "server agent-gateway executable is unavailable")
    }
    #else
    throw XCTSkip("Served filesystem profile is available only on macOS")
    #endif
  }

  func testServedInvokerCanRunSymlinkedGateway() async throws {
    #if os(macOS)
    let fixture = try makeSymlinkedGateway()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let invoker = AgentGatewayCLIInvoker(
      commandPath: fixture.symlink.path,
      vendor: "openrouter",
      model: "test-model",
      apiKeyEnvironment: "PROVIDER_TOKEN",
      environment: ["PROVIDER_TOKEN": "fixture-token"],
      executionMode: .served
    )

    let result = try await invoker.invoke(AgentInvocationRequest(
      purpose: .chat,
      systemPrompt: "system",
      turns: [AgentInvocationTurn(role: .user, markdown: "hello")]
    ))

    XCTAssertEqual(result.markdown, "symlinked reply")
    #else
    throw XCTSkip("Served filesystem profile is available only on macOS")
    #endif
  }

  private struct GatewayFixture {
    let root: URL
    let real: URL
    let symlink: URL
  }

  private func makeSymlinkedGateway() throws -> GatewayFixture {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/AppCoreTests/sandbox-\(UUID().uuidString)", isDirectory: true)
    let realDirectory = root.appendingPathComponent("real", isDirectory: true)
    let symlinkDirectory = root.appendingPathComponent("link", isDirectory: true)
    try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: symlinkDirectory, withIntermediateDirectories: true)
    let real = realDirectory.appendingPathComponent("gateway.sh")
    let script = """
    #!/bin/sh
    cat >/dev/null
    printf '%s\\n' '{"id":3,"jsonrpc":"2.0","result":{"stopReason":"end_turn","_meta":{"agentGateway":{"resultText":"symlinked reply"}}}}'
    """
    try Data(script.utf8).write(to: real)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real.path)
    let symlink = symlinkDirectory.appendingPathComponent("agent-gateway")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: real)
    return GatewayFixture(root: root, real: real, symlink: symlink)
  }
}
