import Foundation
@testable import AppCore
import XCTest

final class AgentGatewayImageTransportTests: XCTestCase {
  func testLocalAnthropicTransportsImageAndRemovesTemporaryFile() async throws {
    let fixture = try FakeGateway()
    defer { fixture.remove() }
    let image = AgentInvocationImage(data: Data([1, 2, 3]), mediaType: "image/png")

    _ = try await fixture.invoke(vendor: "anthropic", images: [image])

    let arguments = try fixture.arguments()
    let imageIndex = try XCTUnwrap(arguments.firstIndex(of: "--image"))
    let imagePath = try XCTUnwrap(arguments.dropFirst(imageIndex + 1).first)
    XCTAssertLessThan(imageIndex, arguments.firstIndex(of: "--") ?? arguments.count)
    XCTAssertEqual(try Data(contentsOf: fixture.imageCapture), image.data)
    XCTAssertFalse(FileManager.default.fileExists(atPath: imagePath))
    XCTAssertTrue(try String(contentsOf: fixture.stdin, encoding: .utf8).contains("RAG chunk lighthouse"))
  }

  func testLocalCodexUsesVendorArgumentsAndPlainPrompt() async throws {
    let fixture = try FakeGateway()
    defer { fixture.remove() }
    let image = AgentInvocationImage(data: Data([4, 5]), mediaType: "image/png")

    _ = try await fixture.invoke(vendor: "codex", images: [image])

    let arguments = try fixture.arguments()
    XCTAssertEqual(Array(arguments.suffix(3).prefix(2)), ["--", "--image"])
    XCTAssertEqual(try Data(contentsOf: fixture.imageCapture), image.data)
    XCTAssertTrue(try String(contentsOf: fixture.stdin, encoding: .utf8).contains("RAG chunk lighthouse"))
  }

