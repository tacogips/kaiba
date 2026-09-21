import Foundation
@testable import AppCore
import XCTest

final class DocumentGatewayIsolationTests: XCTestCase {
  func testServedImageUsesIsolatedEnvironmentAndStagedPage() throws {
    #if os(macOS)
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let gateway = try script(in: root, body: """
    #!/bin/sh
    [ -d "$HOME" ] || exit 10
    [ -z "$UNRELATED_SECRET" ] || exit 11
    [ "$IMAGE_TEST_KEY" = "fake" ] || exit 12
    found=0
    previous=''
    for argument in "$@"; do
      if [ "$previous" = '--image' ]; then
        found=1
        [ "$argument" -ef "$HOME/page.png" ] || exit 13
        [ "$(/bin/cat "$argument")" = 'test image' ] || exit 14
      fi
      previous="$argument"
    done
    [ "$found" = '1' ] || exit 15
    /bin/cat >/dev/null
    printf '%s\\n' '{"id":3,"jsonrpc":"2.0","result":{"stopReason":"end_turn","_meta":{"agentGateway":{"resultText":"Recognized"}}}}'
    """)
    let image = root.appendingPathComponent("source.png")
    try Data("test image".utf8).write(to: image)
    let converter = AgentGatewayImageOCRConverter(commandPath: gateway.path, vendor: "openai", model: "test",
      apiKeyEnvironment: "IMAGE_TEST_KEY", environment: ["IMAGE_TEST_KEY": "fake", "UNRELATED_SECRET": "must-not-forward"], executionMode: .served)
    XCTAssertEqual(try converter.convert(inputPath: image.path).markdown, "Recognized")
    #else
    throw XCTSkip("served filesystem sandbox requires macOS")
    #endif
  }

  func testServedFailureDoesNotExposeProviderDiagnostics() throws {
    #if os(macOS)
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let gateway = try script(in: root, body: "#!/bin/sh\necho 'private provider diagnostic' >&2\nexit 8\n")
    let image = root.appendingPathComponent("source.png")
    try Data("test image".utf8).write(to: image)
    let converter = AgentGatewayImageOCRConverter(commandPath: gateway.path, vendor: "openai", model: "test",
      apiKeyEnvironment: "IMAGE_TEST_KEY", environment: ["IMAGE_TEST_KEY": "fake"], executionMode: .served)
    XCTAssertThrowsError(try converter.convert(inputPath: image.path)) { error in
      XCTAssertEqual(error as? DocumentConversionError, .failed("agent-gateway image processing failed"))
    }
    #else
    throw XCTSkip("served filesystem sandbox requires macOS")
    #endif
  }

  func testImageGatewayTimeoutUsesSharedProcessCleanup() throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let gateway = try script(in: root, body: "#!/bin/sh\n/bin/sleep 30\n")
    let converter = AgentGatewayImageOCRConverter(commandPath: gateway.path, vendor: "openai", model: "test", timeoutNanoseconds: 100_000_000)
    let start = Date()
    XCTAssertThrowsError(try converter.convert(inputPath: "/unused.png"))
    XCTAssertLessThan(Date().timeIntervalSince(start), 10)
  }

  private func fixtureRoot() throws -> URL {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/image-gateway-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func script(in root: URL, body: String) throws -> URL {
    let path = root.appendingPathComponent("gateway.sh")
    try Data(body.utf8).write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
    return path
  }
}
