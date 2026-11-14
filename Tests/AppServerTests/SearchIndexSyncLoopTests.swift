import Foundation
import XCTest

@testable import AppCore
@testable import AppServer

final class SearchIndexSyncLoopTests: XCTestCase {
  func testPreparesActivatesAndKickDrainsPendingNote() async throws {
    let service = try makeService()
    let engine = SyncLoopFakeSearchEngine()
    let loop = SearchIndexSyncLoop(engine: engine, tickInterval: .seconds(0.2), debounce: .seconds(0.05))
    await loop.start(service: service)
    defer { Task { await loop.stop() } }

    try await waitUntil {
      let activationRows = try? service.driver.withDatabase { database in
        try database.query("SELECT 1 FROM search_engine_sync_state WHERE id = 1")
      }
      return await engine.ensureCount() > 0 && activationRows?.isEmpty == false
    }
    let activationRows = try service.driver.withDatabase { database in
      try database.query("SELECT 1 FROM search_engine_sync_state WHERE id = 1")
    }
    XCTAssertEqual(activationRows.count, 1)
    let note = try service.createNote(bodyMarkdown: "kick-triggered note")
    loop.kick()

    try await waitUntil { await engine.hasUpsert(note.noteId) }
    let wasUpserted = await engine.hasUpsert(note.noteId)
    XCTAssertTrue(wasUpserted)
  }

  func testPrepareFailureRetriesAndLogsSanitizedMessage() async throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "retry-backfilled note")
    let engine = SyncLoopFakeSearchEngine(failFirstEnsure: true)
    let messages = SyncLoopLogMessages()
    let loop = SearchIndexSyncLoop(
      engine: engine,
      tickInterval: .seconds(0.1),
      debounce: .seconds(0.02),
      log: { messages.append($0) }
    )
    await loop.start(service: service)
    defer { Task { await loop.stop() } }

    try await waitUntil {
      let ensureCount = await engine.ensureCount()
      let hasUpsert = await engine.hasUpsert(note.noteId)
      return ensureCount >= 2 && hasUpsert
    }
    let ensureCount = await engine.ensureCount()
    let hasUpsert = await engine.hasUpsert(note.noteId)
    XCTAssertGreaterThanOrEqual(ensureCount, 2)
    XCTAssertTrue(hasUpsert)

    let activationRows = try service.driver.withDatabase { database in
      try database.query("SELECT 1 FROM search_engine_sync_state WHERE id = 1")
    }
    XCTAssertEqual(activationRows.count, 1)
    let loggedMessages = messages.snapshot()
    XCTAssertTrue(loggedMessages.contains("kaiba search-engine: index not ready"))
    XCTAssertFalse(loggedMessages.contains { $0.contains("private details") })
    XCTAssertEqual(try service.searchIndexOutboxStatus().pending, 0)
  }

  func testBurstKicksAreCoalesced() async throws {
    let service = try makeService()
    let engine = SyncLoopFakeSearchEngine()
    let loop = SearchIndexSyncLoop(engine: engine, tickInterval: .seconds(10), debounce: .seconds(0.05))
    await loop.start(service: service)
    defer { Task { await loop.stop() } }
    try await waitUntil { await engine.ensureCount() > 0 }
    let note = try service.createNote(bodyMarkdown: "coalesced note")

    for _ in 0..<10 { loop.kick() }
    try await waitUntil { await engine.hasUpsert(note.noteId) }
    try await Task.sleep(for: .seconds(0.1))
    let applyCount = await engine.applyCount()
    XCTAssertLessThanOrEqual(applyCount, 2)
  }

  func testStopPreventsFurtherDrainPasses() async throws {
    let service = try makeService()
    let engine = SyncLoopFakeSearchEngine()
    let loop = SearchIndexSyncLoop(engine: engine, tickInterval: .seconds(10), debounce: .seconds(0.02))
    await loop.start(service: service)
    try await waitUntil { await engine.ensureCount() > 0 }
    await loop.stop()
    let note = try service.createNote(bodyMarkdown: "after stop")
    let applyCount = await engine.applyCount()
    loop.kick()
    try await Task.sleep(for: .seconds(0.5))

    let wasUpserted = await engine.hasUpsert(note.noteId)
    let finalApplyCount = await engine.applyCount()
    XCTAssertFalse(wasUpserted)
    XCTAssertEqual(finalApplyCount, applyCount)
  }

  private func makeService(function: String = #function) throws -> NoteService {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("KaibaSearchIndexSyncLoopTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
  }

  private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("condition did not become true before timeout")
  }
}

private actor SyncLoopFakeSearchEngine: SearchEngine {
  nonisolated let indexIdentity = "sync-loop-test-index"
  private let failFirstEnsure: Bool
  private var ensureCalls = 0
  private var applyCalls = 0
  private var appliedOperations: [SearchIndexOperation] = []

  init(failFirstEnsure: Bool = false) {
    self.failFirstEnsure = failFirstEnsure
  }

  func health() async throws -> SearchEngineHealth {
    SearchEngineHealth(isAvailable: true, detail: "available")
  }

  func ensureIndex() async throws {
    ensureCalls += 1
    if failFirstEnsure && ensureCalls == 1 {
      throw SearchEngineError.unavailable("test failure containing private details")
    }
  }

  func apply(_ operations: [SearchIndexOperation]) async throws -> [SearchIndexOperationResult] {
    applyCalls += 1
    appliedOperations.append(contentsOf: operations)
    return operations.map { SearchIndexOperationResult(noteId: $0.noteId, outcome: .succeeded) }
  }

  func search(_ query: SearchEngineQuery) async throws -> [SearchEngineHit] { [] }

  func relatedNotes(_ query: SearchEngineRelatedQuery) async throws -> [SearchEngineHit] { [] }

  func ensureCount() -> Int { ensureCalls }

  func applyCount() -> Int { applyCalls }

  func hasUpsert(_ noteId: NoteID) -> Bool {
    appliedOperations.contains { operation in
      if case let .upsert(document) = operation { return document.noteId == noteId }
      return false
    }
  }
}

private final class SyncLoopLogMessages: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []

  func append(_ value: String) {
    lock.lock()
    values.append(value)
    lock.unlock()
  }

  func snapshot() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}