  func testLocalClaudeCodeUsesImageStreamJSON() async throws {
    let fixture = try FakeGateway()
    defer { fixture.remove() }
    let image = AgentInvocationImage(data: Data([6, 7, 8]), mediaType: "image/png")

    _ = try await fixture.invoke(vendor: "claude-code", images: [image])

    let arguments = try fixture.arguments()
    let separator = try XCTUnwrap(arguments.firstIndex(of: "--"))
    XCTAssertEqual(Array(arguments.dropFirst(separator + 1)), ClaudeImageInput.arguments)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.stdin)) as? [String: Any])
    let message = try XCTUnwrap(payload["message"] as? [String: Any])
    let content = try XCTUnwrap(message["content"] as? [[String: Any]])
    let source = try XCTUnwrap(content[0]["source"] as? [String: String])
    XCTAssertEqual(source["type"], "base64")
    XCTAssertEqual(source["media_type"], "image/png")
    XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(source["data"])), image.data)
    XCTAssertTrue(try XCTUnwrap(content[1]["text"] as? String).contains("RAG chunk lighthouse"))
  }

  func testUnsupportedVendorDropsImageWithNotice() async throws {
    let fixture = try FakeGateway()
    defer { fixture.remove() }
    let image = AgentInvocationImage(data: Data([9]), mediaType: "image/png")

    _ = try await fixture.invoke(vendor: "cursor", images: [image])

    let arguments = try fixture.arguments()
    XCTAssertFalse(arguments.contains("--image"))
    XCTAssertFalse(arguments.contains("stream-json"))
    XCTAssertFalse(arguments.contains("--"))
    let prompt = try String(contentsOf: fixture.stdin, encoding: .utf8)
    XCTAssertTrue(prompt.contains(AgentInvocationRequest.imageFallbackNotice))
    XCTAssertTrue(prompt.contains("RAG chunk lighthouse"))
  }

  func testRequestsWithoutImagesKeepTextOnlyArgumentsAndStdin() async throws {
    for vendor in ["anthropic", "codex", "claude-code", "cursor"] {
      let fixture = try FakeGateway()
      defer { fixture.remove() }

      _ = try await fixture.invoke(vendor: vendor, images: [])

      let arguments = try fixture.arguments()
      XCTAssertEqual(arguments, [
        "client", "--vendor", vendor, "--model", "test-model", "--prompt", "-"
      ], vendor)
      XCTAssertFalse(arguments.contains("--image"), vendor)
      XCTAssertFalse(arguments.contains("stream-json"), vendor)
      XCTAssertFalse(arguments.contains("--"), vendor)
      let expected = AgentGatewayCLIInvoker.flattenedPrompt(fixture.request(images: []))
      XCTAssertEqual(try Data(contentsOf: fixture.stdin), Data(expected.utf8), vendor)
    }
  }

  func testServedContextStagesImageAndClaudeUsesStreamInputFormat() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source", isDirectory: true)
    let workspace = root.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let imageURL = source.appendingPathComponent("page.png")
    let bytes = Data([10, 11])
    try bytes.write(to: imageURL)
    var context = AgentGatewayExecutionContext(
      binary: "gateway", arguments: ["client"], environment: [:],
      workingDirectory: workspace, workspace: workspace
    )

    try AgentGatewayImageTransport.applyPostContext(
      vendor: "openai", mode: .served, imageURL: imageURL, context: &context
    )

    let stagedImage = workspace.appendingPathComponent("page.png")
    XCTAssertEqual(Array(context.arguments.suffix(2)), ["--image", stagedImage.path])
    XCTAssertEqual(try Data(contentsOf: stagedImage), bytes)
    var claudeContext = AgentGatewayExecutionContext(
      binary: "gateway", arguments: ["client"], environment: [:], workingDirectory: nil, workspace: nil
    )
    try AgentGatewayImageTransport.applyPostContext(
      vendor: "claude-code", mode: .served, imageURL: imageURL, context: &claudeContext
    )
    XCTAssertEqual(Array(claudeContext.arguments.suffix(2)), ["--input-format", "stream-json"])
  }

  func testServedImageRequiresWorkspaceAndVendorSetMatchesOCR() throws {
    let imageURL = URL(fileURLWithPath: "/tmp/page.png")
    var context = AgentGatewayExecutionContext(
      binary: "gateway", arguments: [], environment: [:], workingDirectory: nil, workspace: nil
    )
    XCTAssertThrowsError(try AgentGatewayImageTransport.applyPostContext(
      vendor: "openai", mode: .served, imageURL: imageURL, context: &context
    )) { error in
      XCTAssertEqual(error as? AgentInvocationError, .failed("image workspace unavailable"))
    }
    XCTAssertEqual(
      AgentGatewayImageTransport.imageCapableVendors,
      AgentGatewayImageOCRConverter.supportedVendors
    )
  }

  private struct FakeGateway {
    let root: URL
    let script: URL
    let argumentsFile: URL
    let stdin: URL
    let imageCapture: URL

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      script = root.appendingPathComponent("gateway.sh")
      argumentsFile = root.appendingPathComponent("arguments")
      stdin = root.appendingPathComponent("stdin")
      imageCapture = root.appendingPathComponent("image-capture")
      try Data("""
      #!/bin/sh
      printf '%s\\n' "$@" > "$ARGUMENTS"
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "--image" ]; then shift; /bin/cp "$1" "$IMAGE_CAPTURE"; fi
        shift
      done
      /bin/cat > "$STDIN"
      printf '%s\\n' '{"id":3,"jsonrpc":"2.0","result":{"stopReason":"end_turn","_meta":{"agentGateway":{"resultText":"reply"}}}}'
      """.utf8).write(to: script)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    }

    func invoke(vendor: String, images: [AgentInvocationImage]) async throws -> AgentInvocationResult {
      let invoker = AgentGatewayCLIInvoker(
        commandPath: script.path,
        vendor: vendor,
        model: "test-model",
        environment: [
          "ARGUMENTS": argumentsFile.path,
          "STDIN": stdin.path,
          "IMAGE_CAPTURE": imageCapture.path
        ]
      )
      return try await invoker.invoke(request(images: images))
    }

    func request(images: [AgentInvocationImage]) -> AgentInvocationRequest {
      AgentInvocationRequest(
        purpose: .chat,
        systemPrompt: "",
        turns: [AgentInvocationTurn(role: .user, markdown: "question")],
        contextMarkdown: "RAG chunk lighthouse",
        images: images
      )
    }

    func arguments() throws -> [String] {
      var values = try String(contentsOf: argumentsFile, encoding: .utf8).components(separatedBy: "\n")
      if values.last == "" { values.removeLast() }
      return values
    }

    func remove() {
      try? FileManager.default.removeItem(at: root)
    }
  }
}
