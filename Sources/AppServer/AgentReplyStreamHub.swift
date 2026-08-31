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
  /// A stream can be left open by a provider indefinitely. Keep its payload
  /// bounded independently of its lightweight lease and delivery metadata.
  private static let maximumRetainedChunkBytesPerStream = 256 * 1_024
  /// Byte limits alone do not bound array and string-object overhead: a provider
  /// may legally emit empty or tiny ACP chunks. Keep the retained payload
  /// element count bounded too.
  static let maximumRetainedChunksPerStream = 256
  static let maximumPendingPollsPerTurn = 2
  static let maximumPendingPolls = 256

  public struct Poll: Equatable, Sendable {
    public var cursor: Int
    public var chunks: [String]
    public var done: Bool
    public var status: String?
    public var message: String?
    /// True when retained chunks were evicted and the caller must refresh the
    /// durable conversation rather than treating this response as contiguous.
    public var resync: Bool
    /// Libraries that authorized the provider context for returned chunks.
    /// This is server-only authorization metadata and is not serialized.
    public var requiredLibraryIds: [LibraryID]
    /// Identifies a route-owned response whose delivery must be acknowledged
    /// after final authorization. This intentionally stays internal to
    /// AppServer and is never serialized.
    var deliveryPollId: UUID?
    /// Binds a deferred delivery acknowledgement to the stream generation
    /// that produced the response. This stays internal to AppServer and is
    /// never serialized.
    var streamGeneration: UUID?
  }

  private struct Stream {
    var chunks: [String] = []
    var retainedChunkByteCount = 0
    /// Cursor generation is encoded into the opaque HTTP cursor. A cursor
    /// from another generation safely restarts at this stream's first chunk,
    /// even after its predecessor has been evicted.
    var cursorGeneration: Int64
    /// A retryable failed stream receives a new generation. Deferred terminal
    /// acknowledgements from an older generation must not affect this one.
    var generation: UUID
    var requiredLibraryIds: Set<LibraryID> = []
    var done = false
    var status: String?
    var message: String?
    var payloadWasEvicted = false
    /// Bumped on every publish; orders non-terminal streams for staleness
    /// eviction.
    var lastActivitySequence: UInt64
    var terminalSequence: UInt64?
    var deliveryObligations: Set<UUID> = []
    var firstTerminalDeliverySatisfied = false
    var graceGeneration: UUID?
    /// A grace deadline that passed while a route still owed a response must
    /// be restarted once that response is accepted or rejected. Otherwise a
    /// nonterminal snapshot could lose the terminal tail before its successor
    /// cursor poll can retrieve it.
    var graceExpiredWhileDeliveryWasPending = false
    /// The current outbox attempt permitted to mutate this shared stream.
    /// Recovery registers its new lease before invoking the provider, which
    /// makes later writes from a superseded worker no-ops inside this actor.
    var activeLease: AgentReplyStreamLease?
  }

  private struct PendingPoll {
    var turnNoteId: NoteID
    var continuation: CheckedContinuation<Void, Never>
    var resumed = false
  }

  private var streams: [NoteID: Stream] = [:]
  /// The upper 29 bits of an opaque cursor identify its generation; the low
  /// 24 bits identify the chunk offset. Keeping the token within JavaScript's
  /// safe integer range replaces per-turn retry tombstones with bounded state.
  private static let cursorOffsetBits: Int64 = 24
  private static let cursorOffsetMask: Int64 = 0xFF_FFFF
  private static let maximumCursorGeneration: Int64 = 0x1FFF_FFFF
  private var nextCursorGeneration: Int64 = 1
  private var sequence: UInt64 = 0
  /// A request remains registered until its HTTP response is about to return.
  /// This intentionally includes requests already woken by a chunk: finishing
  /// the turn before that response returns must still protect the tail.
  private var pendingPolls: [UUID: PendingPoll] = [:]
  private var pendingPollRegistrationWaiters: [NoteID: [CheckedContinuation<Void, Never>]] = [:]
  private var graceExpiryWhileDeliveryPendingWaiters: [NoteID: [CheckedContinuation<Void, Never>]] = [:]
  private var deferredPollResponses: [UUID: CheckedContinuation<Void, Never>] = [:]
  /// Test-only observers wait on this actor-owned registration boundary rather
  /// than polling the scheduler for a deferred response.
  private var deferredPollResponseRegistrationWaiters: [CheckedContinuation<Void, Never>] = []
  /// Test-only gate for the route's delivery authorization boundary. It lets
  /// a regression revoke library access after a response is prepared but
  /// before the hub admits it as delivered.
  private var deferredTerminalDeliveryAcknowledgements: [UUID: CheckedContinuation<Void, Never>] = [:]
  private var terminalAckRegistrationWaiters: [CheckedContinuation<Void, Never>] = []
  private let maximumRetainedStreams: Int
  private let firstTerminalDeliveryGraceNanoseconds: UInt64
  private let graceExpiryScheduling: GraceExpiryScheduling
  private let defersPollResponsesForTesting: Bool
  private let defersTerminalAckForTesting: Bool

  /// Exposed for deterministic route tests that must prove a credential was
  /// revoked while a stream poll was actually suspended.
  var activePollCount: Int { pendingPolls.count }

  public init(
    maximumRetainedStreams: Int = maximumStreams,
    firstTerminalDeliveryGraceNanoseconds: UInt64 = 35_000_000_000
  ) {
    self.init(
      maximumRetainedStreams: maximumRetainedStreams,
      firstTerminalDeliveryGraceNanoseconds: firstTerminalDeliveryGraceNanoseconds,
      graceExpiryScheduling: Self.scheduleSystemGraceExpiry,
      defersPollResponsesForTesting: false,
      defersTerminalAckForTesting: false
    )
  }

  init(
    maximumRetainedStreams: Int,
    firstTerminalDeliveryGraceNanoseconds: UInt64,
    graceExpiryScheduling: @escaping GraceExpiryScheduling,
    defersPollResponsesForTesting: Bool = false,
    defersTerminalAckForTesting: Bool = false
  ) {
    self.maximumRetainedStreams = max(0, maximumRetainedStreams)
    self.firstTerminalDeliveryGraceNanoseconds = firstTerminalDeliveryGraceNanoseconds
    self.graceExpiryScheduling = graceExpiryScheduling
    self.defersPollResponsesForTesting = defersPollResponsesForTesting
    self.defersTerminalAckForTesting = defersTerminalAckForTesting
  }

  public func publish(turnNoteId: NoteID, text: String, libraryId: LibraryID? = nil) {
    var stream = streams[turnNoteId] ?? makeStream(turnNoteId: turnNoteId)
    appendChunk(text, to: &stream)
    if let libraryId {
      stream.requiredLibraryIds.insert(libraryId)
    }
    sequence += 1
    stream.lastActivitySequence = sequence
    streams[turnNoteId] = stream
    wakePolls(for: turnNoteId)
    cleanupEligibleTerminalStreams()
    evictStalePayloads()
  }

  public func beginLeasedStream(turnNoteId: NoteID, lease: AgentReplyStreamLease) {
    var stream = streams[turnNoteId] ?? makeStream(turnNoteId: turnNoteId)
    if let activeLease = stream.activeLease {
      // One streamed turn is owned by one durable dispatch. A foreign dispatch
      // must never seize an existing stream, even with a numerically higher
      // attempt number.
      guard lease.dispatchId == activeLease.dispatchId else {
        return
      }
      guard lease.attemptNumber > activeLease.attemptNumber
        || (lease.attemptNumber == activeLease.attemptNumber && lease == activeLease) else {
        return
      }
      // Recovery may claim a new lease after an old worker has already
      // published partial output but before it terminalizes. Start a fresh
      // cursor generation so no client can concatenate two provider attempts.
      if lease.attemptNumber > activeLease.attemptNumber, !stream.done {
        resetForNewLeaseGeneration(&stream)
      }
    }
    if stream.done {
      // A failed chat turn is explicitly retryable. A newer claimed attempt
      // starts a fresh stream generation, while answered and cancelled turns
      // remain terminal and cannot be reopened by any stale worker.
      guard stream.status == "failed" else { return }
      if let activeLease = stream.activeLease {
        guard lease.attemptNumber > activeLease.attemptNumber else { return }
      }
      resetForNewLeaseGeneration(&stream)
    }
    stream.activeLease = lease
    streams[turnNoteId] = stream
  }

  public func publish(
    turnNoteId: NoteID,
    text: String,
    libraryId: LibraryID,
    lease: AgentReplyStreamLease
  ) {
    guard var stream = streams[turnNoteId], stream.activeLease == lease, !stream.done else { return }
    appendChunk(text, to: &stream)
    stream.requiredLibraryIds.insert(libraryId)
    sequence += 1
    stream.lastActivitySequence = sequence
    streams[turnNoteId] = stream
    wakePolls(for: turnNoteId)
    cleanupEligibleTerminalStreams()
    evictStalePayloads()
  }

  public func finish(
    turnNoteId: NoteID,
    status: String,
    message: String?,
    libraryId: LibraryID? = nil
  ) {
    var stream = streams[turnNoteId] ?? makeStream(turnNoteId: turnNoteId)
    if let libraryId {
      stream.requiredLibraryIds.insert(libraryId)
    }
    stream.done = true
    stream.status = status
    stream.message = message
    sequence += 1
    stream.terminalSequence = sequence
    stream.deliveryObligations.formUnion(pendingPolls.compactMap { id, poll in
      poll.turnNoteId == turnNoteId ? id : nil
    })
    let graceGeneration = UUID()
    stream.graceGeneration = graceGeneration
    streams[turnNoteId] = stream
    wakePolls(for: turnNoteId)
    scheduleGraceExpiry(turnNoteId: turnNoteId, generation: graceGeneration)
    cleanupEligibleTerminalStreams()
  }

  public func finish(
    turnNoteId: NoteID,
    status: String,
    message: String?,
    libraryId: LibraryID,
    lease: AgentReplyStreamLease
  ) {
    guard var stream = streams[turnNoteId], stream.activeLease == lease, !stream.done else { return }
    stream.requiredLibraryIds.insert(libraryId)
    stream.done = true
    stream.status = status
    stream.message = message
    sequence += 1
    stream.terminalSequence = sequence
    stream.deliveryObligations.formUnion(pendingPolls.compactMap { id, poll in
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
    timeoutNanoseconds: UInt64,
    deferTerminalAcknowledgement: Bool = false
  ) async -> Poll {
    if var ready = snapshot(turnNoteId: turnNoteId, cursor: cursor) {
      if deferTerminalAcknowledgement {
        let id = UUID()
        ready.deliveryPollId = id
        registerDeliveryObligation(
          for: turnNoteId,
          generation: ready.streamGeneration,
          pollId: id
        )
      } else {
        recordTerminalDelivery(
          for: turnNoteId,
          generation: ready.streamGeneration,
          pollId: nil,
          delivered: ready.done
        )
      }
      return ready
    }
    guard pendingPolls.count < Self.maximumPendingPolls,
      pendingPollCount(for: turnNoteId) < Self.maximumPendingPollsPerTurn
    else {
      return Poll(
        cursor: cursor,
        chunks: [],
        done: false,
        status: "overloaded",
        message: nil,
        resync: false,
        requiredLibraryIds: [],
        deliveryPollId: nil,
        streamGeneration: nil
      )
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
        let waiters = pendingPollRegistrationWaiters.removeValue(forKey: turnNoteId) ?? []
        waiters.forEach { $0.resume() }
      }
    } onCancel: {
      Task { await self.wake(id) }
    }
    timeout.cancel()
    await deferPollResponseIfNeeded(id)
    var poll = snapshot(turnNoteId: turnNoteId, cursor: cursor)
      ?? Poll(
        cursor: cursor,
        chunks: [],
        done: false,
        status: nil,
        message: nil,
        resync: false,
        requiredLibraryIds: [],
        deliveryPollId: nil,
        streamGeneration: nil
    )
    let cancelled = Task.isCancelled
    if deferTerminalAcknowledgement, !cancelled {
      poll.deliveryPollId = id
      registerDeliveryObligation(
        for: turnNoteId,
        generation: poll.streamGeneration,
        pollId: id
      )
    }
    pendingPolls.removeValue(forKey: id)
    if !deferTerminalAcknowledgement || cancelled {
      recordTerminalDelivery(
        for: turnNoteId,
        generation: poll.streamGeneration,
        pollId: id,
        delivered: poll.done && !cancelled
      )
    } else {
      // The route owns this obligation through post-poll reauthentication and
      // final owner/library checks. If the stream finishes during either
      // await, retention still includes this response until the route accepts
      // or rejects it below.
    }
    return poll
  }

  /// Completes a route-owned poll after the route has either authorized the
  /// response or rejected it. Rejections release the request obligation
  /// without making an unseen terminal stream eligible for retention eviction.
  func acknowledgeTerminalDelivery(
    turnNoteId: NoteID,
    poll: Poll,
    delivered: Bool
  ) {
    recordTerminalDelivery(
      for: turnNoteId,
      generation: poll.streamGeneration,
      pollId: poll.deliveryPollId,
      delivered: delivered && poll.done
    )
  }

  /// Runs final route authorization after any deferred acknowledgement wait,
  /// then records delivery without another suspension. A rejected
  /// authorization releases its obligation without making an unseen terminal
  /// stream eligible for delivery-based eviction.
  func authorizeAndAcknowledgeTerminalDelivery(
    turnNoteId: NoteID,
    poll: Poll,
    authorizing authorization: @Sendable () throws -> Bool
  ) async throws -> Bool {
    if poll.deliveryPollId != nil {
      await deferTerminalDeliveryAcknowledgementIfNeeded()
    }
    let authorized = try authorization()
    if poll.deliveryPollId != nil {
      recordTerminalDelivery(
        for: turnNoteId,
        generation: poll.streamGeneration,
        pollId: poll.deliveryPollId,
        delivered: authorized && poll.done
      )
    }
    return authorized
  }

  private func makeStream(turnNoteId _: NoteID) -> Stream {
    sequence += 1
    return Stream(
      cursorGeneration: allocateCursorGeneration(),
      generation: UUID(),
      lastActivitySequence: sequence
    )
  }

  /// Clears every payload and delivery field that is scoped to a provider
  /// attempt. The new opaque cursor makes stale callers resynchronize from
  /// durable state instead of appending output across attempts.
  private func resetForNewLeaseGeneration(_ stream: inout Stream) {
    stream.cursorGeneration = allocateCursorGeneration()
    stream.chunks.removeAll(keepingCapacity: false)
    stream.retainedChunkByteCount = 0
    stream.generation = UUID()
    stream.requiredLibraryIds.removeAll()
    stream.done = false
    stream.status = nil
    stream.message = nil
    stream.payloadWasEvicted = true
    stream.terminalSequence = nil
    stream.deliveryObligations.removeAll()
    stream.firstTerminalDeliverySatisfied = false
    stream.graceGeneration = nil
    stream.graceExpiredWhileDeliveryWasPending = false
    sequence += 1
    stream.lastActivitySequence = sequence
  }

  private func allocateCursorGeneration() -> Int64 {
    let generation = nextCursorGeneration
    nextCursorGeneration = generation == Self.maximumCursorGeneration ? 1 : generation + 1
    return generation
  }

  private func chunkOffset(for cursor: Int, in stream: Stream) -> Int {
    let rawCursor = Int64(cursor)
    guard rawCursor >= 0, rawCursor >> Self.cursorOffsetBits == stream.cursorGeneration else {
      return 0
    }
    return min(Int(rawCursor & Self.cursorOffsetMask), stream.chunks.count)
  }

  private func encodedCursor(for stream: Stream) -> Int {
    let offset = min(Int64(stream.chunks.count), Self.cursorOffsetMask)
    return Int((stream.cursorGeneration << Self.cursorOffsetBits) | offset)
  }

  /// Nil while there is nothing new past `cursor` and the stream is not done.
  private func snapshot(turnNoteId: NoteID, cursor: Int) -> Poll? {
    guard let stream = streams[turnNoteId] else {
      return nil
    }
    let bounded = chunkOffset(for: cursor, in: stream)
    guard stream.chunks.count > bounded || stream.done else {
      return nil
    }
    return Poll(
      cursor: encodedCursor(for: stream),
      chunks: Array(stream.chunks[bounded...]),
      done: stream.done,
      status: stream.status,
      message: stream.message,
      resync: stream.payloadWasEvicted,
      requiredLibraryIds: stream.requiredLibraryIds.sorted { $0.rawValue < $1.rawValue },
      deliveryPollId: nil,
      streamGeneration: stream.generation
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
          let waiters = deferredPollResponseRegistrationWaiters
          deferredPollResponseRegistrationWaiters.removeAll()
          waiters.forEach { $0.resume() }
        }
      }
    } onCancel: {
      Task { await self.resumeDeferredPollResponse(id) }
    }
  }

  private func resumeDeferredPollResponse(_ id: UUID) {
    deferredPollResponses.removeValue(forKey: id)?.resume()
  }

  private func deferTerminalDeliveryAcknowledgementIfNeeded() async {
    guard defersTerminalAckForTesting else { return }
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled {
          continuation.resume()
        } else {
          deferredTerminalDeliveryAcknowledgements[id] = continuation
          let waiters = terminalAckRegistrationWaiters
          terminalAckRegistrationWaiters.removeAll()
          waiters.forEach { $0.resume() }
        }
      }
    } onCancel: {
      Task { await self.resumeDeferredTerminalDeliveryAcknowledgement(id) }
    }
  }

  private func resumeDeferredTerminalDeliveryAcknowledgement(_ id: UUID) {
    deferredTerminalDeliveryAcknowledgements.removeValue(forKey: id)?.resume()
  }

  private func recordTerminalDelivery(
    for turnNoteId: NoteID,
    generation: UUID?,
    pollId: UUID?,
    delivered: Bool
  ) {
    guard let generation,
          var stream = streams[turnNoteId],
          stream.generation == generation else {
      return
    }
    if let pollId {
      stream.deliveryObligations.remove(pollId)
    }
    if delivered && stream.done {
      stream.firstTerminalDeliverySatisfied = true
    }
    let restartGrace = stream.done
      && !stream.firstTerminalDeliverySatisfied
      && stream.deliveryObligations.isEmpty
      && stream.graceExpiredWhileDeliveryWasPending
    let graceGeneration: UUID?
    if restartGrace {
      let nextGeneration = UUID()
      stream.graceGeneration = nextGeneration
      stream.graceExpiredWhileDeliveryWasPending = false
      graceGeneration = nextGeneration
    } else {
      graceGeneration = nil
    }
    streams[turnNoteId] = stream
    if let graceGeneration {
      scheduleGraceExpiry(turnNoteId: turnNoteId, generation: graceGeneration)
    }
    cleanupEligibleTerminalStreams()
  }

  private func registerDeliveryObligation(
    for turnNoteId: NoteID,
    generation: UUID?,
    pollId: UUID
  ) {
    guard let generation,
          var stream = streams[turnNoteId],
          stream.generation == generation else {
      return
    }
    stream.deliveryObligations.insert(pollId)
    streams[turnNoteId] = stream
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
    if !stream.deliveryObligations.isEmpty {
      stream.graceExpiredWhileDeliveryWasPending = true
      streams[turnNoteId] = stream
      let waiters = graceExpiryWhileDeliveryPendingWaiters.removeValue(forKey: turnNoteId) ?? []
      waiters.forEach { $0.resume() }
      return
    }
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
  /// mid-reply never does. Bound retained chunk payload independently from the
  /// lightweight current-lease and delivery metadata needed for a later finish
  /// to wake an already-pending poll. A discarded payload receives a fresh
  /// cursor generation, so clients safely restart instead of treating an old
  /// offset as current.
  private func evictStalePayloads() {
    let payloads = streams.compactMap { id, stream -> (NoteID, UInt64)? in
      guard !stream.chunks.isEmpty else {
        return nil
      }
      return (id, stream.lastActivitySequence)
    }.sorted { $0.1 < $1.1 }
    let excess = max(0, payloads.count - maximumRetainedStreams)
    for (id, _) in payloads.prefix(excess) {
      guard var stream = streams[id] else { continue }
      // Preserve the stream identity, producer fence, and route-delivery
      // state. Only the resynchronizable payload is discarded.
      stream.chunks.removeAll(keepingCapacity: false)
      stream.retainedChunkByteCount = 0
      stream.cursorGeneration = allocateCursorGeneration()
      stream.payloadWasEvicted = true
      sequence += 1
      stream.lastActivitySequence = sequence
      streams[id] = stream
    }
  }

  private func appendChunk(_ text: String, to stream: inout Stream) {
    let byteCount = text.utf8.count
    guard byteCount <= Self.maximumRetainedChunkBytesPerStream else {
      // Avoid retaining a giant or unbounded partial response. The cursor
      // generation change directs clients to resynchronize from durable state.
      stream.chunks.removeAll(keepingCapacity: false)
      stream.retainedChunkByteCount = 0
      stream.cursorGeneration = allocateCursorGeneration()
      stream.payloadWasEvicted = true
      return
    }
    guard stream.chunks.count < Self.maximumRetainedChunksPerStream,
      stream.retainedChunkByteCount <= Self.maximumRetainedChunkBytesPerStream - byteCount
    else {
      // The payload remains resumable only from durable state after either
      // bound is exceeded. Retain the current bounded chunk as the start of a
      // fresh generation for a caller that has already observed resync.
      stream.chunks.removeAll(keepingCapacity: false)
      stream.retainedChunkByteCount = 0
      stream.cursorGeneration = allocateCursorGeneration()
      stream.payloadWasEvicted = true
      stream.chunks.append(text)
      stream.retainedChunkByteCount = byteCount
      return
    }
    stream.chunks.append(text)
    stream.retainedChunkByteCount += byteCount
  }

  // Internal observability for actor-level regression coverage. These are not
  // part of the HTTP contract.
  func pendingPollCount(for turnNoteId: NoteID) -> Int {
    pendingPolls.values.filter { $0.turnNoteId == turnNoteId }.count
  }

  /// Internal observability for bounded-payload regression coverage.
  func retainedChunkCount() -> Int {
    streams.values.reduce(into: 0) { $0 += $1.chunks.count }
  }

  func retainedChunkByteCount() -> Int {
    streams.values.reduce(into: 0) { $0 += $1.retainedChunkByteCount }
  }

  /// Suspends test execution until a long poll has registered with the hub.
  /// This actor-owned handshake avoids scheduler-yield readiness probes.
  func waitForPendingPollRegistration(for turnNoteId: NoteID) async {
    guard !pendingPolls.values.contains(where: { $0.turnNoteId == turnNoteId }) else { return }
    await withCheckedContinuation { continuation in
      if pendingPolls.values.contains(where: { $0.turnNoteId == turnNoteId }) {
        continuation.resume()
      } else {
        pendingPollRegistrationWaiters[turnNoteId, default: []].append(continuation)
      }
    }
  }

  /// Suspends test execution until a terminal stream's grace deadline has
  /// elapsed while a route-owned delivery obligation is still active. This
  /// makes retention-pressure tests observe the exact interleaving instead of
  /// relying on an unstructured grace-expiry task being scheduled first.
  func waitForGraceExpiryWhileDeliveryIsPending(for turnNoteId: NoteID) async {
    guard streams[turnNoteId]?.graceExpiredWhileDeliveryWasPending != true else { return }
    await withCheckedContinuation { continuation in
      if streams[turnNoteId]?.graceExpiredWhileDeliveryWasPending == true {
        continuation.resume()
      } else {
        graceExpiryWhileDeliveryPendingWaiters[turnNoteId, default: []].append(continuation)
      }
    }
  }

  /// Suspends test execution until a terminal poll has registered its deferred
  /// response. This is intentionally actor-owned so a cancellation regression
  /// cannot race a clock-polled readiness probe.
  func waitForDeferredPollResponseRegistration() async {
    guard defersPollResponsesForTesting, deferredPollResponses.isEmpty else { return }
    await withCheckedContinuation { continuation in
      if deferredPollResponses.isEmpty {
        deferredPollResponseRegistrationWaiters.append(continuation)
      } else {
        continuation.resume()
      }
    }
  }

  /// Deterministically observes registration at the terminal-delivery
  /// authorization boundary used by route-level TOCTOU tests.
  func waitForTerminalDeliveryAcknowledgementRegistration() async {
    guard defersTerminalAckForTesting,
          deferredTerminalDeliveryAcknowledgements.isEmpty else { return }
    await withCheckedContinuation { continuation in
      if deferredTerminalDeliveryAcknowledgements.isEmpty {
        terminalAckRegistrationWaiters.append(continuation)
      } else {
        continuation.resume()
      }
    }
  }

  func resumeDeferredTerminalDeliveryAcknowledgements() {
    let acknowledgements = deferredTerminalDeliveryAcknowledgements
    deferredTerminalDeliveryAcknowledgements.removeAll()
    acknowledgements.values.forEach { $0.resume() }
  }

  func containsStream(for turnNoteId: NoteID) -> Bool {
    streams[turnNoteId] != nil
  }
}

