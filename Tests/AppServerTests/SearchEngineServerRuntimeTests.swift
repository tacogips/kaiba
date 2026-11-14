import Foundation
import XCTest

@testable import AppCore
@testable import AppServer

final class SearchEngineServerRuntimeTests: XCTestCase {
  func testRuntimeWithoutEngineStartsWithoutAttachingSyncLoop() async throws {
    let runtime = KaibaServerRuntime(KaibaServeConfiguration(noteRoot: try makeNoteRoot()))

    _ = try await runtime.startForTesting()
    let attached = await runtime.isSearchEngineAttachedForTesting
    await runtime.stop()

    XCTAssertFalse(attached)
  }

  func testUnreachableEngineDoesNotBlockStartAndStops() async throws {
    let configuration = KaibaConfiguration(searchEngine: KaibaSearchEngineConfiguration(
      kind: "meilisearch",
      url: "http://127.0.0.1:1"
    ))
    let runtime = KaibaServerRuntime(KaibaServeConfiguration(
      noteRoot: try makeNoteRoot(),
      configuration: configuration
    ))

    _ = try await runtime.startForTesting()
    let attached = await runtime.isSearchEngineAttachedForTesting
    XCTAssertTrue(attached)
    await runtime.stop()
  }

  func testUnsupportedEngineKindFailsBeforeStart() async throws {
    let configuration = KaibaConfiguration(searchEngine: KaibaSearchEngineConfiguration(
      kind: "opensearch",
      url: "http://127.0.0.1:7700"
    ))
    let runtime = KaibaServerRuntime(KaibaServeConfiguration(
      noteRoot: try makeNoteRoot(),
      configuration: configuration
    ))

    do {
      _ = try await runtime.startForTesting()
      XCTFail("unsupported engine kind should prevent server start")
    } catch {
      XCTAssertTrue(String(describing: error).contains("searchEngine.kind"))
    }
  }

  private func makeNoteRoot() throws -> String {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("KaibaSearchEngineServerRuntimeTests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.path
  }
}
