import Foundation
import XCTest

@testable import AppCore
@testable import AppServer

final class SearchEngineRuntimeControllerTests: XCTestCase {
  func testStartSharesEngineWithScopedServiceAndKickDrainsNote() async throws {
    let slot = SearchEngineSlot()
    let service = try makeService(slot: slot)
    let engine = ControllerFakeSearchEngine(identity: "engine-a")
    let controller = makeController(slot: slot, engines: [engine])

    await controller.start(service: service)
    XCTAssertEqual(slot.engine?.indexIdentity, "engine-a")
    XCTAssertEqual(service.searchEngine?.indexIdentity, "engine-a")
    let scoped = service.scoped(to: try service.defaultUser().userId)
    XCTAssertTrue(scoped.searchEngineSlot === slot)
    let note = try scoped.createNote(bodyMarkdown: "controller kick")
    controller.kick()

    try await waitUntil { await engine.hasUpsert(note.noteId) }
    XCTAssertEqual(scoped.searchEngine?.indexIdentity, "engine-a")
    XCTAssertTrue(scoped.isSearchEngineEnabled)
    let wasUpserted = await engine.hasUpsert(note.noteId)
    XCTAssertTrue(wasUpserted)
    await controller.stop()
  }

  func testStoredSettingsErrorStartsFTSOnlyAndLogsField() async throws {
    let slot = SearchEngineSlot()
    let service = try makeService(slot: slot)
    let messages = ControllerLogMessages()
    let controller = SearchEngineRuntimeController(
      slot: slot,
      makeEngine: { _ in throw SearchEngineSettingsError.invalid(field: "searchEngine.url") },
      makeLoop: { SearchIndexSyncLoop(engine: $0) },
      log: { messages.append($0) }
    )

    await controller.start(service: service)
    let outcome = await slot.reload()

    XCTAssertNil(slot.engine)
    XCTAssertFalse(outcome?.active ?? true)
    XCTAssertTrue(messages.snapshot().contains("kaiba search-engine: stored settings invalid: searchEngine.url"))
    XCTAssertFalse(messages.snapshot().contains { $0.contains("http") })
    await controller.stop()
  }

  func testIdentityChangeStopsOldLoopAndBackfillsEveryNote() async throws {
    let slot = SearchEngineSlot()
    let service = try makeService(slot: slot)
    let notes = try [
      service.createNote(bodyMarkdown: "first backfill"),
      service.createNote(bodyMarkdown: "second backfill")
    ]
    let first = ControllerFakeSearchEngine(identity: "engine-a")
    let second = ControllerFakeSearchEngine(identity: "engine-b")
    let loops = ControllerLoopRecorder()
    let controller = makeController(slot: slot, engines: [first, second], recorder: loops)
    await controller.start(service: service)
    try await waitUntil { await first.upsertedNoteIds().count == notes.count }

    let outcome = await controller.reload()
    try await waitUntil { await second.upsertedNoteIds().count == notes.count }
    let oldApplyCount = await first.applyCount()
    let backfilledIds = await second.upsertedNoteIds()

    XCTAssertEqual(outcome.indexIdentity, "engine-b")
    XCTAssertEqual(slot.engine?.indexIdentity, "engine-b")
    XCTAssertEqual(Set(backfilledIds), Set(notes.map(\.noteId)))
    try await Task.sleep(for: .milliseconds(80))
    let finalOldApplyCount = await first.applyCount()
    XCTAssertEqual(finalOldApplyCount, oldApplyCount)
    let recordedLoops = loops.snapshot()
    XCTAssertEqual(recordedLoops.count, 2)
    if let oldLoop = recordedLoops.first {
      try await assertLoopStopped(oldLoop.loop, engine: oldLoop.engine, service: service)
    } else {
      XCTFail("expected the initial sync loop to be recorded")
    }
    await controller.stop()
  }

