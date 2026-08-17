import Foundation
import AppCore

/// In-process fan-out behind `GET /note/agent-stream`. The auto-action
/// dispatcher publishes each ACP `agent_message_chunk` here while a chat
/// reply generates; web clients long-poll with a chunk cursor and render the
/// reply incrementally, which gives a streaming chat UX over the server's
/// single-write HTTP responses.
public actor AgentReplyStreamHub {
  typealias GraceExpiryScheduling = @Sendable (
    UInt64,
    @escaping @Sendable () -> Void
  ) -> Void
  /// Finished streams linger so a poller that raced the finish still reads the
  /// tail; the oldest are dropped past this cap.
  public static let maximumStreams = 64

  public struct Poll: Equatable, Sendable {
    public var cursor: Int
    public var chunks: [String]
    public var done: Bool
    public var status: String?
    public var message: String?
  }

  private struct Stream {
    var chunks: [String] = []
    var done = false
    var status: String?
    var message: String?
    /// Bumped on every publish; orders non-terminal streams for staleness
    /// eviction.
    var lastActivitySequence: UInt64
    var terminalSequence: UInt64?
    var deliveryObligations: Set<UUID> = []
    var firstTerminalDeliverySatisfied = false
    var graceGeneration: UUID?
  }

  private struct PendingPoll {
    var turnNoteId: NoteID
    var continuation: CheckedContinuation<Void, Never>
    var resumed = false
  }

  private var streams: [NoteID: Stream] = [:]
  private var sequence: UInt64 = 0
  /// A request remains registered until its HTTP response is about to return.
  /// This intentionally includes requests already woken by a chunk: finishing
  /// the turn before that response returns must still protect the tail.
  private var pendingPolls: [UUID: PendingPoll] = [:]
  private var deferredPollResponses: [UUID: CheckedContinuation<Void, Never>] = [:]
  private let maximumRetainedStreams: Int
  private let firstTerminalDeliveryGraceNanoseconds: UInt64
  private let graceExpiryScheduling: GraceExpiryScheduling
  private let defersPollResponsesForTesting: Bool

  public init(
    maximumRetainedStreams: Int = maximumStreams,
    firstTerminalDeliveryGraceNanoseconds: UInt64 = 35_000_000_000
  ) {
    self.init(
      maximumRetainedStreams: maximumRetainedStreams,
      firstTerminalDeliveryGraceNanoseconds: firstTerminalDeliveryGraceNanoseconds,
      graceExpiryScheduling: Self.scheduleSystemGraceExpiry,
      defersPollResponsesForTesting: false
    )
  }

  init(
    maximumRetainedStreams: Int,
    firstTerminalDeliveryGraceNanoseconds: UInt64,
    graceExpiryScheduling: @escaping GraceExpiryScheduling,
    defersPollResponsesForTesting: Bool = false
  ) {
    self.maximumRetainedStreams = max(0, maximumRetainedStreams)
    self.firstTerminalDeliveryGraceNanoseconds = firstTerminalDeliveryGraceNanoseconds
    self.graceExpiryScheduling = graceExpiryScheduling
    self.defersPollResponsesForTesting = defersPollResponsesForTesting
  }

  public func publish(turnNoteId: NoteID, text: String) {
    var stream = streams[turnNoteId] ?? makeStream()
    stream.chunks.append(text)
    sequence += 1
    stream.lastActivitySequence = sequence
    streams[turnNoteId] = stream
    wakePolls(for: turnNoteId)
    cleanupEligibleTerminalStreams()
    evictStaleActiveStreams()
  }

  public func finish(turnNoteId: NoteID, status: String, message: String?) {
    var stream = streams[turnNoteId] ?? makeStream()
    stream.done = true
    stream.status = status
    stream.message = message
    sequence += 1
    stream.terminalSequence = sequence
    stream.deliveryObligations = Set(pendingPolls.compactMap { id, poll in
      poll.turnNoteId == turnNoteId ? id : nil
    })
    let graceGeneration = UUID()
    stream.graceGeneration = graceGeneration
    streams[turnNoteId] = stream
    wakePolls(for: turnNoteId)
    scheduleGraceExpiry(turnNoteId: turnNoteId, generation: graceGeneration)
    cleanupEligibleTerminalStreams()
  }

  /// Suspends until the stream has chunks past `cursor` or finished, or until
  /// the timeout lapses. An unknown turn returns an empty pending poll so a
  /// client may subscribe before the dispatcher claims the turn.
  public func poll(
    turnNoteId: NoteID,
    cursor: Int,
    timeoutNanoseconds: UInt64
  ) async -> Poll {
    if let ready = snapshot(turnNoteId: turnNoteId, cursor: cursor) {
      recordTerminalDelivery(for: turnNoteId, pollId: nil, delivered: ready.done)
      return ready
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
        pendingPolls[id] = PendingPoll(turnNoteId: turnNoteId, continuation: continuation)
      }
    } onCancel: {
      Task { await self.wake(id) }
    }
    timeout.cancel()
    await deferPollResponseIfNeeded(id)
    let poll = snapshot(turnNoteId: turnNoteId, cursor: cursor)
      ?? Poll(cursor: cursor, chunks: [], done: false, status: nil, message: nil)
    let cancelled = Task.isCancelled
    pendingPolls.removeValue(forKey: id)
    recordTerminalDelivery(for: turnNoteId, pollId: id, delivered: poll.done && !cancelled)
    return poll
  }

  private func makeStream() -> Stream {
    sequence += 1
    return Stream(lastActivitySequence: sequence)
  }

  /// Nil while there is nothing new past `cursor` and the stream is not done.
  private func snapshot(turnNoteId: NoteID, cursor: Int) -> Poll? {
    guard let stream = streams[turnNoteId] else {
      return nil
    }
    let bounded = max(0, min(cursor, stream.chunks.count))
    guard stream.chunks.count > bounded || stream.done else {
      return nil
    }
    return Poll(
      cursor: stream.chunks.count,
      chunks: Array(stream.chunks[bounded...]),
      done: stream.done,
      status: stream.status,
      message: stream.message
    )
  }

  private func wake(_ id: UUID) {
    resumePoll(id)
    resumeDeferredPollResponse(id)
  }

  private func wakePolls(for turnNoteId: NoteID) {
    for (id, poll) in pendingPolls where poll.turnNoteId == turnNoteId {
      resumePoll(id)
    }
  }

  private func resumePoll(_ id: UUID) {
    guard var poll = pendingPolls[id], !poll.resumed else { return }
    poll.resumed = true
    pendingPolls[id] = poll
    poll.continuation.resume()
  }

  private func deferPollResponseIfNeeded(_ id: UUID) async {
    guard defersPollResponsesForTesting else { return }
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled {
          continuation.resume()
        } else {
          deferredPollResponses[id] = continuation
        }
      }
    } onCancel: {
      Task { await self.resumeDeferredPollResponse(id) }
    }
  }

  private func resumeDeferredPollResponse(_ id: UUID) {
    deferredPollResponses.removeValue(forKey: id)?.resume()
  }

  private func recordTerminalDelivery(for turnNoteId: NoteID, pollId: UUID?, delivered: Bool) {
    guard var stream = streams[turnNoteId], stream.done else { return }
    if let pollId {
      stream.deliveryObligations.remove(pollId)
    }
    if delivered {
      stream.firstTerminalDeliverySatisfied = true
    }
    streams[turnNoteId] = stream
    cleanupEligibleTerminalStreams()
  }

  private func scheduleGraceExpiry(turnNoteId: NoteID, generation: UUID) {
    graceExpiryScheduling(firstTerminalDeliveryGraceNanoseconds) { [weak self] in
      Task {
        await self?.expireGrace(turnNoteId: turnNoteId, generation: generation)
      }
    }
  }

  private static func scheduleSystemGraceExpiry(
    delay: UInt64,
    action: @escaping @Sendable () -> Void
  ) {
    Task {
      try? await Task.sleep(nanoseconds: delay)
      action()
    }
  }

  private func expireGrace(turnNoteId: NoteID, generation: UUID) {
    guard var stream = streams[turnNoteId], stream.graceGeneration == generation else { return }
    stream.firstTerminalDeliverySatisfied = true
    streams[turnNoteId] = stream
    cleanupEligibleTerminalStreams()
  }

  /// Active streams and terminal streams that still owe a poller a response
  /// are deliberately not candidates. This can temporarily exceed the target
  /// while preserving the delivery contract.
  private func cleanupEligibleTerminalStreams() {
    let eligible = streams.compactMap { id, stream -> (NoteID, UInt64)? in
      guard stream.done,
            stream.deliveryObligations.isEmpty,
            stream.firstTerminalDeliverySatisfied,
            let terminalSequence = stream.terminalSequence else {
        return nil
      }
      return (id, terminalSequence)
    }.sorted { $0.1 < $1.1 }
    let excess = max(0, eligible.count - maximumRetainedStreams)
    for (id, _) in eligible.prefix(excess) {
      streams.removeValue(forKey: id)
    }
  }

  /// The dispatcher normally finishes every stream, but an invoker that hangs
  /// mid-reply never does — without a bound those streams would retain their
  /// partial chunks forever. Past the retention target the least-recently
  /// active non-terminal streams are dropped; terminal streams keep their
  /// delivery-obligation rules above.
  private func evictStaleActiveStreams() {
    let active = streams.compactMap { id, stream -> (NoteID, UInt64)? in
      stream.done ? nil : (id, stream.lastActivitySequence)
    }.sorted { $0.1 < $1.1 }
    let excess = max(0, active.count - maximumRetainedStreams)
    for (id, _) in active.prefix(excess) {
      streams.removeValue(forKey: id)
    }
  }

  // Internal observability for actor-level regression coverage. These are not
  // part of the HTTP contract.
  func pendingPollCount(for turnNoteId: NoteID) -> Int {
    pendingPolls.values.filter { $0.turnNoteId == turnNoteId }.count
  }

  func deferredPollResponseCount() -> Int {
    deferredPollResponses.count
  }

  func containsStream(for turnNoteId: NoteID) -> Bool {
    streams[turnNoteId] != nil
  }
}

