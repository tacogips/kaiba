import AppCore
import Dispatch
import Foundation

private enum SearchIndexSyncWake {
  case kick
  case tick
}

/// Bridges synchronous change events into one buffered worker signal.
private final class SearchIndexSyncWakeSignal: @unchecked Sendable {
  let stream: AsyncStream<SearchIndexSyncWake>
  private let continuation: AsyncStream<SearchIndexSyncWake>.Continuation
  private let lock = NSLock()
  private var isDebouncing = false

  init() {
    let (stream, continuation) = AsyncStream.makeStream(
      of: SearchIndexSyncWake.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    self.stream = stream
    self.continuation = continuation
  }

  func kick() { yield(.kick) }

  func tick() { yield(.tick) }

  func beginDebounce() {
    lock.lock()
    isDebouncing = true
    lock.unlock()
  }

  func endDebounce() {
    lock.lock()
    isDebouncing = false
    lock.unlock()
  }

  func finish() {
    continuation.finish()
  }

  private func yield(_ wake: SearchIndexSyncWake) {
    lock.lock()
    defer { lock.unlock() }
    if !isDebouncing { continuation.yield(wake) }
  }
}

/// Owns the server's serial preparation and drain passes for the search outbox.
actor SearchIndexSyncLoop {
  private let engine: any SearchEngine
  private let tickInterval: Duration
  private let debounce: Duration
  private let log: @Sendable (String) -> Void
  private let wakeSignal = SearchIndexSyncWakeSignal()
  private var task: Task<Void, Never>?
  private var timer: DispatchSourceTimer?

  init(
    engine: any SearchEngine,
    tickInterval: Duration = .seconds(15),
    debounce: Duration = .seconds(1),
    log: @escaping @Sendable (String) -> Void = {
      FileHandle.standardError.write(Data(($0 + "\n").utf8))
    }
  ) {
    self.engine = engine
    self.tickInterval = tickInterval
    self.debounce = debounce
    self.log = log
  }

  func start(service: NoteService) {
    guard task == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "kaiba.search-index-sync-timer"))
    let interval = tickInterval.nanosecondsForDispatch
    timer.schedule(deadline: .now() + .nanoseconds(interval), repeating: .nanoseconds(interval))
    timer.setEventHandler { [wakeSignal] in wakeSignal.tick() }
    timer.resume()
    self.timer = timer
    task = Task { [weak self] in
      await self?.run(service: service)
    }
  }

  nonisolated func kick() {
    wakeSignal.kick()
  }

  func stop() async {
    timer?.cancel()
    timer = nil
    wakeSignal.finish()
    task?.cancel()
    await task?.value
    task = nil
  }

  private func run(service: NoteService) async {
    var isPrepared = false
    await performPass(service: service, isPrepared: &isPrepared)
    for await wake in wakeSignal.stream {
      guard !Task.isCancelled else { return }
      if case .kick = wake {
        wakeSignal.beginDebounce()
        try? await Task.sleep(for: debounce)
        wakeSignal.endDebounce()
      }
      guard !Task.isCancelled else { return }
      await performPass(service: service, isPrepared: &isPrepared)
    }
  }

  private func performPass(service: NoteService, isPrepared: inout Bool) async {
    if !isPrepared {
      do {
        try await engine.ensureIndex()
        try service.activateSearchEngineSync(indexIdentity: engine.indexIdentity)
        isPrepared = true
      } catch {
        log("kaiba search-engine: index not ready")
        return
      }
    }

    do {
      let report = try await SearchIndexSynchronizer(service: service).drainUntilIdle(engine: engine)
      if report.failed > 0 {
        log("kaiba search-engine: \(report.failed) note(s) failed to sync")
      }
    } catch {
      log("kaiba search-engine: drain failed")
    }
  }
}

private extension Duration {
  var nanosecondsForDispatch: Int {
    let components = self.components
    let nanoseconds = components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
    return max(1, Int(nanoseconds))
  }
}

struct SearchIndexSyncKickObserver: NoteChangeObserving {
  let loop: SearchIndexSyncLoop

  func noteStoreDidChange(_ event: NoteChangeEvent) {
    loop.kick()
  }
}

struct FanOutNoteChangeObserver: NoteChangeObserving {
  let observers: [any NoteChangeObserving]

  init(_ observers: [any NoteChangeObserving]) {
    self.observers = observers
  }

  func noteStoreDidChange(_ event: NoteChangeEvent) {
    for observer in observers {
      observer.noteStoreDidChange(event)
    }
  }
}
