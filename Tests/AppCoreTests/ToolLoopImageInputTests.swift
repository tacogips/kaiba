import Foundation
@testable import AppCore
import XCTest

final class ToolLoopImageInputTests: XCTestCase {
  private let image = AgentInvocationImage(data: Data([0x89, 0x50, 0x4E, 0x47]), mediaType: "image/png")

  private var baseRequest: ToolLoopModelRequest {
    ToolLoopModelRequest(
      model: "test-model",
      systemPrompt: "system",
      messages: [
        .user("earlier question"),
        .assistant(text: "earlier answer", toolCalls: []),
        .user("current question")
      ],
      tools: []
    )
  }

  func testAnthropicAddsBase64BeforeTextAndPreservesCacheControl() throws {
    var request = baseRequest
    request.images = [image]
    request.imageMessageIndex = 2

    let body = try json(AnthropicMessagesToolLoopClient.requestBody(request))
    let messages = try XCTUnwrap(body["messages"]?.asArray)
    let earlierContent = try XCTUnwrap(messages[0]["content"]?.asArray)
    XCTAssertEqual(earlierContent.count, 1)
    XCTAssertEqual(earlierContent[0]["type"]?.asString, "text")

    let currentContent = try XCTUnwrap(messages[2]["content"]?.asArray)
    XCTAssertEqual(currentContent.count, 2)
    XCTAssertEqual(currentContent[0]["type"]?.asString, "image")
    XCTAssertEqual(currentContent[0]["source"]?["type"]?.asString, "base64")
    XCTAssertEqual(currentContent[0]["source"]?["media_type"]?.asString, "image/png")
    XCTAssertEqual(currentContent[0]["source"]?["data"]?.asString, image.data.base64EncodedString())
    XCTAssertEqual(currentContent[1]["type"]?.asString, "text")
    XCTAssertNotNil(currentContent[1]["cache_control"])
  }

  func testOpenAIAddsTextThenImageOnlyAtIndexedUserMessage() throws {
    var request = baseRequest
    request.images = [image]
    request.imageMessageIndex = 2

    let body = try json(OpenAIChatCompletionsToolLoopClient.requestBody(request))
    let messages = try XCTUnwrap(body["messages"]?.asArray)
    XCTAssertEqual(messages[1]["content"]?.asString, "earlier question")
    let currentContent = try XCTUnwrap(messages[3]["content"]?.asArray)
    XCTAssertEqual(currentContent.count, 2)
    XCTAssertEqual(currentContent[0]["type"]?.asString, "text")
    XCTAssertEqual(currentContent[0]["text"]?.asString, "current question")
    XCTAssertEqual(currentContent[1]["type"]?.asString, "image_url")
    XCTAssertEqual(
      currentContent[1]["image_url"]?["url"]?.asString,
      "data:image/png;base64,\(image.data.base64EncodedString())"
    )
  }

  func testRequestsWithoutImagesAreByteIdenticalToDefaultRequest() throws {
    var explicitEmpty = baseRequest
    explicitEmpty.images = []
    explicitEmpty.imageMessageIndex = nil
    XCTAssertEqual(
      try AnthropicMessagesToolLoopClient.requestBody(baseRequest),
      try AnthropicMessagesToolLoopClient.requestBody(explicitEmpty)
    )
    XCTAssertEqual(
      try OpenAIChatCompletionsToolLoopClient.requestBody(baseRequest),
      try OpenAIChatCompletionsToolLoopClient.requestBody(explicitEmpty)
    )
  }

