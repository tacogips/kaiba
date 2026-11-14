import Foundation
import AppCore

/// In-process broadcaster behind `GET /note/events`. Holds a monotonic revision
/// and a bounded window of recent events; pollers suspend until the revision
/// advances past the one they last saw, or until their timeout lapses.
public actor NoteChangeFeed {
  /// A `since` older than this window can no longer be served event-by-event;
  /// the poller receives the current revision with no events and refreshes.
  static let bufferCapacity = 128

  private var revision: UInt64 = 0
  private var buffer: [(revision: UInt64, event: NoteChangeEvent)] = []
  private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

  public init() {}

  public var currentRevision: UInt64 {
    revision
  }

  public func publish(_ event: NoteChangeEvent) {
    revision += 1
    buffer.append((revision: revision, event: event))
    if buffer.count > Self.bufferCapacity {
      buffer.removeFirst(buffer.count - Self.bufferCapacity)
    }
    let resumed = waiters
    waiters.removeAll()
    for continuation in resumed.values {
      continuation.resume()
    }
  }

  public func poll(
    since: UInt64,
    timeoutNanoseconds: UInt64
  ) async -> (revision: UInt64, events: [NoteChangeEvent]) {
    // `since > revision` means the poller carries a cursor from a previous
    // incarnation of this feed (a restarted server). Returning immediately lets
    // it adopt the current revision instead of waiting forever.
    if revision != since {
      return snapshot(since: since)
    }
    let id = UUID()
    let timeout = Task { [weak self] in
      try? await Task.sleep(nanoseconds: timeoutNanoseconds)
      await self?.wake(id)
    }
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        if Task.isCancelled {
          continuation.resume()
          return
        }
        waiters[id] = continuation
      }
    } onCancel: {
      Task { await self.wake(id) }
    }
    timeout.cancel()
    return snapshot(since: since)
  }

  private func wake(_ id: UUID) {
    waiters.removeValue(forKey: id)?.resume()
  }

  /// Events are only served when the window still covers `since`; a poller that
  /// fell behind gets the current revision with no events and refreshes wholesale.
  private func snapshot(since: UInt64) -> (revision: UInt64, events: [NoteChangeEvent]) {
    guard let oldest = buffer.first, since >= oldest.revision - 1, since < revision else {
      return (revision: revision, events: [])
    }
    return (revision: revision, events: buffer.filter { $0.revision > since }.map(\.event))
  }
}

/// Bridges the synchronous `NoteChangeObserving` callback on the mutating
/// thread onto the feed actor.
public struct NoteChangeFeedObserver: NoteChangeObserving {
  public let feed: NoteChangeFeed

  public init(feed: NoteChangeFeed) {
    self.feed = feed
  }

  public func noteStoreDidChange(_ event: NoteChangeEvent) {
    Task { [feed] in
      await feed.publish(event)
    }
  }
}
