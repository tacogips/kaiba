import Foundation
@testable import AppCore
import XCTest

final class DocumentPageAgentChatProviderTests: NoteTestCase {
  func testAnthropicAndOpenAIRequestsCarryImportedPageImageAndRetrievedText() async throws {
    for transport in ["anthropic", "openai"] {
      let fixture = try makeFixture()
      let client = CapturingPageModelClient(transport: transport)
      let runner = UserAgentToolLoopRunner(
        client: client, tools: EmptyPageTools(), model: "test-model", maxToolRounds: 1,
        supportsImageInput: true
      )
      let turn = try fixture.service.appendPendingAgentChatTurn(
        conversationNotebookId: fixture.conversation.notebookId, userMarkdown: "lighthouse", agentAvailable: true
      )
      try await fixture.service.generateAgentChatReply(turnNoteId: turn.noteId, invoker: runner)

      let capturedBody = await client.capturedBody()
      let body = try XCTUnwrap(capturedBody)
      let serialized = try XCTUnwrap(String(bytes: body, encoding: .utf8))
      XCTAssertTrue(serialized.contains(fixture.pageTwo.base64EncodedString()), transport)
      XCTAssertTrue(serialized.contains("Lighthouse maintenance log"), transport)
      XCTAssertTrue(serialized.contains("Page 2 text"), transport)
      XCTAssertEqual(NoteService.chatTurnState(of: try fixture.service.getNote(turn.noteId))?.status, .answered)
    }
  }

  func testGatewayVendorsAndFallbackCompletePageChat() async throws {
    for vendor in ["anthropic", "codex", "claude-code", "cursor"] {
      let fixture = try makeFixture()
      let gateway = try FakePageGateway()
      defer { gateway.remove() }
      let turn = try fixture.service.appendPendingAgentChatTurn(
        conversationNotebookId: fixture.conversation.notebookId, userMarkdown: "lighthouse", agentAvailable: true
      )
      try await fixture.service.generateAgentChatReply(
        turnNoteId: turn.noteId,
        invoker: AgentGatewayCLIInvoker(
          commandPath: gateway.script.path, vendor: vendor, model: "test-model",
          environment: ["ARGUMENTS": gateway.arguments.path, "STDIN_CAPTURE": gateway.stdin.path, "IMAGE_CAPTURE": gateway.image.path]
        )
      )

      let args = try gateway.readArguments()
      let input = try String(contentsOf: gateway.stdin, encoding: .utf8)
      XCTAssertTrue(input.contains("Lighthouse maintenance log"), vendor)
      XCTAssertTrue(input.contains("Page 2 text"), vendor)
      if vendor == "cursor" {
        XCTAssertFalse(args.contains("--image"))
        XCTAssertTrue(input.contains(AgentInvocationRequest.imageFallbackNotice))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gateway.image.path))
      } else if vendor == "claude-code" {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        let message = try XCTUnwrap(json["message"] as? [String: Any])
        let content = try XCTUnwrap(message["content"] as? [[String: Any]])
        let source = try XCTUnwrap(content[0]["source"] as? [String: String])
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(source["data"])), fixture.pageTwo)
      } else {
        XCTAssertEqual(try Data(contentsOf: gateway.image), fixture.pageTwo)
      }
      XCTAssertEqual(NoteService.chatTurnState(of: try fixture.service.getNote(turn.noteId))?.status, .answered)
    }
  }

  func testToolLoopWithoutImageSupportUsesTextFallbackAndAnswers() async throws {
    let fixture = try makeFixture()
    let client = CapturingPageModelClient(transport: "anthropic")
    let runner = UserAgentToolLoopRunner(
      client: client, tools: EmptyPageTools(), model: "test-model", maxToolRounds: 1,
      supportsImageInput: false
    )
    let turn = try fixture.service.appendPendingAgentChatTurn(
      conversationNotebookId: fixture.conversation.notebookId, userMarkdown: "lighthouse", agentAvailable: true
    )
    try await fixture.service.generateAgentChatReply(turnNoteId: turn.noteId, invoker: runner)

    let capturedBody = await client.capturedBody()
    let bodyData = try XCTUnwrap(capturedBody)
    let body = try XCTUnwrap(String(bytes: bodyData, encoding: .utf8))
    XCTAssertFalse(body.contains(fixture.pageTwo.base64EncodedString()))
    XCTAssertTrue(body.contains(AgentInvocationRequest.imageFallbackNotice))
    XCTAssertTrue(body.contains("Lighthouse maintenance log"))
    XCTAssertEqual(NoteService.chatTurnState(of: try fixture.service.getNote(turn.noteId))?.status, .answered)
  }

  private func makeFixture() throws -> PageProviderFixture {
    let service = try makeService()
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
    try Data("synthetic source".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let imported = try service.importDocumentPages(
      at: source.path,
      processor: DocumentPageProcessor(recognizer: ProviderRecognizer(), extractor: ProviderExtractor()),
      maximumOCRPages: 3
    )
    let page = try XCTUnwrap(imported.notes.first { $0.noteNumber == 2 })
    _ = try service.createNote(bodyMarkdown: "Lighthouse maintenance log: beacon service schedule.")
    let conversation = try service.startAgentConversation(subjectNoteId: page.noteId)
    return PageProviderFixture(
      service: service, page: page, pageTwo: Data("synthetic page 2 PNG".utf8),
      conversation: conversation
    )
  }
}