  func testReloadToNoneDetachesAndStopsFurtherApplies() async throws {
    let slot = SearchEngineSlot()
    let service = try makeService(slot: slot)
    let engine = ControllerFakeSearchEngine(identity: "engine-a")
    let loops = ControllerLoopRecorder()
    let controller = makeController(slot: slot, engines: [engine, nil], recorder: loops)
    await controller.start(service: service)
    try await waitUntil { await engine.ensureCount() > 0 }

    let outcome = await controller.reload()
    let recordedLoops = loops.snapshot()
    XCTAssertEqual(recordedLoops.count, 1)
    if let oldLoop = recordedLoops.first {
      try await assertLoopStopped(oldLoop.loop, engine: oldLoop.engine, service: service)
    } else {
      XCTFail("expected the initial sync loop to be recorded")
    }
    let scoped = service.scoped(to: nil)
    let note = try scoped.createNote(bodyMarkdown: "after detach")
    controller.kick()
    try await Task.sleep(for: .milliseconds(100))

    XCTAssertFalse(outcome.active)
    XCTAssertNil(slot.engine)
    XCTAssertFalse(scoped.isSearchEngineEnabled)
    let wasUpsertedAfterDetach = await engine.hasUpsert(note.noteId)
    XCTAssertFalse(wasUpsertedAfterDetach)
    await controller.stop()
  }

  func testConcurrentReloadsLeaveOneLoopActive() async throws {
    let slot = SearchEngineSlot()
    let service = try makeService(slot: slot)
    let initial = ControllerFakeSearchEngine(identity: "engine-a")
    let replacementA = ControllerFakeSearchEngine(identity: "engine-b")
    let replacementB = ControllerFakeSearchEngine(identity: "engine-c")
    let loops = ControllerLoopRecorder()
    let controller = makeController(
      slot: slot,
      engines: [initial, replacementA, replacementB],
      recorder: loops
    )
    await controller.start(service: service)

    async let firstReload = controller.reload()
    async let secondReload = controller.reload()
    _ = await (firstReload, secondReload)
    let activeIdentity = try XCTUnwrap(slot.engine?.indexIdentity)
    let recordedLoops = loops.snapshot()
    XCTAssertEqual(recordedLoops.count, 3)
    for replacedLoop in recordedLoops.dropLast() {
      try await assertLoopStopped(replacedLoop.loop, engine: replacedLoop.engine, service: service)
    }
    guard let finalLoop = recordedLoops.last else {
      XCTFail("expected the final sync loop to be recorded")
      await controller.stop()
      return
    }
    let freshNote = try service.createNote(bodyMarkdown: "single active loop")
    finalLoop.loop.kick()
    try await waitUntil {
      let firstHasNote = await replacementA.hasUpsert(freshNote.noteId)
      let secondHasNote = await replacementB.hasUpsert(freshNote.noteId)
      return firstHasNote || secondHasNote
    }
    try await Task.sleep(for: .milliseconds(80))

    let replacementAHasNote = await replacementA.hasUpsert(freshNote.noteId)
    let replacementBHasNote = await replacementB.hasUpsert(freshNote.noteId)
    XCTAssertEqual([replacementAHasNote, replacementBHasNote].filter { $0 }.count, 1)
    let receivingIdentity = replacementAHasNote ? replacementA.indexIdentity : replacementB.indexIdentity
    XCTAssertEqual(receivingIdentity, slot.engine?.indexIdentity)
    XCTAssertTrue(["engine-b", "engine-c"].contains(activeIdentity))
    await controller.stop()
  }

  func testManagedConfigurationReloadIsNoOp() async throws {
    let configuration = KaibaSearchEngineConfiguration(kind: "elasticsearch", url: "http://127.0.0.1:9200")
    let slot = SearchEngineSlot(engine: ControllerFakeSearchEngine(identity: "managed"))
    let service = try makeService(slot: slot)
    slot.setManagedConfiguration(configuration)
    let calls = ControllerFactoryCallCount()
    let managed = ControllerFakeSearchEngine(identity: "managed")
    let controller = SearchEngineRuntimeController(
      slot: slot,
      makeEngine: { _ in
        calls.increment()
        return managed
      },
      makeLoop: { SearchIndexSyncLoop(engine: $0, tickInterval: .seconds(10), debounce: .milliseconds(20)) },
      log: { _ in }
    )
    await controller.start(service: service)
    let callsAtStart = calls.value

    let outcome = await controller.reload()

    XCTAssertEqual(calls.value, callsAtStart)
    XCTAssertEqual(outcome.indexIdentity, "managed")
    XCTAssertEqual(slot.engine?.indexIdentity, "managed")
    await controller.stop()
  }

