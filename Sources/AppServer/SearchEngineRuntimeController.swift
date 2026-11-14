import AppCore
import Foundation

/// Owns the active engine and its single outbox drain loop for the server lifetime.
actor SearchEngineRuntimeController {
  private let slot: SearchEngineSlot
  private let makeEngine: @Sendable (NoteService) throws -> (any SearchEngine)?
  private let makeLoop: @Sendable (any SearchEngine) -> SearchIndexSyncLoop
  private let log: @Sendable (String) -> Void
  private let reloadGate = SearchEngineReloadGate()
  private let loopBox = SearchEngineLoopBox()
  private var service: NoteService?
  private var currentLoop: SearchIndexSyncLoop?
  private var hasResolvedManagedConfiguration = false

  init(
    slot: SearchEngineSlot,
    makeEngine: @escaping @Sendable (NoteService) throws -> (any SearchEngine)?,
    makeLoop: @escaping @Sendable (any SearchEngine) -> SearchIndexSyncLoop,
    log: @escaping @Sendable (String) -> Void = {
      FileHandle.standardError.write(Data(($0 + "\n").utf8))
    }
  ) {
    self.slot = slot
    self.makeEngine = makeEngine
    self.makeLoop = makeLoop
    self.log = log
  }

  func start(service: NoteService) async {
    self.service = service
    slot.setReloadHandler { [weak self] in
      guard let self else { return SearchEngineReloadOutcome(active: false, indexIdentity: nil) }
      return await self.reload()
    }
    _ = await reload()
  }

  func reload() async -> SearchEngineReloadOutcome {
    await reloadGate.acquire()
    let outcome = await reloadSerialized()
    await reloadGate.release()
    return outcome
  }

  nonisolated func kick() {
    loopBox.current()?.kick()
  }

  func stop() async {
    await reloadGate.acquire()
    slot.setReloadHandler(nil)
    await currentLoop?.stop()
    currentLoop = nil
    loopBox.set(nil)
    slot.replace(nil)
    service = nil
    hasResolvedManagedConfiguration = false
    await reloadGate.release()
  }

  private func reloadSerialized() async -> SearchEngineReloadOutcome {
    guard let service else { return SearchEngineReloadOutcome(active: false, indexIdentity: nil) }
    if slot.managedConfiguration != nil, hasResolvedManagedConfiguration {
      return currentOutcome
    }

    let engine: (any SearchEngine)?
    do {
      engine = try makeEngine(service)
    } catch let error as SearchEngineSettingsError {
      switch error {
      case let .invalid(field):
        log("kaiba search-engine: stored settings invalid: \(field)")
      case .managedByConfig:
        log("kaiba search-engine: settings error: SearchEngineSettingsError")
      }
      engine = nil
    } catch {
      log("kaiba search-engine: configuration failed: \(String(describing: type(of: error)))")
      engine = nil
    }

    await currentLoop?.stop()
    currentLoop = nil
    loopBox.set(nil)
    slot.replace(engine)

    if let engine {
      let loop = makeLoop(engine)
      currentLoop = loop
      loopBox.set(loop)
      await loop.start(service: service)
    }
    if slot.managedConfiguration != nil {
      hasResolvedManagedConfiguration = true
    }
    return SearchEngineReloadOutcome(active: engine != nil, indexIdentity: engine?.indexIdentity)
  }

  private var currentOutcome: SearchEngineReloadOutcome {
    SearchEngineReloadOutcome(active: currentLoop != nil, indexIdentity: slot.engine?.indexIdentity)
  }
}

/// Synchronous kick access for change-feed callbacks; it never waits for the controller actor.
private final class SearchEngineLoopBox: @unchecked Sendable {
  private let lock = NSLock()
  private var loop: SearchIndexSyncLoop?

  func set(_ loop: SearchIndexSyncLoop?) {
    lock.withLock { self.loop = loop }
  }

  func current() -> SearchIndexSyncLoop? {
    lock.withLock { loop }
  }
}

/// Serializes reloads across actor suspension points.
private actor SearchEngineReloadGate {
  private var isHeld = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    guard isHeld else {
      isHeld = true
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func release() {
    if waiters.isEmpty {
      isHeld = false
    } else {
      waiters.removeFirst().resume()
    }
  }
}

struct SearchEngineControllerKickObserver: NoteChangeObserving {
  let controller: SearchEngineRuntimeController

  func noteStoreDidChange(_ event: NoteChangeEvent) {
    controller.kick()
  }
}
