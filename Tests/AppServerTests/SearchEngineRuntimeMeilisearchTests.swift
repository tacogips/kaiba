import Foundation
import XCTest

@testable import AppCore
@testable import AppServer

final class SearchEngineRuntimeMeilisearchTests: XCTestCase {
  func testSettingsReloadActivatesMeilisearchForScopedServices() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("SearchEngineRuntimeMeilisearchTests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let slot = SearchEngineSlot()
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path), searchEngineSlot: slot)
    let resolverMode = MeilisearchResolverMode()
    let initialEngine = RuntimeMeilisearchFakeEngine(identity: "initial-fake")
    let controller = SearchEngineRuntimeController(
      slot: slot,
      makeEngine: { service in
        if resolverMode.usesProductionResolver {
          return try service.makeResolvedSearchEngine(configuration: nil, environment: [:])
        }
        return initialEngine
      },
      makeLoop: { engine in
        SearchIndexSyncLoop(engine: RuntimeMeilisearchFakeEngine(identity: engine.indexIdentity))
      },
      log: { _ in }
    )

    await controller.start(service: service)
    XCTAssertEqual(slot.engine?.indexIdentity, "initial-fake")
    resolverMode.enableProductionResolver()
    let view = try await service.updateSearchEngineSettings(SearchEngineSettingsInput(
      kind: "meilisearch", url: "http://127.0.0.1:7700", indexPrefix: "runtime-test", authMode: "none"
    ))

    let expectedIdentity = "meilisearch:http://127.0.0.1:7700/runtime-test-notes-v1"
    XCTAssertTrue(view.active)
    XCTAssertEqual(slot.engine?.indexIdentity, expectedIdentity)
    let scoped = service.scoped(to: try service.defaultUser().userId)
    XCTAssertTrue(scoped.searchEngineSlot === slot)
    XCTAssertEqual(scoped.searchEngine?.indexIdentity, expectedIdentity)
    await controller.stop()
  }
}

private actor RuntimeMeilisearchFakeEngine: SearchEngine {
  nonisolated let indexIdentity: String

  init(identity: String) {
    indexIdentity = identity
  }

  func health() async throws -> SearchEngineHealth {
    SearchEngineHealth(isAvailable: true, detail: "available")
  }

  func ensureIndex() async throws {}

  func apply(_ operations: [SearchIndexOperation]) async throws -> [SearchIndexOperationResult] {
    operations.map { SearchIndexOperationResult(noteId: $0.noteId, outcome: .succeeded) }
  }

  func search(_ query: SearchEngineQuery) async throws -> [SearchEngineHit] { [] }

  func relatedNotes(_ query: SearchEngineRelatedQuery) async throws -> [SearchEngineHit] { [] }
}

private final class MeilisearchResolverMode: @unchecked Sendable {
  private let lock = NSLock()
  private var enabled = false

  var usesProductionResolver: Bool { lock.withLock { enabled } }

  func enableProductionResolver() {
    lock.withLock { enabled = true }
  }
}
