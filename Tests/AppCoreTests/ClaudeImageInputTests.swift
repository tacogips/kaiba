import Foundation
@testable import AppCore
import XCTest

final class ClaudeImageInputTests: XCTestCase {
  func testGatewayReceivesClaudeStreamInputAndRestrictedArguments() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let imageURL = root.appendingPathComponent("page with spaces.jpg")
    let bytes = Data([0xff, 0xd8, 0xff, 0x00])
    try bytes.write(to: imageURL)
    let capture = root.appendingPathComponent("stdin.json")
    let arguments = root.appendingPathComponent("args.jsonl")
    let script = root.appendingPathComponent("gateway.sh")
    try Data("""
    #!/bin/sh
    printf '%s\\n' "$@" > "$ARGUMENTS"
    /bin/cat > "$CAPTURE"
    printf '%s\\n' '{"id":3,"jsonrpc":"2.0","result":{"stopReason":"end_turn","_meta":{"agentGateway":{"resultText":"Recognized page"}}}}'
    """.utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let prompt = "Read the \"image\".\nPreserve Japanese: 日本語"
    let converter = AgentGatewayImageOCRConverter(
      commandPath: script.path, vendor: "claude-code", model: "test-model",
      environment: ["CAPTURE": capture.path, "ARGUMENTS": arguments.path], prompt: prompt
    )
    XCTAssertEqual(try converter.convert(inputPath: imageURL.path).markdown, "Recognized page")
    let args = try String(contentsOf: arguments, encoding: .utf8).components(separatedBy: "\n")
    XCTAssertEqual(Array(args.prefix(8)), ["client", "--vendor", "claude-code", "--model", "test-model", "--prompt", "-", "--"])
    XCTAssertEqual(Array(args.dropFirst(8).dropLast()), ClaudeImageInput.arguments)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: capture)) as? [String: Any])
    let message = try XCTUnwrap(payload["message"] as? [String: Any])
    let content = try XCTUnwrap(message["content"] as? [[String: Any]])
    let source = try XCTUnwrap(content[0]["source"] as? [String: String])
    XCTAssertEqual(source["media_type"], "image/jpeg")
    XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(source["data"])), bytes)
    XCTAssertEqual(content[1]["text"] as? String, prompt)
    XCTAssertFalse(args.contains("--image"))
  }

  func testRejectsEmptyAndUnsupportedImages() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let empty = root.appendingPathComponent("empty.png")
    try Data().write(to: empty)
    XCTAssertThrowsError(try ClaudeImageInput.encode(prompt: "Read", imageURL: empty))
    let unsupported = root.appendingPathComponent("image.svg")
    try Data("image".utf8).write(to: unsupported)
    XCTAssertThrowsError(try ClaudeImageInput.encode(prompt: "Read", imageURL: unsupported))
  }

  func testDataEncoderMatchesURLEncoderAndRejectsUnsupportedMediaType() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x00])
    let imageURL = root.appendingPathComponent("page.png")
    try bytes.write(to: imageURL)

    XCTAssertEqual(
      try ClaudeImageInput.encode(prompt: "RAG text", imageData: bytes, mediaType: "image/png"),
      try ClaudeImageInput.encode(prompt: "RAG text", imageURL: imageURL)
    )
    XCTAssertThrowsError(
      try ClaudeImageInput.encode(prompt: "RAG text", imageData: bytes, mediaType: "image/tiff")
    )
  }
}