/// Bridges AppCore's synchronous publish callbacks onto the hub actor through
/// one ordered stream — chunks must land in emission order, and a detached
/// Task per chunk would not guarantee that.
public final class AgentReplyStreamHubPublisher: AgentReplyStreamPublishing, @unchecked Sendable {
  private enum Event {
    case chunk(turnNoteId: NoteID, text: String)
    case finish(turnNoteId: NoteID, status: String, message: String?)
  }

  private let continuation: AsyncStream<Event>.Continuation
  private let pump: Task<Void, Never>

  public init(hub: AgentReplyStreamHub) {
    let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
    self.continuation = continuation
    pump = Task {
      for await event in stream {
        switch event {
        case let .chunk(turnNoteId, text):
          await hub.publish(turnNoteId: turnNoteId, text: text)
        case let .finish(turnNoteId, status, message):
          await hub.finish(turnNoteId: turnNoteId, status: status, message: message)
        }
      }
    }
  }

  // The pump is deliberately not cancelled: finishing the continuation lets
  // it drain events already buffered — cancelling here could drop a
  // buffered `.finish` and strand its stream as never-terminal.
  deinit {
    continuation.finish()
  }

  public func publishAgentReplyChunk(turnNoteId: NoteID, text: String) {
    continuation.yield(.chunk(turnNoteId: turnNoteId, text: text))
  }

  public func finishAgentReplyStream(turnNoteId: NoteID, status: String, message: String?) {
    continuation.yield(.finish(turnNoteId: turnNoteId, status: status, message: message))
  }
}
