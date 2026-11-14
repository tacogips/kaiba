import Foundation
@testable import AppCore
import XCTest

#if os(Linux)
import Glibc
#else
import Darwin
#endif

final class AgentGatewayCLIInvokerTests: NoteTestCase {
  func testFlattenedPromptWithContextAndHistory() {
    let request = AgentInvocationRequest(
      purpose: .chat,
      systemPrompt: "system",
      turns: [
        AgentInvocationTurn(role: .user, markdown: "First question"),
        AgentInvocationTurn(role: .assistant, markdown: "First answer"),
        AgentInvocationTurn(role: .user, markdown: "Second question")
      ],
      contextMarkdown: "# Doc\nBody."
    )
    let prompt = AgentGatewayCLIInvoker.flattenedPrompt(request)
    XCTAssertTrue(prompt.hasPrefix("<document>\n# Doc\nBody.\n</document>"))
    XCTAssertTrue(prompt.contains("Conversation so far:"))
    XCTAssertTrue(prompt.contains("User:\nFirst question"))
    XCTAssertTrue(prompt.contains("Assistant:\nFirst answer"))
    XCTAssertTrue(prompt.hasSuffix("User:\nSecond question"))
  }

  func testFlattenedPromptSingleTurnIsBareMessage() {
    let request = AgentInvocationRequest(
      purpose: .tagExtraction,
      systemPrompt: "system",
      turns: [AgentInvocationTurn(role: .user, markdown: "Only message")]
    )
    XCTAssertEqual(AgentGatewayCLIInvoker.flattenedPrompt(request), "Only message")
  }

  func testParseACPOutputPrefersResultText() {
    let jsonl = """
    {"id":2,"jsonrpc":"2.0","result":{"sessionId":"sess-1"}}
    {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hel"}}}}
    {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"lo"}}}}
    {"id":3,"jsonrpc":"2.0","result":{"stopReason":"end_turn","_meta":{"agentGateway":{"vendor":"openrouter","model":"m","resultText":"Hello there"}}}}
    """
    let parsed = AgentGatewayCLIInvoker.parseACPOutput(Data(jsonl.utf8))
    XCTAssertEqual(parsed.resultText, "Hello there")
    XCTAssertEqual(parsed.streamedText, "Hello")
    XCTAssertNil(parsed.errorMessage)
  }

  func testParseACPOutputSurfacesJSONRPCError() {
    let jsonl = """
    {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"partial"}}}}
    {"error":{"code":-32002,"message":"vendor exited with status 1"},"id":3,"jsonrpc":"2.0"}
    """
    let parsed = AgentGatewayCLIInvoker.parseACPOutput(Data(jsonl.utf8))
    XCTAssertEqual(parsed.errorMessage, "agent error -32002: vendor exited with status 1")
    XCTAssertEqual(parsed.streamedText, "partial")
    XCTAssertNil(parsed.resultText)
  }

  func testParseACPOutputIgnoresGarbageLines() {
    let parsed = AgentGatewayCLIInvoker.parseACPOutput(Data("not json\n\n{}".utf8))
    XCTAssertEqual(parsed, AgentGatewayCLIInvoker.ParsedACPOutput())
  }

  func testFactoryBuildsInvokerWhenBinaryAndSettingsPresent() {
    let configuration = KaibaAIConfiguration(
      agent: KaibaAgentBackendConfiguration(
        backend: "agent-gateway-cli",
        commandPath: "/bin/echo",
        provider: "openrouter",
        model: "openai/gpt-5-mini"
      )
    )
    XCTAssertNotNil(AgentInvokerFactory.makeInvoker(configuration: configuration))
    XCTAssertTrue(
      AgentInvokerFactory.describeAvailability(configuration: configuration)
        .contains("agent-gateway ready")
    )
  }