/// Bridges AppCore's direct callbacks onto the stream hub. Leased callbacks
/// await the hub so takeover registration and admission are serialized by the
/// actor; direct local invocations retain the existing ordered event pump.
public final class AgentReplyStreamHubPublisher: AgentReplyStreamPublishing, @unchecked Sendable {
  private enum Event {
    case chunk(turnNoteId: NoteID, text: String, libraryId: LibraryID)
    case finish(turnNoteId: NoteID, status: String, message: String?, libraryId: LibraryID)
  }

  private let continuation: AsyncStream<Event>.Continuation
  private let pump: Task<Void, Never>
  private let hub: AgentReplyStreamHub

  public init(hub: AgentReplyStreamHub) {
    let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
    self.continuation = continuation
    self.hub = hub
    pump = Task {
      for await event in stream {
        switch event {
        case let .chunk(turnNoteId, text, libraryId):
          await hub.publish(turnNoteId: turnNoteId, text: text, libraryId: libraryId)
        case let .finish(turnNoteId, status, message, libraryId):
          await hub.finish(
            turnNoteId: turnNoteId,
            status: status,
            message: message,
            libraryId: libraryId
          )
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

  public func publishAgentReplyChunk(turnNoteId: NoteID, text: String, libraryId: LibraryID) {
    continuation.yield(.chunk(turnNoteId: turnNoteId, text: text, libraryId: libraryId))
  }

  public func finishAgentReplyStream(
    turnNoteId: NoteID,
    status: String,
    message: String?,
    libraryId: LibraryID
  ) {
    continuation.yield(.finish(
      turnNoteId: turnNoteId,
      status: status,
      message: message,
      libraryId: libraryId
    ))
  }

  public func beginLeasedAgentReplyStream(
    turnNoteId: NoteID,
    lease: AgentReplyStreamLease
  ) async {
    await hub.beginLeasedStream(turnNoteId: turnNoteId, lease: lease)
  }

  public func publishLeasedAgentReplyChunk(
    turnNoteId: NoteID,
    text: String,
    libraryId: LibraryID,
    lease: AgentReplyStreamLease
  ) async {
    await hub.publish(
      turnNoteId: turnNoteId,
      text: text,
      libraryId: libraryId,
      lease: lease
    )
  }

  public func finishLeasedAgentReplyStream(
    turnNoteId: NoteID,
    status: String,
    message: String?,
    libraryId: LibraryID,
    lease: AgentReplyStreamLease
  ) async {
    await hub.finish(
      turnNoteId: turnNoteId,
      status: status,
      message: message,
      libraryId: libraryId,
      lease: lease
    )
  }
}