  func testReloadHandlerIsInstalledAndClearedWithLifecycle() async throws {
    let slot = SearchEngineSlot()
    let service = try makeService(slot: slot)
    let engine = ControllerFakeSearchEngine(identity: "engine-a")
    let controller = makeController(slot: slot, engines: [engine])

    await controller.start(service: service)
    let outcome = await slot.reload()
    XCTAssertEqual(outcome?.indexIdentity, "engine-a")
    // The replacement loop prepares in its own task, so its ensureIndex can land after reload returns.
    try await waitUntil { await engine.ensureCount() == 2 }
    let ensureCount = await engine.ensureCount()
    XCTAssertEqual(ensureCount, 2)

    await controller.stop()
    let clearedOutcome = await slot.reload()
    XCTAssertNil(clearedOutcome)
  }

  private func makeController(
    slot: SearchEngineSlot,
    engines: [(any SearchEngine)?],
    recorder: ControllerLoopRecorder? = nil
  ) -> SearchEngineRuntimeController {
    let factory = ControllerEngineQueue(engines)
    return SearchEngineRuntimeController(
      slot: slot,
      makeEngine: { _ in factory.next() },
      makeLoop: { engine in
        let loop = SearchIndexSyncLoop(engine: engine, tickInterval: .seconds(10), debounce: .milliseconds(20))
        if let fakeEngine = engine as? ControllerFakeSearchEngine {
          recorder?.record(engine: fakeEngine, loop: loop)
        }
        return loop
      },
      log: { _ in }
    )
  }

  private func makeService(
    slot: SearchEngineSlot = SearchEngineSlot(),
    function: String = #function
  ) throws -> NoteService {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("KaibaSearchEngineRuntimeControllerTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path), searchEngineSlot: slot)
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

  private func assertLoopStopped(
    _ loop: SearchIndexSyncLoop,
    engine: ControllerFakeSearchEngine,
    service: NoteService,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    let probe = try service.createNote(bodyMarkdown: "stopped loop probe")
    loop.kick()
    try await Task.sleep(for: .milliseconds(200))
    let wasUpserted = await engine.hasUpsert(probe.noteId)
    XCTAssertFalse(wasUpserted, "replaced loop drained a fresh probe note", file: file, line: line)
  }
}

private actor ControllerFakeSearchEngine: SearchEngine {
  nonisolated let indexIdentity: String
  private var ensureCalls = 0
  private var applyCalls = 0
  private var operations: [SearchIndexOperation] = []

  init(identity: String) {
    indexIdentity = identity
  }

  func health() async throws -> SearchEngineHealth {
    SearchEngineHealth(isAvailable: true, detail: "available")
  }

  func ensureIndex() async throws {
    ensureCalls += 1
  }

  func apply(_ operations: [SearchIndexOperation]) async throws -> [SearchIndexOperationResult] {
    applyCalls += 1
    self.operations.append(contentsOf: operations)
    return operations.map { SearchIndexOperationResult(noteId: $0.noteId, outcome: .succeeded) }
  }

  func search(_ query: SearchEngineQuery) async throws -> [SearchEngineHit] { [] }

  func relatedNotes(_ query: SearchEngineRelatedQuery) async throws -> [SearchEngineHit] { [] }

  func ensureCount() -> Int { ensureCalls }

  func applyCount() -> Int { applyCalls }

  func hasUpsert(_ noteId: NoteID) -> Bool {
    operations.contains { operation in
      if case let .upsert(document) = operation { return document.noteId == noteId }
      return false
    }
  }

  func upsertedNoteIds() -> [NoteID] {
    operations.compactMap { operation in
      if case let .upsert(document) = operation { return document.noteId }
      return nil
    }
  }
}

private final class ControllerEngineQueue: @unchecked Sendable {
  private let lock = NSLock()
  private var engines: [(any SearchEngine)?]
  private var lastEngine: (any SearchEngine)?

  init(_ engines: [(any SearchEngine)?]) {
    self.engines = engines
    lastEngine = engines.last ?? nil
  }

  func next() -> (any SearchEngine)? {
    lock.lock()
    defer { lock.unlock() }
    guard !engines.isEmpty else { return lastEngine }
    lastEngine = engines.removeFirst()
    return lastEngine
  }
}

private final class ControllerLogMessages: @unchecked Sendable {
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

private final class ControllerLoopRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [(engine: ControllerFakeSearchEngine, loop: SearchIndexSyncLoop)] = []

  func record(engine: ControllerFakeSearchEngine, loop: SearchIndexSyncLoop) {
    lock.lock()
    values.append((engine: engine, loop: loop))
    lock.unlock()
  }

  func snapshot() -> [(engine: ControllerFakeSearchEngine, loop: SearchIndexSyncLoop)] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}

private final class ControllerFactoryCallCount: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }
}
