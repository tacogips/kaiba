import Foundation
@testable import AppCore
import XCTest

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
}
