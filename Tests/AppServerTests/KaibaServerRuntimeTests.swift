import Foundation
import XCTest

import AppCore
@testable import AppServer

/// The shared serve bootstrap used by `kaiba serve` and the menu-bar app
/// (`design-docs/specs/macos-menu-bar-app.md`).
final class KaibaServerRuntimeTests: XCTestCase {

  func testConfigurationDefaultsAreLoopbackAndAuthenticated() {
    let config = KaibaServeConfiguration(noteRoot: "/tmp/does-not-matter")
    XCTAssertEqual(config.host, "127.0.0.1")
    XCTAssertEqual(config.port, 8787)
    XCTAssertFalse(config.allowUnauthenticated)
    XCTAssertFalse(config.unauthenticatedActsAsAdmin)
  }

  func testStartBringsUpAnAuthenticatedServerAndStopTearsItDown() async throws {
    let noteRoot = try makeNoteRoot()
    // A high, uncommon loopback port to avoid colliding with a real server.
    let runtime = KaibaServerRuntime(KaibaServeConfiguration(
      host: "127.0.0.1",
      port: 8796,
      noteRoot: noteRoot
    ))

    let info = try await runtime.start()
    let running = await runtime.isRunning
    XCTAssertTrue(running)
    XCTAssertEqual(info.endpoint, "http://127.0.0.1:8796")
    guard case let .authenticated(registrationURL, qrText) = info.authMode else {
      return XCTFail("default runtime must require authentication")
    }
    XCTAssertTrue(registrationURL.hasPrefix("http://127.0.0.1:8796/note/register?code="))
    XCTAssertFalse(qrText.isEmpty)

    // The unauthenticated /healthz route answers over the real socket.
    let (data, response) = try await URLSession.shared.data(
      from: URL(string: "\(info.endpoint)/healthz")!
    )
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertFalse(data.isEmpty)

    await runtime.stop()
    let stillRunning = await runtime.isRunning
    XCTAssertFalse(stillRunning)
  }

  func testUnauthenticatedConfigurationReportsUnauthenticatedMode() async throws {
    let noteRoot = try makeNoteRoot()
    let runtime = KaibaServerRuntime(KaibaServeConfiguration(
      host: "127.0.0.1",
      port: 8797,
      noteRoot: noteRoot,
      allowUnauthenticated: true
    ))
    let info = try await runtime.start()
    defer { Task { await runtime.stop() } }
    XCTAssertEqual(info.authMode, .unauthenticated)
    await runtime.stop()
  }

  private func makeNoteRoot(function: String = #function) throws -> String {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/AppServerTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.path
  }
}