  func testFactoryReturnsNilWithoutModelOrBinary() {
    let missingModel = KaibaAIConfiguration(
      agent: KaibaAgentBackendConfiguration(
        backend: "agent-gateway-cli",
        commandPath: "/bin/echo",
        provider: "openrouter"
      )
    )
    XCTAssertNil(AgentInvokerFactory.makeInvoker(configuration: missingModel))
    XCTAssertTrue(
      AgentInvokerFactory.describeAvailability(configuration: missingModel)
        .contains("ai.agent.model")
    )

    let missingBinary = KaibaAIConfiguration(
      agent: KaibaAgentBackendConfiguration(
        backend: "agent-gateway-cli",
        commandPath: "/nonexistent/agent-gateway",
        provider: "openrouter",
        model: "m"
      )
    )
    XCTAssertNil(AgentInvokerFactory.makeInvoker(configuration: missingBinary))
    XCTAssertTrue(
      AgentInvokerFactory.describeAvailability(configuration: missingBinary)
        .contains("not found")
    )
  }

  func testServedFactoryRejectsUnavailableGatewayConfigurationBeforeReconciliation() {
    let codingVendor = KaibaAIConfiguration(
      agent: KaibaAgentBackendConfiguration(
        backend: "agent-gateway-cli",
        commandPath: "/bin/echo",
        provider: "codex",
        model: "test-model",
        apiKeyEnvironmentVariable: "PROVIDER_TOKEN"
      )
    )
    XCTAssertNil(AgentInvokerFactory.makeInvoker(
      configuration: codingVendor,
      environment: ["PROVIDER_TOKEN": "selected-provider-secret"],
      executionMode: .served
    ))
    XCTAssertTrue(AgentInvokerFactory.describeAvailability(
      configuration: codingVendor,
      environment: ["PROVIDER_TOKEN": "selected-provider-secret"],
      executionMode: .served
    ).contains("tool-capable vendor codex"))

    let missingCredential = KaibaAIConfiguration(
      agent: KaibaAgentBackendConfiguration(
        backend: "agent-gateway-cli",
        commandPath: "/bin/echo",
        provider: "openrouter",
        model: "test-model"
      )
    )
    XCTAssertNil(AgentInvokerFactory.makeInvoker(
      configuration: missingCredential,
      environment: [:],
      executionMode: .served
    ))
    XCTAssertTrue(AgentInvokerFactory.describeAvailability(
      configuration: missingCredential,
      environment: [:],
      executionMode: .served
    ).contains("apiKeyEnvironmentVariable"))
  }

  #if os(Linux)
  func testServedFactoryFailsClosedWithoutMacOSSandboxSupport() {
    let configuration = KaibaAIConfiguration(
      agent: KaibaAgentBackendConfiguration(
        backend: "agent-gateway-cli",
        commandPath: "/bin/echo",
        provider: "openrouter",
        model: "test-model",
        apiKeyEnvironmentVariable: "PROVIDER_TOKEN"
      )
    )

    XCTAssertNil(AgentInvokerFactory.makeInvoker(
      configuration: configuration,
      environment: ["PROVIDER_TOKEN": "selected-provider-secret"],
      executionMode: .served
    ))
    XCTAssertTrue(AgentInvokerFactory.describeAvailability(
      configuration: configuration,
      environment: ["PROVIDER_TOKEN": "selected-provider-secret"],
      executionMode: .served
    ).contains("requires macOS sandbox-exec"))
  }
  #endif

  func testServedUnavailableConfigurationForceDisablesReconciledAutoActions() throws {
    let configuration = KaibaAIConfiguration(
      agent: KaibaAgentBackendConfiguration(
        backend: "agent-gateway-cli",
        commandPath: "/bin/echo",
        provider: "codex",
        model: "test-model",
        apiKeyEnvironmentVariable: "PROVIDER_TOKEN"
      ),
      autoTag: KaibaAutoTagConfiguration(auto: .on)
    )
    let environment = ["PROVIDER_TOKEN": "selected-provider-secret"]
    let available = AgentInvokerFactory.makeInvoker(
      configuration: configuration,
      environment: environment,
      executionMode: .served
    ) != nil
    let service = try NoteService(driver: makeNoteDriver())

    let lines = try AIAutoActionReconciliation.reconcile(
      service: service,
      aiConfiguration: configuration,
      invokerAvailable: available,
      environment: environment,
      executionMode: .served
    )

    XCTAssertFalse(available)
    XCTAssertFalse(try service.listAutoActions().contains(where: \.enabled))
    XCTAssertTrue(lines.contains(where: { $0.contains("tool-capable vendor codex") }))
  }