  func testRunnerCarriesImagesAndMessageIndexAcrossToolRounds() async throws {
    let toolCall = AgentToolCall(id: "call-1", name: "search_notes", input: .object([:]))
    let client = CapturingModelClient([
      ToolLoopModelTurn(text: "Searching", toolCalls: [toolCall], stopReason: .toolUse),
      ToolLoopModelTurn(text: "Answer", toolCalls: [], stopReason: .endTurn)
    ])
    let runner = UserAgentToolLoopRunner(
      client: client,
      tools: ImageTestTools(),
      model: "test-model",
      maxToolRounds: 2,
      supportsImageInput: true
    )

    _ = try await runner.invoke(invocationRequest())

    let requests = client.capturedRequests
    XCTAssertEqual(requests.count, 2)
    for request in requests {
      XCTAssertEqual(request.images, [image])
      XCTAssertEqual(request.imageMessageIndex, 2)
      XCTAssertTrue(request.systemPrompt.contains("RAG chunk lighthouse"))
      guard let index = request.imageMessageIndex else { return XCTFail("image index missing") }
      guard case .user = request.messages[index] else { return XCTFail("image index must point to user") }
    }
  }

  func testUnsupportedRunnerDropsImagesAndAddsNoticeToPrompt() async throws {
    let client = CapturingModelClient([ToolLoopModelTurn(text: "Answer", toolCalls: [], stopReason: .endTurn)])
    let runner = UserAgentToolLoopRunner(
      client: client,
      tools: ImageTestTools(),
      model: "test-model",
      maxToolRounds: 1
    )

    _ = try await runner.invoke(invocationRequest())

    let request = try XCTUnwrap(client.capturedRequests.first)
    XCTAssertTrue(request.images.isEmpty)
    XCTAssertNil(request.imageMessageIndex)
    XCTAssertTrue(request.systemPrompt.contains(AgentInvocationRequest.imageFallbackNotice))
    XCTAssertTrue(request.systemPrompt.contains("RAG chunk lighthouse"))
  }

  func testRuntimeImageCapabilityMatchesProviderMatrix() {
    XCTAssertTrue(UserAgentRuntimeFactory.supportsImageInput(for: .anthropic))
    XCTAssertTrue(UserAgentRuntimeFactory.supportsImageInput(for: .openai))
    XCTAssertTrue(UserAgentRuntimeFactory.supportsImageInput(for: .openrouter))
    XCTAssertFalse(UserAgentRuntimeFactory.supportsImageInput(for: .openaiCompatible))
    XCTAssertFalse(UserAgentRuntimeFactory.supportsImageInput(for: .codex))
  }

  private func invocationRequest() -> AgentInvocationRequest {
    AgentInvocationRequest(
      purpose: .chat,
      systemPrompt: "helpful",
      turns: [
        AgentInvocationTurn(role: .user, markdown: "first"),
        AgentInvocationTurn(role: .assistant, markdown: "response"),
        AgentInvocationTurn(role: .user, markdown: "current")
      ],
      contextMarkdown: "RAG chunk lighthouse",
      images: [image]
    )
  }

  private func json(_ data: Data) throws -> JSONValue {
    guard let text = String(data: data, encoding: .utf8) else {
      throw ToolLoopModelClientError.malformedResponse("request body was not UTF-8")
    }
    return try JSONValue(parsing: text)
  }
}

private final class CapturingModelClient: ToolLoopModelClient, @unchecked Sendable {
  private let lock = NSLock()
  private var turns: [ToolLoopModelTurn]
  private var requests: [ToolLoopModelRequest] = []

  init(_ turns: [ToolLoopModelTurn]) {
    self.turns = turns
  }

  var capturedRequests: [ToolLoopModelRequest] {
    lock.withLock { requests }
  }

  func complete(
    _ request: ToolLoopModelRequest,
    onTextDelta: @escaping @Sendable (String) -> Bool
  ) async throws -> ToolLoopModelTurn {
    lock.withLock {
      requests.append(request)
      return turns.isEmpty ? ToolLoopModelTurn(text: "", toolCalls: [], stopReason: .endTurn) : turns.removeFirst()
    }
  }
}

private struct ImageTestTools: AgentToolExecuting {
  let definitions = [AgentToolDefinition(
    name: "search_notes",
    description: "Search notes",
    inputSchema: .object(["type": .string("object")])
  )]

  func execute(_ call: AgentToolCall) async -> AgentToolResult {
    AgentToolResult(callId: call.id, content: "[]")
  }
}
