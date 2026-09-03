import Foundation
import AppCore

/// An opaque, principal-bound event-feed cursor. It reveals neither store-wide
/// mutation counts nor the time at which another principal changed the store.
public struct NoteChangeFeedPoll: Sendable {
  public var revision: String
  public var events: [NoteChangeEvent]
  /// A new or expired cursor requires the client to refresh its own view once.
  public var resync: Bool

  public init(revision: String, events: [NoteChangeEvent], resync: Bool) {
    self.revision = revision
    self.events = events
    self.resync = resync
  }
}

public enum NoteChangeFeedError: Error, Sendable {
  case authorizationFailed(String)
  /// The caller has too many live opaque cursors. Refuse a reset instead of
  /// evicting another client, which could wake or resync its active poll.
  case cursorCapacityReached
  /// Long-poll waiters retain continuations and timeout tasks. Admission is
  /// bounded separately from cursor and event retention.
  case waiterCapacityReached
}

/// In-process broadcaster behind `GET /note/events`. Each opaque cursor holds
/// only events visible to its authenticated principal, and a foreign event
/// neither advances nor wakes that cursor.
public actor NoteChangeFeed {
  private struct DeliveredPoll {
    var successorCursor: String
    var events: [NoteChangeEvent]
    var resync: Bool
  }

  private struct CursorState {
    var principalId: String
    /// All cursor generations in one delivery chain share a root, so retaining
    /// one retry generation does not consume another principal-local slot.
    var rootCursor: String
    /// Supplying this cursor acknowledges delivery from its predecessor.
    var predecessorCursor: String?
    var eventAuthorizer: @Sendable (NoteChangeEvent) throws -> Bool
    var pendingEvents: [NoteChangeEvent]
    var requiresResync: Bool
    var authorizationFailure: String?
    /// A completed response remains available under its request cursor until
    /// the client advances to `successorCursor`. This makes transport loss and
    /// same-cursor overlap replay-safe without an HTTP acknowledgment hook.
    var deliveredPoll: DeliveredPoll?
    /// Each concurrent request for a cursor waits independently. When an event
    /// arrives, every waiter resumes and observes the same prepared delivery.
    var waiters: [UUID: CheckedContinuation<Void, Never>]
    var lastAccessedAt: Date
  }

  private static let cursorLifetime: TimeInterval = 5 * 60
  static let maximumCursorsPerPrincipal = 32
  static let maximumPendingEventsPerCursor = 128
  static let maximumWaitersPerCursor = 2
  static let maximumWaitersPerPrincipal = 16
  static let maximumWaiters = 256
  private var cursors: [String: CursorState] = [:]
  private var publishedRevision: UInt64 = 0

  public init() {}

  /// Test-only observation of internal publications. This value is never
  /// included in a client response and must not be used as an event cursor.
  var currentRevision: UInt64 {
    publishedRevision
  }

  var activePollCount: Int {
    cursors.values.reduce(into: 0) { count, state in
      count += state.waiters.count
    }
  }

  public func publish(_ event: NoteChangeEvent) {
    publishedRevision += 1
    for cursor in Array(cursors.keys) {
      guard var state = cursors[cursor] else {
        continue
      }
      guard !state.requiresResync else {
        continue
      }
      // Once a response is prepared, its successor is the only generation
      // that may receive later events. The request cursor stays immutable so
      // a retry gets precisely the already-prepared response.
      guard state.deliveredPoll == nil else {
        continue
      }
      do {
        guard try state.eventAuthorizer(event) else {
          cursors[cursor] = state
          continue
        }
        append(event, to: &state)
      } catch {
        state.authorizationFailure = "\(error)"
        append(event, to: &state)
      }
      let waiters = state.waiters.values
      state.waiters.removeAll()
      cursors[cursor] = state
      for waiter in waiters {
        waiter.resume()
      }
    }
  }

  public func poll(
    since: String?,
    principalId: String,
    timeoutNanoseconds: UInt64,
    eventAuthorizer: @escaping @Sendable (NoteChangeEvent) throws -> Bool
  ) async throws -> NoteChangeFeedPoll {
    evictExpiredCursors()
    guard let since,
          since != "0",
          var state = cursors[since],
          state.principalId == principalId else {
      let revision = try makeCursor(for: principalId)
      cursors[revision] = CursorState(
        principalId: principalId,
        rootCursor: revision,
        predecessorCursor: nil,
        eventAuthorizer: eventAuthorizer,
        pendingEvents: [],
        requiresResync: false,
        authorizationFailure: nil,
        deliveredPoll: nil,
        waiters: [:],
        lastAccessedAt: Date()
      )
      return NoteChangeFeedPoll(revision: revision, events: [], resync: true)
    }

    // A request using the successor is the acknowledgement for the previous
    // response. Until then, the predecessor remains replayable.
    if let predecessor = state.predecessorCursor {
      cursors.removeValue(forKey: predecessor)
      state.predecessorCursor = nil
    }
    state.eventAuthorizer = eventAuthorizer
    state.lastAccessedAt = Date()
    cursors[since] = state
    if let replay = try replayPreparedPoll(cursor: since) {
      return replay
    }
    if let firstResult = try prepareVisiblePoll(cursor: since) {
      return firstResult
    }

    try await waitForVisibleEvent(cursor: since, timeoutNanoseconds: timeoutNanoseconds)
    if let replay = try replayPreparedPoll(cursor: since) {
      return replay
    }
    return try prepareVisiblePoll(cursor: since)
      ?? NoteChangeFeedPoll(revision: since, events: [], resync: false)
  }

  private func prepareVisiblePoll(cursor: String) throws -> NoteChangeFeedPoll? {
    guard var state = cursors[cursor] else {
      return nil
    }
    if let failure = state.authorizationFailure {
      state.authorizationFailure = nil
      cursors[cursor] = state
      throw NoteChangeFeedError.authorizationFailed(failure)
    }
    if state.requiresResync {
      state.requiresResync = false
      state.pendingEvents = []
      return prepareDelivery(cursor: cursor, state: state, events: [], resync: true)
    }
    let visibleEvents = try visibleEvents(
      in: state.pendingEvents,
      authorizingWith: state.eventAuthorizer
    )
    state.pendingEvents = []
    guard !visibleEvents.isEmpty else {
      cursors[cursor] = state
      return nil
    }
    return prepareDelivery(cursor: cursor, state: state, events: visibleEvents, resync: false)
  }

  private func visibleEvents(
    in events: [NoteChangeEvent],
    authorizingWith eventAuthorizer: @Sendable (NoteChangeEvent) throws -> Bool
  ) throws -> [NoteChangeEvent] {
    var visibleEvents: [NoteChangeEvent] = []
    for event in events {
      do {
        if try eventAuthorizer(event) {
          visibleEvents.append(event)
        }
      } catch {
        throw NoteChangeFeedError.authorizationFailed("\(error)")
      }
    }
    return visibleEvents
  }

  private func replayPreparedPoll(cursor: String) throws -> NoteChangeFeedPoll? {
    guard let state = cursors[cursor], let deliveredPoll = state.deliveredPoll else {
      return nil
    }
    // A replay is still a new authorization decision. Retain the immutable
    // batch for transport safety, but filter it through the request's current
    // owner/library reach before exposing metadata again. If the authorization
    // read fails, the batch stays intact for same-cursor retry.
    let events = try visibleEvents(
      in: deliveredPoll.events,
      authorizingWith: state.eventAuthorizer
    )
    return NoteChangeFeedPoll(
      revision: deliveredPoll.successorCursor,
      events: events,
      resync: deliveredPoll.resync
    )
  }

  private func prepareDelivery(
    cursor: String,
    state: CursorState,
    events: [NoteChangeEvent],
    resync: Bool
  ) -> NoteChangeFeedPoll {
    let successorCursor = makeSuccessorCursor()
    let response = NoteChangeFeedPoll(
      revision: successorCursor,
      events: events,
      resync: resync
    )
    var deliveredState = state
    deliveredState.deliveredPoll = DeliveredPoll(
      successorCursor: successorCursor,
      events: events,
      resync: resync
    )
    deliveredState.waiters.removeAll()
    deliveredState.lastAccessedAt = Date()
    cursors[cursor] = deliveredState
    cursors[successorCursor] = CursorState(
      principalId: state.principalId,
      rootCursor: state.rootCursor,
      predecessorCursor: cursor,
      eventAuthorizer: state.eventAuthorizer,
      pendingEvents: [],
      requiresResync: false,
      authorizationFailure: nil,
      deliveredPoll: nil,
      waiters: [:],
      lastAccessedAt: Date()
    )
    return response
  }

  private func append(_ event: NoteChangeEvent, to state: inout CursorState) {
    if state.pendingEvents.count >= Self.maximumPendingEventsPerCursor {
      state.pendingEvents = []
      state.requiresResync = true
    } else {
      state.pendingEvents.append(event)
    }
  }

  private func waitForVisibleEvent(cursor: String, timeoutNanoseconds: UInt64) async throws {
    guard let initialState = cursors[cursor] else {
      return
    }
    guard initialState.waiters.count < Self.maximumWaitersPerCursor,
      activePollCount < Self.maximumWaiters,
      waiterCount(for: initialState.principalId) < Self.maximumWaitersPerPrincipal
    else {
      throw NoteChangeFeedError.waiterCapacityReached
    }
    let waiterId = UUID()
    let timeout = Task { [weak self] in
      try? await Task.sleep(nanoseconds: timeoutNanoseconds)
      await self?.wake(cursor: cursor, waiterId: waiterId)
    }
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        guard var state = cursors[cursor] else {
          continuation.resume()
          return
        }
        if !state.pendingEvents.isEmpty || state.requiresResync || state.authorizationFailure != nil || state.deliveredPoll != nil {
          continuation.resume()
          return
        }
        state.waiters[waiterId] = continuation
        cursors[cursor] = state
      }
    } onCancel: {
      Task { await self.wake(cursor: cursor, waiterId: waiterId) }
    }
    timeout.cancel()
  }

  private func wake(cursor: String, waiterId: UUID) {
    guard var state = cursors[cursor] else {
      return
    }
    guard let waiter = state.waiters.removeValue(forKey: waiterId) else {
      return
    }
    cursors[cursor] = state
    waiter.resume()
  }

  private func makeCursor(for principalId: String) throws -> String {
    evictExpiredCursors()
    let cursorCount = Set(cursors.values.lazy
      .filter { $0.principalId == principalId }
      .map(\.rootCursor)).count
    guard cursorCount < Self.maximumCursorsPerPrincipal else {
      throw NoteChangeFeedError.cursorCapacityReached
    }
    return makeSuccessorCursor()
  }

  private func waiterCount(for principalId: String) -> Int {
    cursors.values.reduce(into: 0) { count, state in
      guard state.principalId == principalId else { return }
      count += state.waiters.count
    }
  }

  private func makeSuccessorCursor() -> String {
    "note-events-\(UUID().uuidString.lowercased())"
  }

  private func evictExpiredCursors() {
    let cutoff = Date().addingTimeInterval(-Self.cursorLifetime)
    let expired = cursors.compactMap { cursor, state in
      state.lastAccessedAt < cutoff && state.waiters.isEmpty ? cursor : nil
    }
    for cursor in expired {
      cursors.removeValue(forKey: cursor)
    }
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