  func testInvokerRunsFakeGatewayScript() async throws {
    // A stand-in gateway that echoes a fixed ACP response, proving the
    // spawn -> stdin -> JSONL parse pipeline without a real model.
    let script = """
    #!/bin/sh
    cat > /dev/null
    echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ok"}}}}'
    echo '{"id":3,"jsonrpc":"2.0","result":{"stopReason":"end_turn","_meta":{"agentGateway":{"resultText":"scripted reply"}}}}'
    """
    let directory = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath,
      isDirectory: true
    ).appendingPathComponent("tmp/AppCoreTests", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let scriptURL = directory.appendingPathComponent("fake-agent-gateway-\(UUID().uuidString).sh")
    try Data(script.utf8).write(to: scriptURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: scriptURL.path
    )
    defer { try? FileManager.default.removeItem(at: scriptURL) }

    let invoker = AgentGatewayCLIInvoker(
      commandPath: scriptURL.path,
      vendor: "openrouter",
      model: "test-model"
    )
    let result = try await invoker.invoke(AgentInvocationRequest(
      purpose: .chat,
      systemPrompt: "system",
      turns: [AgentInvocationTurn(role: .user, markdown: "hello")]
    ))
    XCTAssertEqual(result.markdown, "scripted reply")
  }

  func testServedInvokerUsesIsolatedWorkspaceAndAllowlistedEnvironment() async throws {
    let sentinelURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("kaiba-server-sentinel-\(UUID().uuidString)")
    try Data("unrelated-file-secret".utf8).write(to: sentinelURL)
    let siblingSentinelURL = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath,
      isDirectory: true
    ).appendingPathComponent("tmp/AppCoreTests/gateway-sidecar-\(UUID().uuidString)")
    try Data("gateway-neighbor-secret".utf8).write(to: siblingSentinelURL)
    defer {
      if FileManager.default.fileExists(atPath: sentinelURL.path) {
        try? FileManager.default.removeItem(at: sentinelURL)
      }
      if FileManager.default.fileExists(atPath: siblingSentinelURL.path) {
        try? FileManager.default.removeItem(at: siblingSentinelURL)
      }
    }
    let inheritedWorkspace = FileManager.default.currentDirectoryPath
    let scriptURL = try makeExecutableGatewayScript("""
    #!/bin/sh
    if [ -n "${UNRELATED_SERVER_SECRET:-}" ]; then
      echo 'unrelated secret leaked' >&2
      exit 10
    fi
    if [ "$PROVIDER_TOKEN" != 'selected-provider-secret' ]; then
      echo 'selected provider credential missing' >&2
      exit 11
    fi
    if [ "$PWD" = "\(inheritedWorkspace)" ]; then
      echo 'inherited server workspace leaked' >&2
      exit 12
    fi
    if [ "$(cat "\(sentinelURL.path)" 2>/dev/null)" = 'unrelated-file-secret' ]; then
      echo 'external file read leaked' >&2
      exit 13
    fi
    if [ "$(cat "\(siblingSentinelURL.path)" 2>/dev/null)" = 'gateway-neighbor-secret' ]; then
      echo 'gateway-neighbor read leaked' >&2
      exit 15
    fi
    if touch "\(sentinelURL.path)" 2>/dev/null; then
      echo 'sandbox allowed external mutation' >&2
      exit 14
    fi
    cat > /dev/null
    echo '{"id":3,"jsonrpc":"2.0","result":{"stopReason":"end_turn","_meta":{"agentGateway":{"resultText":"isolated reply"}}}}'
    """)
    defer { try? FileManager.default.removeItem(at: scriptURL) }
    var environment = ProcessInfo.processInfo.environment
    environment["PROVIDER_TOKEN"] = "selected-provider-secret"
    environment["UNRELATED_SERVER_SECRET"] = "must-not-reach-gateway"

    let result = try await AgentGatewayCLIInvoker(
      commandPath: scriptURL.path,
      vendor: "openrouter",
      model: "test-model",
      apiKeyEnvironment: "PROVIDER_TOKEN",
      environment: environment,
      executionMode: .served
    ).invoke(AgentInvocationRequest(
      purpose: .chat,
      systemPrompt: "system",
      turns: [AgentInvocationTurn(role: .user, markdown: "hello")]
    ))

