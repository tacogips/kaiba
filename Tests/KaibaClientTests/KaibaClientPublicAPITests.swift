import Foundation
import Testing
import KaibaClient

@Suite("Kaiba client public API")
struct KaibaClientPublicAPITests {
  @Test func endpointDoesNotPublishRawURLMembers() throws {
    let targetInfo = try JSONDecoder().decode(
      SwiftTargetInfo.self,
      from: try runXcrun(["swift", "-print-target-info"])
    )
    guard let sdkPath = String(
      bytes: try runXcrun(["--sdk", "macosx", "--show-sdk-path"]),
      encoding: .utf8
    )?.trimmingCharacters(in: .whitespacesAndNewlines) else {
      throw PublicAPITestError.invalidUTF8(tool: "xcrun")
    }
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let modules = repositoryRoot
      .appendingPathComponent(".build")
      .appendingPathComponent(targetInfo.target.unversionedTriple)
      .appendingPathComponent("debug/Modules")
    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("kaiba-public-api-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: output) }

    _ = try runXcrun([
      "swift-symbolgraph-extract",
      "-module-name", "KaibaClient",
      "-I", modules.path,
      "-output-dir", output.path,
      "-target", targetInfo.target.triple,
      "-sdk", sdkPath,
      "-minimum-access-level", "public",
      "-skip-synthesized-members"
    ])
    let graph = try JSONDecoder().decode(
      SymbolGraph.self,
      from: Data(contentsOf: output.appendingPathComponent("KaibaClient.symbols.json"))
    )
    let endpointMembers = graph.symbols
      .map(\.pathComponents)
      .filter { $0.first == "KaibaEndpoint" }

    #expect(endpointMembers.contains(["KaibaEndpoint", "isLoopback"]))
    #expect(!endpointMembers.contains(["KaibaEndpoint", "url"]))
    #expect(!endpointMembers.contains(["KaibaEndpoint", "transportURL"]))
  }

  private func runXcrun(_ arguments: [String]) throws -> Data {
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    let stdout = output.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
      let stderr = errors.fileHandleForReading.readDataToEndOfFile()
      throw PublicAPITestError.commandFailed(
        tool: "xcrun",
        status: process.terminationStatus,
        diagnostic: String(bytes: stderr, encoding: .utf8) ?? "<non-UTF-8 diagnostics>"
      )
    }
    return stdout
  }
}

private struct SwiftTargetInfo: Decodable {
  struct Target: Decodable {
    let triple: String
    let unversionedTriple: String
  }

  let target: Target
}

private struct SymbolGraph: Decodable {
  struct Symbol: Decodable {
    let pathComponents: [String]
  }

  let symbols: [Symbol]
}

private enum PublicAPITestError: Error {
  case commandFailed(tool: String, status: Int32, diagnostic: String)
  case invalidUTF8(tool: String)
}