private struct PageProviderFixture {
  var service: NoteService
  var page: Note
  var pageTwo: Data
  var conversation: Notebook
}

private struct ProviderRecognizer: DocumentPageRecognizing {
  func recognize(imageURL: URL) throws -> String {
    let components = try String(contentsOf: imageURL, encoding: .utf8).components(separatedBy: " ")
    let page = components.count > 2 ? components[2] : "?"
    return "Page \(page) text about lighthouse beacons"
  }
}

private struct ProviderExtractor: DocumentImageExtracting {
  func extractImages(fileURL: URL, sourceFormat: String) throws -> DocumentImageExtractionResult {
    DocumentImageExtractionResult(images: (1...3).map { page in
      DocumentExtractedImage(
        pageNumber: page, kind: .pageCapture, data: Data("synthetic page \(page) PNG".utf8),
        mediaType: "image/png", suggestedFilename: "page-\(page).png"
      )
    }, pageTexts: ["", "", ""])
  }
}

private actor CapturingPageModelClient: ToolLoopModelClient {
  let transport: String
  private(set) var body: Data?
  init(transport: String) { self.transport = transport }

  func complete(
    _ request: ToolLoopModelRequest,
    onTextDelta: @escaping @Sendable (String) -> Bool
  ) async throws -> ToolLoopModelTurn {
    body = try transport == "anthropic"
      ? AnthropicMessagesToolLoopClient.requestBody(request)
      : OpenAIChatCompletionsToolLoopClient.requestBody(request)
    return ToolLoopModelTurn(text: "Answered", toolCalls: [], stopReason: .endTurn)
  }

  func capturedBody() -> Data? { body }
}

private struct EmptyPageTools: AgentToolExecuting {
  var definitions: [AgentToolDefinition] { [] }
  func execute(_ call: AgentToolCall) async -> AgentToolResult { AgentToolResult(callId: call.id, content: "") }
}

private struct FakePageGateway {
  var root: URL
  var script: URL
  var arguments: URL
  var stdin: URL
  var image: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    script = root.appendingPathComponent("gateway.sh")
    arguments = root.appendingPathComponent("arguments")
    stdin = root.appendingPathComponent("stdin")
    image = root.appendingPathComponent("image")
    try Data("""
    #!/bin/sh
    printf '%s\\n' "$@" > "$ARGUMENTS"
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--image" ]; then shift; /bin/cp "$1" "$IMAGE_CAPTURE"; fi
      shift
    done
    /bin/cat > "$STDIN_CAPTURE"
    printf '%s\\n' '{"id":3,"jsonrpc":"2.0","result":{"stopReason":"end_turn","_meta":{"agentGateway":{"resultText":"Answered"}}}}'
    """.utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
  }

  func readArguments() throws -> [String] {
    let values = try String(contentsOf: arguments, encoding: .utf8).components(separatedBy: "\n")
    return values.last == "" ? Array(values.dropLast()) : values
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}