    XCTAssertEqual(result.markdown, "isolated reply")
    XCTAssertEqual(try String(contentsOf: sentinelURL, encoding: .utf8), "unrelated-file-secret")
    XCTAssertEqual(try String(contentsOf: siblingSentinelURL, encoding: .utf8), "gateway-neighbor-secret")
  }

  func testServedInvokerRejectsToolCapableVendorBeforeLaunchingGateway() async throws {
    let invoker = AgentGatewayCLIInvoker(
      commandPath: "/bin/echo",
      vendor: "codex",
      model: "test-model",
      apiKeyEnvironment: "PROVIDER_TOKEN",
      environment: ["PROVIDER_TOKEN": "selected-provider-secret"],
      executionMode: .served
    )

    do {
      _ = try await invoker.invoke(AgentInvocationRequest(
        purpose: .chat,
        systemPrompt: "system",
        turns: [AgentInvocationTurn(role: .user, markdown: "hello")]
      ))
      XCTFail("expected served coding-agent vendor to be rejected")
    } catch AgentInvocationError.unavailable(let message) {
      XCTAssertEqual(message, "server agent-gateway is unavailable")
    }
  }

  func testServedInvokerSuppressesGatewayCredentialDiagnostics() async throws {
    let scriptURL = try makeExecutableGatewayScript("""
    #!/bin/sh
    echo "gateway stderr: $PROVIDER_TOKEN" >&2
    exit 1
    """)
    defer { try? FileManager.default.removeItem(at: scriptURL) }

    let credential = "served-diagnostic-secret"
    do {
      _ = try await AgentGatewayCLIInvoker(
        commandPath: scriptURL.path,
        vendor: "openrouter",
        model: "test-model",
        apiKeyEnvironment: "PROVIDER_TOKEN",
        environment: ["PROVIDER_TOKEN": credential],
        executionMode: .served
      ).invoke(AgentInvocationRequest(
        purpose: .chat,
        systemPrompt: "system",
        turns: [AgentInvocationTurn(role: .user, markdown: "hello")]
      ))
      XCTFail("expected gateway failure")
    } catch AgentInvocationError.failed(let message) {
      XCTAssertFalse(message.contains(credential))
      XCTAssertEqual(message, "agent-gateway produced no reply (exit 1)")
    }
  }

  func testServedInvokerSuppressesACPCredentialDiagnostics() async throws {
    let scriptURL = try makeExecutableGatewayScript("""
    #!/bin/sh
    cat > /dev/null
    echo "{\\"jsonrpc\\":\\"2.0\\",\\"error\\":{\\"code\\":-32000,\\"message\\":\\"$PROVIDER_TOKEN\\"}}"
    """)
    defer { try? FileManager.default.removeItem(at: scriptURL) }

    let credential = "served-acp-secret"
    do {
      _ = try await AgentGatewayCLIInvoker(
        commandPath: scriptURL.path,
        vendor: "openrouter",
        model: "test-model",
        apiKeyEnvironment: "PROVIDER_TOKEN",
        environment: ["PROVIDER_TOKEN": credential],
        executionMode: .served
      ).invoke(AgentInvocationRequest(
        purpose: .chat,
        systemPrompt: "system",
        turns: [AgentInvocationTurn(role: .user, markdown: "hello")]
      ))
      XCTFail("expected ACP gateway failure")
    } catch AgentInvocationError.failed(let message) {
      XCTAssertFalse(message.contains(credential))
      XCTAssertEqual(message, "agent-gateway request failed")
    }
  }

  func testInvokerFailsBeforeRetainingUnboundedGatewayStdout() async throws {
    let scriptURL = try makeExecutableGatewayScript("""
    #!/bin/sh
    cat > /dev/null
    i=0
    while [ "$i" -lt 1200 ]; do
      head -c 300 /dev/zero | tr '\\0' x
      printf '\\n'
      i=$((i + 1))
    done
    """)
    defer { try? FileManager.default.removeItem(at: scriptURL) }

    do {
      _ = try await AgentGatewayCLIInvoker(
        commandPath: scriptURL.path,
        vendor: "openrouter",
        model: "test-model"
      ).invoke(AgentInvocationRequest(
        purpose: .chat,
        systemPrompt: "system",
        turns: [AgentInvocationTurn(role: .user, markdown: "hello")]
      ))
      XCTFail("expected the process output limit to reject oversized stdout")
    } catch AgentInvocationError.failed(let message) {
      XCTAssertTrue(message.contains("256 KiB process limit"))
    }
  }

  func testInvokerTimesOutWhenGatewayNeverReadsPrompt() async throws {
    let scriptURL = try makeExecutableGatewayScript("""
    #!/bin/sh
    trap '' TERM
    while :; do sleep 1; done
    """)
    defer { try? FileManager.default.removeItem(at: scriptURL) }

    let invoker = AgentGatewayCLIInvoker(
      commandPath: scriptURL.path,
      vendor: "openrouter",
      model: "test-model",
      invocationTimeoutNanoseconds: 30_000_000,
      terminationGraceNanoseconds: 30_000_000
    )
    let clock = ContinuousClock()
    let started = clock.now
    do {
      _ = try await invoker.invoke(AgentInvocationRequest(
        purpose: .chat,
        systemPrompt: "system",
        turns: [AgentInvocationTurn(role: .user, markdown: String(repeating: "x", count: 512 * 1024))]
      ))
      XCTFail("expected the blocked stdin write to time out")
    } catch AgentInvocationError.failed(let message) {
      XCTAssertEqual(message, "agent-gateway invocation timed out")
    }
    XCTAssertLessThan(clock.now - started, .seconds(2))
  }

  func testInvokerForceKillsGatewayThatIgnoresSIGTERM() async throws {
    let scriptURL = try makeExecutableGatewayScript("""
    #!/bin/sh
    trap '' TERM
    cat > /dev/null
    while :; do sleep 60; done
    """)
    defer { try? FileManager.default.removeItem(at: scriptURL) }

    let invoker = AgentGatewayCLIInvoker(
      commandPath: scriptURL.path,
      vendor: "openrouter",
      model: "test-model",
      invocationTimeoutNanoseconds: 30_000_000,
      terminationGraceNanoseconds: 30_000_000
    )
    let clock = ContinuousClock()
    let started = clock.now
    do {
      _ = try await invoker.invoke(AgentInvocationRequest(
        purpose: .chat,
        systemPrompt: "system",
        turns: [AgentInvocationTurn(role: .user, markdown: "hello")]
      ))
      XCTFail("expected the SIGTERM-ignoring gateway to time out")
    } catch AgentInvocationError.failed(let message) {
      XCTAssertEqual(message, "agent-gateway invocation timed out")
    }
    XCTAssertLessThan(clock.now - started, .milliseconds(500))
  }

  func testInvokerForceKillsGatewayDescendants() async throws {
    let childPIDURL = temporaryGatewayPath(suffix: ".pid")
    defer { try? FileManager.default.removeItem(at: childPIDURL) }
    let scriptURL = try makeExecutableGatewayScript("""
    #!/bin/sh
    cat > /dev/null
    (
      trap '' TERM
      while :; do sleep 1; done
    ) &
    echo "$!" > "\(childPIDURL.path)"
    while :; do sleep 1; done
    """)
    defer { try? FileManager.default.removeItem(at: scriptURL) }

    let invoker = AgentGatewayCLIInvoker(
      commandPath: scriptURL.path,
      vendor: "openrouter",
      model: "test-model",
      terminationGraceNanoseconds: 30_000_000
    )
    let task = Task {
      try await invoker.invoke(AgentInvocationRequest(
        purpose: .chat,
        systemPrompt: "system",
        turns: [AgentInvocationTurn(role: .user, markdown: "hello")]
      ))
    }

    let writtenChildPID = await Self.processIDWritten(to: childPIDURL)
    let childPID = try XCTUnwrap(writtenChildPID)
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("expected cancellation to terminate the gateway process group")
    } catch is CancellationError {
      // Expected: cancellation reaches the gateway process group.
    }
    let descendantExited = await Self.waitForCondition(timeout: .seconds(1)) {
      !Self.processExists(childPID)
    }
    XCTAssertTrue(
      descendantExited,
      "gateway descendant \(childPID) survived forced group termination"
    )
  }

  func testInvokerCleansDescendantHoldingOutputAfterGatewayExits() async throws {
    let childPIDURL = temporaryGatewayPath(suffix: ".pid")
    defer { try? FileManager.default.removeItem(at: childPIDURL) }
    let scriptURL = try makeExecutableGatewayScript("""
    #!/bin/sh
    cat > /dev/null
    printf '%s\\n' '{"id":3,"jsonrpc":"2.0","result":{"stopReason":"end_turn","_meta":{"agentGateway":{"resultText":"gateway reply"}}}}'
    (
      trap '' TERM
      while :; do sleep 1; done
    ) &
    echo "$!" > "\(childPIDURL.path)"
    sleep 0.05
    exit 0
    """)
    defer { try? FileManager.default.removeItem(at: scriptURL) }

    let invoker = AgentGatewayCLIInvoker(
      commandPath: scriptURL.path,
      vendor: "openrouter",
      model: "test-model",
      terminationGraceNanoseconds: 30_000_000
    )
    let task = Task {
      try await invoker.invoke(AgentInvocationRequest(
        purpose: .chat,
        systemPrompt: "system",
        turns: [AgentInvocationTurn(role: .user, markdown: "hello")]
      ))
    }

    let writtenChildPID = await Self.processIDWritten(to: childPIDURL)
    let childPID = try XCTUnwrap(writtenChildPID)
    defer { _ = kill(childPID, SIGKILL) }
    let completed = await Self.taskCompleted(task, within: .milliseconds(500))
    if !completed {
      _ = kill(childPID, SIGKILL)
      task.cancel()
      _ = try? await task.value
      XCTFail("gateway output collection blocked on a descendant-held descriptor")
      return
    }

    let result = try await task.value
    XCTAssertEqual(result.markdown, "gateway reply")
    let descendantExited = await Self.waitForCondition(timeout: .seconds(1)) {
      !Self.processExists(childPID)
    }
    XCTAssertTrue(
      descendantExited,
      "gateway descendant \(childPID) survived normal gateway-exit cleanup"
    )
  }

  func testInvokerCancellationDuringPostExitDescendantCleanupThrowsCancellationError() async throws {
    let childPIDURL = temporaryGatewayPath(suffix: ".pid")
    defer {
      try? FileManager.default.removeItem(at: childPIDURL)
    }
    let scriptURL = try makeExecutableGatewayScript("""
    #!/bin/sh
    cat > /dev/null
    printf '%s\\n' '{"id":3,"jsonrpc":"2.0","result":{"stopReason":"end_turn","_meta":{"agentGateway":{"resultText":"gateway reply"}}}}'
    (
      trap '' TERM
      while :; do sleep 0.05; done
    ) &
    echo "$!" > "\(childPIDURL.path)"
    exit 0
    """)
    defer { try? FileManager.default.removeItem(at: scriptURL) }

    let cleanupPacer = ManualProcessGroupCleanupPacer()
    let task = Task {
      try await AgentGatewayCLIInvoker.run(
        binary: scriptURL.path,
        arguments: [],
        stdin: Data("hello".utf8),
        environment: ProcessInfo.processInfo.environment,
        terminationGraceNanoseconds: 1_000_000_000,
        processGroupPollIntervalWaiter: { await cleanupPacer.wait() }
      )
    }

    let writtenChildPID = await Self.processIDWritten(to: childPIDURL)
    let childPID = try XCTUnwrap(writtenChildPID)
    defer { _ = kill(childPID, SIGKILL) }
    let cleanupStarted = await cleanupPacer.waitForFirstWait()
    guard cleanupStarted else {
      task.cancel()
      _ = try? await task.value
      XCTFail("gateway did not begin post-child process-group cleanup")
      return
    }

    let clock = ContinuousClock()
    let started = clock.now
    task.cancel()
    let schedulerProbe = Task { true }
    let schedulerRemainedResponsive = await schedulerProbe.value
    XCTAssertTrue(schedulerRemainedResponsive)
    let pacedWaitCount = await cleanupPacer.waitCount
    XCTAssertEqual(
      pacedWaitCount,
      1,
      "cancelled cleanup must remain suspended at its paced process-group poll"
    )
    await cleanupPacer.releaseFirstWait()
    do {
      _ = try await task.value
      XCTFail("expected cancellation during descendant cleanup")
    } catch is CancellationError {
      // Expected: cancellation remains observable after direct-child exit.
    }
    XCTAssertLessThan(clock.now - started, .seconds(2))
    let descendantExited = await Self.waitForCondition(timeout: .seconds(1)) {
      !Self.processExists(childPID)
    }
    XCTAssertTrue(
      descendantExited,
      "gateway descendant \(childPID) survived cancellation during cleanup"
    )
  }

  func testInvokerCancellationTerminatesBlockedGateway() async throws {
    let readyURL = temporaryGatewayPath(suffix: ".ready")
    defer { try? FileManager.default.removeItem(at: readyURL) }
    let scriptURL = try makeExecutableGatewayScript("""
    #!/bin/sh
    : > "\(readyURL.path)"
    trap '' TERM
    while :; do sleep 1; done
    """)
    defer { try? FileManager.default.removeItem(at: scriptURL) }

    let invoker = AgentGatewayCLIInvoker(
      commandPath: scriptURL.path,
      vendor: "openrouter",
      model: "test-model",
      terminationGraceNanoseconds: 30_000_000
    )
    let task = Task {
      try await invoker.invoke(AgentInvocationRequest(
        purpose: .chat,
        systemPrompt: "system",
        turns: [AgentInvocationTurn(role: .user, markdown: String(repeating: "x", count: 512 * 1024))]
      ))
    }
    let didStart = await Self.waitForCondition(timeout: .seconds(5)) {
      FileManager.default.fileExists(atPath: readyURL.path)
    }
    guard didStart else {
      task.cancel()
      _ = try? await task.value
      XCTFail("gateway did not reach its cancellation readiness marker")
      return
    }

    let clock = ContinuousClock()
    let started = clock.now
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("expected cancellation to terminate the blocked gateway")
    } catch is CancellationError {
      // Expected: cancellation closes stdin and terminates the process group.
    }
    XCTAssertLessThan(clock.now - started, .milliseconds(500))
  }

  func testModelCatalogRunsGatewayModelsCommandAndDecodesResult() async throws {
    let script = """
    #!/bin/sh
    if [ "$1" != "models" ] || [ "$2" != "--vendor" ] || [ "$3" != "openrouter" ] || [ "$4" != "--api-key-environment" ] || [ "$5" != "ROUTER_TOKEN" ]; then
      echo 'unexpected arguments' >&2
      exit 9
    fi
    echo '{"protocolVersion":"1.0","vendor":"openrouter","models":[{"modelId":"openai/gpt-5-mini","name":"GPT-5 mini","description":"Fast model"}]}'
    """
    let scriptURL = try makeExecutableGatewayScript(script)
    defer { try? FileManager.default.removeItem(at: scriptURL) }

    let result = try await AgentGatewayCLIModelCatalog(
      commandPath: scriptURL.path,
      vendor: "openrouter",
      apiKeyEnvironment: "ROUTER_TOKEN"
    ).models()

    XCTAssertEqual(result.protocolVersion, "1.0")
    XCTAssertEqual(result.vendor, "openrouter")
    XCTAssertEqual(result.models, [AgentGatewayModelInfo(
      modelId: "openai/gpt-5-mini",
      name: "GPT-5 mini",
      description: "Fast model"
    )])
  }

  func testModelCatalogSurfacesGatewayFailure() async throws {
    let scriptURL = try makeExecutableGatewayScript("""
    #!/bin/sh
    echo 'model listing failed (-32020): codex does not support model enumeration' >&2
    exit 1
    """)
    defer { try? FileManager.default.removeItem(at: scriptURL) }

    do {
      _ = try await AgentGatewayCLIModelCatalog(
        commandPath: scriptURL.path,
        vendor: "codex"
      ).models()
      XCTFail("expected model listing to fail")
    } catch AgentInvocationError.failed(let message) {
      XCTAssertEqual(
        message,
        "model listing failed (-32020): codex does not support model enumeration"
      )
    }
  }

  func testServedModelCatalogSuppressesGatewayCredentialDiagnostic() async throws {
    let credential = "served-catalog-secret"
    let scriptURL = try makeExecutableGatewayScript("""
    #!/bin/sh
    echo "catalog error: $PROVIDER_TOKEN" >&2
    exit 1
    """)
    defer { try? FileManager.default.removeItem(at: scriptURL) }

    do {
      _ = try await AgentGatewayCLIModelCatalog(
        commandPath: scriptURL.path,
        vendor: "openrouter",
        apiKeyEnvironment: "PROVIDER_TOKEN",
        environment: ["PROVIDER_TOKEN": credential],
        executionMode: .served
      ).models()
      XCTFail("expected model listing to fail")
    } catch AgentInvocationError.failed(let message) {
      XCTAssertFalse(message.contains(credential))
      XCTAssertEqual(message, "agent-gateway model listing exited with status 1")
    }
  }

  func testModelCatalogRejectsPreCatalogGatewayOutput() async throws {
    let scriptURL = try makeExecutableGatewayScript("""
    #!/bin/sh
    echo 'Usage: agent-gateway <command> [options]'
    """)
    defer { try? FileManager.default.removeItem(at: scriptURL) }

    do {
      _ = try await AgentGatewayCLIModelCatalog(
        commandPath: scriptURL.path,
        vendor: "openai"
      ).models()
      XCTFail("expected invalid catalog output to fail")
    } catch AgentInvocationError.failed(let message) {
      XCTAssertTrue(message.contains("version 0.1.2 or newer"))
    }
  }

  private func makeExecutableGatewayScript(_ script: String) throws -> URL {
    let directory = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath,
      isDirectory: true
    ).appendingPathComponent("tmp/AppCoreTests", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let scriptURL = directory.appendingPathComponent("fake-agent-gateway-\(UUID().uuidString).sh")
    try Data(script.utf8).write(to: scriptURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: scriptURL.path
    )
    return scriptURL
  }

  private func temporaryGatewayPath(suffix: String) -> URL {
    URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath,
      isDirectory: true
    )
    .appendingPathComponent("tmp/AppCoreTests", isDirectory: true)
    .appendingPathComponent("fake-agent-gateway-\(UUID().uuidString)\(suffix)")
  }

  private static func processIDWritten(to url: URL) async -> pid_t? {
    guard await waitForCondition(timeout: .seconds(1), condition: {
      FileManager.default.fileExists(atPath: url.path)
    }), let text = try? String(contentsOf: url, encoding: .utf8), let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    else {
      return nil
    }
    return pid_t(value)
  }

  private static func taskCompleted(
    _ task: Task<AgentInvocationResult, Error>,
    within timeout: Duration
  ) async -> Bool {
    let completion = TaskCompletionProbe()
    Task {
      _ = try? await task.value
      completion.markComplete()
    }
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !completion.isComplete {
      guard clock.now < deadline else { return false }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return true
  }

  private static func waitForCondition(
    timeout: Duration,
    condition: @escaping @Sendable () -> Bool
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
      guard clock.now < deadline else { return false }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return true
  }

  private static func processExists(_ processIdentifier: pid_t) -> Bool {
    kill(processIdentifier, 0) == 0 || errno == EPERM
  }
}

private final class TaskCompletionProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var completed = false

  var isComplete: Bool {
    lock.lock()
    defer { lock.unlock() }
    return completed
  }

  func markComplete() {
    lock.lock()
    completed = true
    lock.unlock()
  }
}

private actor ManualProcessGroupCleanupPacer {
  private var firstWaitContinuation: CheckedContinuation<Void, Never>?
  private var firstWaitObservers: [CheckedContinuation<Void, Never>] = []
  private(set) var waitCount = 0

  func wait() async {
    waitCount += 1
    guard waitCount == 1 else {
      await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).asyncAfter(
          deadline: .now() + .milliseconds(10)
        ) {
          continuation.resume()
        }
      }
      return
    }
    await withCheckedContinuation { continuation in
      firstWaitContinuation = continuation
      let observers = firstWaitObservers
      firstWaitObservers.removeAll()
      observers.forEach { $0.resume() }
    }
  }

  func waitForFirstWait() async -> Bool {
    if firstWaitContinuation != nil {
      return true
    }
    await withCheckedContinuation { continuation in
      firstWaitObservers.append(continuation)
    }
    return true
  }

  func releaseFirstWait() {
    let continuation = firstWaitContinuation
    firstWaitContinuation = nil
    continuation?.resume()
  }
}
