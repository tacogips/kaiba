import Foundation
@testable import AppCore
@testable import AppServer
import XCTest

private final class ManualGraceExpiryScheduler: @unchecked Sendable {
  private let lock = NSLock()
  private var pending: [@Sendable () -> Void] = []

  func schedule(_ delay: UInt64, action: @escaping @Sendable () -> Void) {
    _ = delay
    lock.withLock { pending.append(action) }
  }

  func fireAll() {
    let actions = lock.withLock { () -> [@Sendable () -> Void] in
      defer { pending.removeAll() }
      return pending
    }
    actions.forEach { $0() }
  }
}

private actor RecoveredAnsweredChatInvoker: AgentInvoking {
  private var invocationCount = 0

  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    XCTAssertEqual(request.purpose, .chat)
    invocationCount += 1
    return AgentInvocationResult(markdown: "recovered answered reply")
  }

  func count() -> Int {
    invocationCount
  }
}

private actor FirstChunkBlockingChatInvoker: AgentStreamingInvoking {
  private var firstChunkWaiters: [CheckedContinuation<Void, Never>] = []
  private var emittedFirstChunk = false
  private var resumeContinuation: CheckedContinuation<Void, Never>?

  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    XCTAssertEqual(request.purpose, .chat)
    return AgentInvocationResult(markdown: "final streamed reply")
  }

  func invoke(
    _ request: AgentInvocationRequest,
    onChunk: @escaping @Sendable (String) -> Bool
  ) async throws -> AgentInvocationResult {
    XCTAssertEqual(request.purpose, .chat)
    XCTAssertTrue(onChunk("first live chunk"))
    emittedFirstChunk = true
    let waiters = firstChunkWaiters
    firstChunkWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    await withCheckedContinuation { resumeContinuation = $0 }
    XCTAssertTrue(onChunk("second live chunk"))
    return AgentInvocationResult(markdown: "final streamed reply")
  }

  func waitUntilFirstChunk() async {
    guard !emittedFirstChunk else { return }
    await withCheckedContinuation { firstChunkWaiters.append($0) }
  }

  func resume() {
    resumeContinuation?.resume()
    resumeContinuation = nil
  }
}

private actor AnsweredTurnStreamAdmissionBarrier {
  private var paused = false
  private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
  private var resumeContinuation: CheckedContinuation<Void, Never>?

  func pauseFirstAdmission(_: AgentReplyStreamLease) async {
    guard !paused else { return }
    paused = true
    let waiters = pauseWaiters
    pauseWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation { resumeContinuation = $0 }
  }

  func waitUntilPaused() async {
    guard !paused else { return }
    await withCheckedContinuation { pauseWaiters.append($0) }
  }

  func resume() {
    resumeContinuation?.resume()
    resumeContinuation = nil
  }
}

final class AgentReplyStreamHubTests: XCTestCase {
  func testLeasedReplyPublishesFirstChunkBeforeDurableCompletion() async throws {
    let service = try makeService()
    for action in AIAutoActionReconciliation.taggingActions {
      _ = try service.configureAutoAction(
        actionId: action.actionId,
        trigger: action.trigger,
        workflowId: NoteStoreSchema.autoTaggingWorkflowId,
        enabled: false
      )
    }
    let alice = try service.createUser(email: "live-stream@example.com", displayName: "Live")
    let aliceService = service.scoped(to: alice.userId)
    let subject = try aliceService.createNote(bodyMarkdown: "# Subject\nLive stream")
    let conversation = try aliceService.startAgentConversation(subjectNoteId: subject.noteId)
    _ = try service.configureAutoAction(
      actionId: NoteStoreSchema.agentChatReplyActionId,
      trigger: .noteCreated,
      workflowId: NoteStoreSchema.agentChatReplyWorkflowId,
      enabled: true
    )
    let turn = try aliceService.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Summarize",
      agentAvailable: true
    )
    let hub = AgentReplyStreamHub()
    let invoker = FirstChunkBlockingChatInvoker()
    let dispatcher = KaibaAutoActionDispatcher(
      service: service,
      invoker: invoker,
      streamPublisher: AgentReplyStreamHubPublisher(hub: hub)
    )
    let worker = try NoteService(driver: service.driver, autoActionDispatcher: dispatcher)

    XCTAssertEqual(try worker.retryPendingAutoActionDispatches(), 1)
    await invoker.waitUntilFirstChunk()
    let partial = await hub.poll(turnNoteId: turn.noteId, cursor: 0, timeoutNanoseconds: 1_000_000_000)
    XCTAssertEqual(partial.chunks, ["first live chunk"])
    XCTAssertFalse(partial.done)
    XCTAssertEqual(NoteService.chatTurnState(of: try service.getNote(turn.noteId))?.status, .pending)

    await invoker.resume()
    await worker.drainAutoActionDispatches()
    let terminal = await hub.poll(turnNoteId: turn.noteId, cursor: partial.cursor, timeoutNanoseconds: 1_000_000)
    XCTAssertTrue(terminal.done)
    XCTAssertEqual(terminal.status, "answered")
  }

  func testRecoveredAnsweredTurnFinishesCurrentLeaseStreamWithoutReinvokingProvider() async throws {
    let service = try makeService()
    for action in AIAutoActionReconciliation.taggingActions {
      _ = try service.configureAutoAction(
        actionId: action.actionId,
        trigger: action.trigger,
        workflowId: NoteStoreSchema.autoTaggingWorkflowId,
        enabled: false
      )
    }
    let alice = try service.createUser(email: "recovered-answer@example.com", displayName: "Alice")
    let aliceService = service.scoped(to: alice.userId)
    let subject = try aliceService.createNote(bodyMarkdown: "# Subject\nRecovered answer")
    let conversation = try aliceService.startAgentConversation(subjectNoteId: subject.noteId)
    _ = try service.configureAutoAction(
      actionId: NoteStoreSchema.agentChatReplyActionId,
      trigger: .noteCreated,
      workflowId: NoteStoreSchema.agentChatReplyWorkflowId,
      enabled: true
    )
    let turn = try aliceService.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Summarize",
      agentAvailable: true
    )
    let hub = AgentReplyStreamHub()
    let barrier = AnsweredTurnStreamAdmissionBarrier()
    var dispatcherService = service
    dispatcherService.agentReplyStreamPostLeaseValidationHook = { lease in
      await barrier.pauseFirstAdmission(lease)
    }
    let invoker = RecoveredAnsweredChatInvoker()
    let dispatcher = KaibaAutoActionDispatcher(
      service: dispatcherService,
      invoker: invoker,
      streamPublisher: AgentReplyStreamHubPublisher(hub: hub)
    )
    let worker = try NoteService(
      driver: service.driver,
      autoActionDispatcher: dispatcher,
      autoActionDispatchLeaseStaleness: 0
    )

    XCTAssertEqual(try worker.retryPendingAutoActionDispatches(), 1)
    await barrier.waitUntilPaused()
    XCTAssertEqual(NoteService.chatTurnState(of: try service.getNote(turn.noteId))?.status, .answered)

    let attempt = try XCTUnwrap(try service.listAutoActionDispatchAttempts().first {
      $0.record.event.noteId == turn.noteId
    })
    let staleLeaseBindings: [SQLiteValue] = [.text("2000-01-01T00:00:00Z"), .id(attempt.dispatchId)]
    try worker.driver.withDatabase { database in
      try database.execute(
        "UPDATE auto_action_dispatches SET leased_at = ? WHERE dispatch_id = ?",
        bindings: staleLeaseBindings
      )
    }
    XCTAssertEqual(try worker.recoverInterruptedAutoActionDispatches(olderThan: 1), 1)
    XCTAssertEqual(try worker.retryPendingAutoActionDispatches(), 1)

    let poll = await hub.poll(turnNoteId: turn.noteId, cursor: 0, timeoutNanoseconds: 1_000_000_000)
    XCTAssertTrue(poll.done)
    XCTAssertEqual(poll.status, "answered")
    XCTAssertTrue(poll.chunks.isEmpty)
    let invocationCount = await invoker.count()
    XCTAssertEqual(invocationCount, 1)

    await barrier.resume()
    await worker.drainAutoActionDispatches()
  }

  func testLeasedStreamRejectsSupersededChunksAndTerminalStates() async {
    let hub = AgentReplyStreamHub()
    let turnNoteId = NoteID("leased-turn")
    let libraryId = LibraryID("library-default")
    let staleLease = AgentReplyStreamLease(
      dispatchId: AutoActionDispatchID("dispatch-stale"),
      token: "stale",
      attemptNumber: 1
    )
    let currentLease = AgentReplyStreamLease(
      dispatchId: staleLease.dispatchId,
      token: "current",
      attemptNumber: 2
    )

    await hub.beginLeasedStream(turnNoteId: turnNoteId, lease: staleLease)
    await hub.beginLeasedStream(turnNoteId: turnNoteId, lease: currentLease)
    await hub.publish(
      turnNoteId: turnNoteId,
      text: "stale chunk",
      libraryId: libraryId,
      lease: staleLease
    )
    for status in ["answered", "failed", "cancelled"] {
      await hub.finish(
        turnNoteId: turnNoteId,
        status: status,
        message: "stale \(status)",
        libraryId: libraryId,
        lease: staleLease
      )
    }
    await hub.publish(
      turnNoteId: turnNoteId,
      text: "current chunk",
      libraryId: libraryId,
      lease: currentLease
    )
    await hub.finish(
      turnNoteId: turnNoteId,
      status: "answered",
      message: nil,
      libraryId: libraryId,
      lease: currentLease
    )

    let poll = await hub.poll(turnNoteId: turnNoteId, cursor: 0, timeoutNanoseconds: 1_000_000)
    XCTAssertEqual(poll.chunks, ["current chunk"])
    XCTAssertTrue(poll.done)
    XCTAssertEqual(poll.status, "answered")
  }

  func testNewerLeaseTakeoverResetsPublishedNonterminalGeneration() async {
    let hub = AgentReplyStreamHub()
    let turnNoteId = NoteID("nonterminal-takeover")
    let firstLibrary = LibraryID("library-first")
    let retryLibrary = LibraryID("library-retry")
    let firstLease = AgentReplyStreamLease(
      dispatchId: AutoActionDispatchID("dispatch-nonterminal-takeover"),
      token: "first",
      attemptNumber: 1
    )
    let retryLease = AgentReplyStreamLease(
      dispatchId: firstLease.dispatchId,
      token: "retry",
      attemptNumber: 2
    )
    let foreignLease = AgentReplyStreamLease(
      dispatchId: AutoActionDispatchID("foreign-dispatch"),
      token: "foreign",
      attemptNumber: 3
    )

    await hub.beginLeasedStream(turnNoteId: turnNoteId, lease: firstLease)
    await hub.publish(
      turnNoteId: turnNoteId,
      text: "stale attempt output",
      libraryId: firstLibrary,
      lease: firstLease
    )
    let firstPoll = await hub.poll(turnNoteId: turnNoteId, cursor: 0, timeoutNanoseconds: 1_000_000)
    XCTAssertEqual(firstPoll.chunks, ["stale attempt output"])
    XCTAssertFalse(firstPoll.done)

    await hub.beginLeasedStream(turnNoteId: turnNoteId, lease: retryLease)
    await hub.beginLeasedStream(turnNoteId: turnNoteId, lease: foreignLease)
    await hub.publish(
      turnNoteId: turnNoteId,
      text: "retry output",
      libraryId: retryLibrary,
      lease: retryLease
    )
    await hub.finish(
      turnNoteId: turnNoteId,
      status: "answered",
      message: nil,
      libraryId: retryLibrary,
      lease: retryLease
    )

    let retryPoll = await hub.poll(
      turnNoteId: turnNoteId,
      cursor: firstPoll.cursor,
      timeoutNanoseconds: 1_000_000
    )
    XCTAssertEqual(retryPoll.chunks, ["retry output"])
    XCTAssertTrue(retryPoll.resync)
    XCTAssertTrue(retryPoll.done)
    XCTAssertEqual(retryPoll.status, "answered")
    XCTAssertEqual(retryPoll.requiredLibraryIds, [retryLibrary])
  }

  func testLeasedFailedStreamCanBeSupersededBySuccessfulRetry() async {
    let hub = AgentReplyStreamHub()
    let turnNoteId = NoteID("retryable-leased-turn")
    let libraryId = LibraryID("library-default")
    let failedLease = AgentReplyStreamLease(
      dispatchId: AutoActionDispatchID("dispatch-retry"),
      token: "failed-attempt",
      attemptNumber: 1
    )
    let retryLease = AgentReplyStreamLease(
      dispatchId: failedLease.dispatchId,
      token: "retry-attempt",
      attemptNumber: 2
    )

    await hub.beginLeasedStream(turnNoteId: turnNoteId, lease: failedLease)
    await hub.publish(
      turnNoteId: turnNoteId,
      text: "failed chunk",
      libraryId: libraryId,
      lease: failedLease
    )
    await hub.finish(
      turnNoteId: turnNoteId,
      status: "failed",
      message: "retryable provider failure",
      libraryId: libraryId,
      lease: failedLease
    )
    let failedPoll = await hub.poll(
      turnNoteId: turnNoteId,
      cursor: 0,
      timeoutNanoseconds: 1_000_000
    )
    XCTAssertEqual(failedPoll.chunks, ["failed chunk"])
    XCTAssertTrue(failedPoll.done)
    XCTAssertEqual(failedPoll.status, "failed")

    await hub.beginLeasedStream(turnNoteId: turnNoteId, lease: retryLease)
    await hub.publish(
      turnNoteId: turnNoteId,
      text: "stale retry chunk",
      libraryId: libraryId,
      lease: failedLease
    )
    await hub.finish(
      turnNoteId: turnNoteId,
      status: "cancelled",
      message: "stale retry terminal",
      libraryId: libraryId,
      lease: failedLease
    )
    await hub.publish(
      turnNoteId: turnNoteId,
      text: "successful retry chunk",
      libraryId: libraryId,
      lease: retryLease
    )
    await hub.finish(
      turnNoteId: turnNoteId,
      status: "answered",
      message: nil,
      libraryId: libraryId,
      lease: retryLease
    )

    let poll = await hub.poll(
      turnNoteId: turnNoteId,
      cursor: failedPoll.cursor,
      timeoutNanoseconds: 1_000_000
    )
    XCTAssertEqual(poll.chunks, ["successful retry chunk"])
    XCTAssertNotEqual(poll.cursor, failedPoll.cursor)
    XCTAssertTrue(poll.done)
    XCTAssertEqual(poll.status, "answered")
  }

  func testFailedGenerationCursorSurvivesRetentionEviction() async {
    let hub = AgentReplyStreamHub(maximumRetainedStreams: 1)
    let turnNoteId = NoteID("evicted-retryable-leased-turn")
    let evictionTurnNoteId = NoteID("retention-pressure-turn")
    let libraryId = LibraryID("library-default")
    let failedLease = AgentReplyStreamLease(
      dispatchId: AutoActionDispatchID("dispatch-evicted-retry"),
      token: "failed-attempt",
      attemptNumber: 1
    )
    let retryLease = AgentReplyStreamLease(
      dispatchId: failedLease.dispatchId,
      token: "retry-attempt",
      attemptNumber: 2
    )

    await hub.beginLeasedStream(turnNoteId: turnNoteId, lease: failedLease)
    await hub.publish(
      turnNoteId: turnNoteId,
      text: "failed chunk",
      libraryId: libraryId,
      lease: failedLease
    )
    await hub.finish(
      turnNoteId: turnNoteId,
      status: "failed",
      message: "retryable provider failure",
      libraryId: libraryId,
      lease: failedLease
    )
    let failedPoll = await hub.poll(
      turnNoteId: turnNoteId,
      cursor: 0,
      timeoutNanoseconds: 1_000_000
    )
    XCTAssertEqual(failedPoll.chunks, ["failed chunk"])
    XCTAssertGreaterThan(failedPoll.cursor, 0)

    await hub.finish(turnNoteId: evictionTurnNoteId, status: "answered", message: nil)
    _ = await hub.poll(
      turnNoteId: evictionTurnNoteId,
      cursor: 0,
      timeoutNanoseconds: 1_000_000
    )
    let failedStreamRetained = await hub.containsStream(for: turnNoteId)
    XCTAssertFalse(failedStreamRetained)

    await hub.beginLeasedStream(turnNoteId: turnNoteId, lease: retryLease)
    await hub.publish(
      turnNoteId: turnNoteId,
      text: "successful retry chunk",
      libraryId: libraryId,
      lease: retryLease
    )
    await hub.finish(
      turnNoteId: turnNoteId,
      status: "answered",
      message: nil,
      libraryId: libraryId,
      lease: retryLease
    )

    let retryPoll = await hub.poll(
      turnNoteId: turnNoteId,
      cursor: failedPoll.cursor,
      timeoutNanoseconds: 1_000_000
    )
    XCTAssertEqual(retryPoll.chunks, ["successful retry chunk"])
    XCTAssertNotEqual(retryPoll.cursor, failedPoll.cursor)
    XCTAssertTrue(retryPoll.done)
    XCTAssertEqual(retryPoll.status, "answered")
  }

  func testFailedRetryCursorsStayBoundedUnderEvictionPressure() async {
    let hub = AgentReplyStreamHub(maximumRetainedStreams: 1)
    let libraryId = LibraryID("library-default")
    let retryTurnNoteId = NoteID("retry-after-pressure")
    var failedCursor = 0

    for index in 0 ..< 128 {
      let turnNoteId = index == 0 ? retryTurnNoteId : NoteID("failed-pressure-\(index)")
      let failedLease = AgentReplyStreamLease(
        dispatchId: AutoActionDispatchID("dispatch-pressure-\(index)"),
        token: "failed-attempt",
        attemptNumber: 1
      )
      await hub.beginLeasedStream(turnNoteId: turnNoteId, lease: failedLease)
      await hub.publish(
        turnNoteId: turnNoteId,
        text: "failed chunk \(index)",
        libraryId: libraryId,
        lease: failedLease
      )
      await hub.finish(
        turnNoteId: turnNoteId,
        status: "failed",
        message: "retryable provider failure",
        libraryId: libraryId,
        lease: failedLease
      )
      let failedPoll = await hub.poll(
        turnNoteId: turnNoteId,
        cursor: 0,
        timeoutNanoseconds: 1_000_000
      )
      XCTAssertEqual(failedPoll.chunks, ["failed chunk \(index)"])
      let evictionTurnNoteId = NoteID("failed-pressure-eviction-\(index)")
      await hub.finish(turnNoteId: evictionTurnNoteId, status: "answered", message: nil)
      _ = await hub.poll(
        turnNoteId: evictionTurnNoteId,
        cursor: 0,
        timeoutNanoseconds: 1_000_000
      )
      let failedStreamRetained = await hub.containsStream(for: turnNoteId)
      XCTAssertFalse(failedStreamRetained)
      if index == 0 {
        failedCursor = failedPoll.cursor
      }
    }

    let retryLease = AgentReplyStreamLease(
      dispatchId: AutoActionDispatchID("dispatch-pressure-0"),
      token: "successful-retry",
      attemptNumber: 2
    )
    await hub.beginLeasedStream(turnNoteId: retryTurnNoteId, lease: retryLease)
    await hub.publish(
      turnNoteId: retryTurnNoteId,
      text: "successful retry after pressure",
      libraryId: libraryId,
      lease: retryLease
    )
    await hub.finish(
      turnNoteId: retryTurnNoteId,
      status: "answered",
      message: nil,
      libraryId: libraryId,
      lease: retryLease
    )

    let retryPoll = await hub.poll(
      turnNoteId: retryTurnNoteId,
      cursor: failedCursor,
      timeoutNanoseconds: 1_000_000
    )
    XCTAssertEqual(retryPoll.chunks, ["successful retry after pressure"])
    XCTAssertNotEqual(retryPoll.cursor, failedCursor)
    XCTAssertTrue(retryPoll.done)
    await hub.finish(turnNoteId: NoteID("retry-pressure-final-eviction"), status: "answered", message: nil)
    _ = await hub.poll(
      turnNoteId: NoteID("retry-pressure-final-eviction"),
      cursor: 0,
      timeoutNanoseconds: 1_000_000
    )
    let retryStreamRetained = await hub.containsStream(for: retryTurnNoteId)
    XCTAssertFalse(retryStreamRetained)
  }

  func testFailedGenerationAcknowledgementCannotEvictSuccessfulRetry() async {
    let hub = AgentReplyStreamHub(
      maximumRetainedStreams: 0,
      firstTerminalDeliveryGraceNanoseconds: 35_000_000_000,
      graceExpiryScheduling: { _, _ in },
      defersPollResponsesForTesting: false
    )
    let turnNoteId = NoteID("retry-generation-acknowledgement")
    let libraryId = LibraryID("library-default")
    let failedLease = AgentReplyStreamLease(
      dispatchId: AutoActionDispatchID("dispatch-retry-generation"),
      token: "failed-attempt",
      attemptNumber: 1
    )
    let retryLease = AgentReplyStreamLease(
      dispatchId: failedLease.dispatchId,
      token: "retry-attempt",
      attemptNumber: 2
    )

    await hub.beginLeasedStream(turnNoteId: turnNoteId, lease: failedLease)
    await hub.finish(
      turnNoteId: turnNoteId,
      status: "failed",
      message: "retryable provider failure",
      libraryId: libraryId,
      lease: failedLease
    )
    let failedPoll = await hub.poll(
      turnNoteId: turnNoteId,
      cursor: 0,
      timeoutNanoseconds: 1_000_000,
      deferTerminalAcknowledgement: true
    )
    XCTAssertTrue(failedPoll.done)
    XCTAssertEqual(failedPoll.status, "failed")

    await hub.beginLeasedStream(turnNoteId: turnNoteId, lease: retryLease)
    await hub.finish(
      turnNoteId: turnNoteId,
      status: "answered",
      message: nil,
      libraryId: libraryId,
      lease: retryLease
    )

    await hub.acknowledgeTerminalDelivery(
      turnNoteId: turnNoteId,
      poll: failedPoll,
      delivered: true
    )
    let retainedAfterStaleAcknowledgement = await hub.containsStream(for: turnNoteId)
    XCTAssertTrue(retainedAfterStaleAcknowledgement)

    let answeredPoll = await hub.poll(
      turnNoteId: turnNoteId,
      cursor: failedPoll.cursor,
      timeoutNanoseconds: 1_000_000,
      deferTerminalAcknowledgement: true
    )
    XCTAssertTrue(answeredPoll.chunks.isEmpty)
    XCTAssertTrue(answeredPoll.done)
    XCTAssertEqual(answeredPoll.status, "answered")
    await hub.acknowledgeTerminalDelivery(
      turnNoteId: turnNoteId,
      poll: answeredPoll,
      delivered: true
    )
    let retainedAfterAnsweredAcknowledgement = await hub.containsStream(for: turnNoteId)
    XCTAssertFalse(retainedAfterAnsweredAcknowledgement)
  }

  func testWaitingPollersReceiveTerminalTailsAcrossCapacity() async {
    let hub = AgentReplyStreamHub(maximumRetainedStreams: 1)
    let turnIds = (0..<AgentReplyStreamHub.maximumStreams + 2).map { NoteID("turn-\($0)") }
    var polls: [Task<AgentReplyStreamHub.Poll, Never>] = []
    for turnId in turnIds {
      polls.append(Task {
        await hub.poll(turnNoteId: turnId, cursor: 0, timeoutNanoseconds: 2_000_000_000)
      })
      await waitForPolls(on: hub, turnNoteId: turnId, count: 1)
    }

    for turnId in turnIds {
      await hub.publish(turnNoteId: turnId, text: "chunk \(turnId)")
      await hub.finish(turnNoteId: turnId, status: "answered", message: nil)
    }

    for (turnId, task) in zip(turnIds, polls) {
      let poll = await task.value
      XCTAssertTrue(
        poll.chunks == ["chunk \(turnId)"] || (poll.chunks.isEmpty && poll.done && poll.resync),
        "a capacity-evicted payload must still expose a terminal resynchronization response"
      )
      if poll.done {
        continue
      }
      let terminal = await hub.poll(
        turnNoteId: turnId,
        cursor: poll.cursor,
        timeoutNanoseconds: 1_000_000
      )
      XCTAssertTrue(terminal.done)
    }
  }

  func testTurnScopedWakeupDoesNotCompleteAnotherTurnPoll() async {
    let hub = AgentReplyStreamHub()
    let first = Task { await hub.poll(turnNoteId: NoteID("first"), cursor: 0, timeoutNanoseconds: 2_000_000_000) }
    let second = Task { await hub.poll(turnNoteId: NoteID("second"), cursor: 0, timeoutNanoseconds: 2_000_000_000) }
    await waitForPolls(on: hub, turnNoteId: NoteID("first"), count: 1)
    await waitForPolls(on: hub, turnNoteId: NoteID("second"), count: 1)

    await hub.publish(turnNoteId: NoteID("first"), text: "first chunk")
    let firstPoll = await first.value
    XCTAssertEqual(firstPoll.chunks, ["first chunk"])
    let secondPending = await hub.pendingPollCount(for: NoteID("second"))
    XCTAssertEqual(secondPending, 1)
    second.cancel()
    _ = await second.value
  }

  func testTerminalRetentionEvictsOnlyDeliveredTerminalStreamsOldestFirst() async {
    let hub = AgentReplyStreamHub(maximumRetainedStreams: 1)

    await hub.finish(turnNoteId: NoteID("first"), status: "answered", message: nil)
    let first = await hub.poll(turnNoteId: NoteID("first"), cursor: 0, timeoutNanoseconds: 1_000_000)
    XCTAssertTrue(first.done)

    await hub.finish(turnNoteId: NoteID("second"), status: "answered", message: nil)
    let second = await hub.poll(turnNoteId: NoteID("second"), cursor: 0, timeoutNanoseconds: 1_000_000)
    XCTAssertTrue(second.done)

    let evicted = await hub.poll(turnNoteId: NoteID("first"), cursor: 0, timeoutNanoseconds: 1_000_000)
    XCTAssertFalse(evicted.done)
    XCTAssertTrue(evicted.chunks.isEmpty)
  }

  func testTerminalGraceRetainsNoPollerStreamUntilExpiry() async {
    let hub = AgentReplyStreamHub(
      maximumRetainedStreams: 0,
      firstTerminalDeliveryGraceNanoseconds: 1_000_000
    )
    await hub.finish(turnNoteId: NoteID("turn"), status: "answered", message: nil)

    let immediate = await hub.poll(turnNoteId: NoteID("turn"), cursor: 0, timeoutNanoseconds: 1_000_000)
    XCTAssertTrue(immediate.done)
  }

  func testNoPollerGraceExpirySchedulesEligibleCleanup() async {
    let scheduler = ManualGraceExpiryScheduler()
    let hub = AgentReplyStreamHub(
      maximumRetainedStreams: 0,
      firstTerminalDeliveryGraceNanoseconds: 35_000_000_000,
      graceExpiryScheduling: scheduler.schedule
    )
    await hub.finish(turnNoteId: NoteID("turn"), status: "answered", message: nil)
    let retainedBeforeExpiry = await hub.containsStream(for: NoteID("turn"))
    XCTAssertTrue(retainedBeforeExpiry)
    scheduler.fireAll()
    await waitForStream(on: hub, turnNoteId: NoteID("turn"), exists: false)
    let retainedAfterExpiry = await hub.containsStream(for: NoteID("turn"))
    XCTAssertFalse(retainedAfterExpiry)
  }

  func testCancelledPollReleasesObligationWithoutSatisfyingGrace() async {
    let scheduler = ManualGraceExpiryScheduler()
    let hub = AgentReplyStreamHub(
      maximumRetainedStreams: 0,
      firstTerminalDeliveryGraceNanoseconds: 35_000_000_000,
      graceExpiryScheduling: scheduler.schedule,
      defersPollResponsesForTesting: true
    )
    let poll = Task {
      // The deferred-response handshake below owns this test's completion
      // ordering. Keep the ordinary poll deadline outside that interleaving
      // so full-suite scheduler load cannot turn it into terminal delivery.
      await hub.poll(turnNoteId: NoteID("turn"), cursor: 0, timeoutNanoseconds: 60_000_000_000)
    }
    await waitForPolls(on: hub, turnNoteId: NoteID("turn"), count: 1)
    await hub.finish(turnNoteId: NoteID("turn"), status: "answered", message: nil)
    await hub.waitForDeferredPollResponseRegistration()
    poll.cancel()
    _ = await poll.value

    let retainedBeforeDeadline = await hub.containsStream(for: NoteID("turn"))
    XCTAssertTrue(retainedBeforeDeadline, "cancellation must not satisfy first terminal delivery")
    scheduler.fireAll()
    await waitForStream(on: hub, turnNoteId: NoteID("turn"), exists: false)
    let retainedAfterDeadline = await hub.containsStream(for: NoteID("turn"))
    XCTAssertFalse(retainedAfterDeadline)
  }

  func testBetweenPollTerminalSnapshotAndTemporaryExcessRetention() async {
    let hub = AgentReplyStreamHub(
      maximumRetainedStreams: 1,
      firstTerminalDeliveryGraceNanoseconds: 1_000_000_000
    )
    await hub.publish(turnNoteId: NoteID("first"), text: "partial")
    let partial = await hub.poll(turnNoteId: NoteID("first"), cursor: 0, timeoutNanoseconds: 1_000_000)
    XCTAssertFalse(partial.done)
    await hub.finish(turnNoteId: NoteID("first"), status: "answered", message: nil)
    await hub.finish(turnNoteId: NoteID("second"), status: "answered", message: nil)
    let firstProtected = await hub.containsStream(for: NoteID("first"))
    let secondProtected = await hub.containsStream(for: NoteID("second"))
    XCTAssertTrue(firstProtected)
    XCTAssertTrue(secondProtected)

    let terminal = await hub.poll(turnNoteId: NoteID("first"), cursor: partial.cursor, timeoutNanoseconds: 1_000_000)
    XCTAssertTrue(terminal.done)
    _ = await hub.poll(turnNoteId: NoteID("second"), cursor: 0, timeoutNanoseconds: 1_000_000)
    let firstEvicted = await hub.containsStream(for: NoteID("first"))
    let secondRetained = await hub.containsStream(for: NoteID("second"))
    XCTAssertFalse(firstEvicted)
    XCTAssertTrue(secondRetained)
  }

  func testLeasedActiveStreamSurvivesCapacityPressureAndFinishesPendingPoll() async {
    let hub = AgentReplyStreamHub(maximumRetainedStreams: 1)
    let victim = NoteID("leased-capacity-victim")
    let lease = AgentReplyStreamLease(
      dispatchId: AutoActionDispatchID("leased-capacity-dispatch"),
      token: "leased-capacity-token",
      attemptNumber: 1
    )
    await hub.beginLeasedStream(turnNoteId: victim, lease: lease)
    let pollTask = Task {
      await hub.poll(turnNoteId: victim, cursor: 0, timeoutNanoseconds: 2_000_000_000)
    }
    await waitForPolls(on: hub, turnNoteId: victim, count: 1)

    await hub.publish(turnNoteId: NoteID("capacity-pressure-a"), text: "a")
    await hub.publish(turnNoteId: NoteID("capacity-pressure-b"), text: "b")
    let victimRetained = await hub.containsStream(for: victim)
    XCTAssertTrue(victimRetained)

    await hub.finish(
      turnNoteId: victim,
      status: "answered",
      message: nil,
      libraryId: LibraryID("library-default"),
      lease: lease
    )
    let poll = await pollTask.value
    XCTAssertTrue(poll.done)
    XCTAssertEqual(poll.status, "answered")
  }

  func testHungLeasedStreamsBoundPayloadAndPreservePendingTerminalDelivery() async {
    let hub = AgentReplyStreamHub(maximumRetainedStreams: 1)
    let victim = NoteID("bounded-leased-victim")
    let victimLease = AgentReplyStreamLease(
      dispatchId: AutoActionDispatchID("bounded-leased-victim-dispatch"),
      token: "bounded-leased-victim-token",
      attemptNumber: 1
    )
    await hub.beginLeasedStream(turnNoteId: victim, lease: victimLease)
    await hub.publish(
      turnNoteId: victim,
      text: "already delivered",
      libraryId: LibraryID("library-default"),
      lease: victimLease
    )
    let partial = await hub.poll(turnNoteId: victim, cursor: 0, timeoutNanoseconds: 1_000_000)
    let pending = Task {
      await hub.poll(turnNoteId: victim, cursor: partial.cursor, timeoutNanoseconds: 2_000_000_000)
    }
    await waitForPolls(on: hub, turnNoteId: victim, count: 1)

    for index in 0..<3 {
      let turnNoteId = NoteID("bounded-hung-lease-\(index)")
      let lease = AgentReplyStreamLease(
        dispatchId: AutoActionDispatchID("bounded-hung-dispatch-\(index)"),
        token: "bounded-hung-token-\(index)",
        attemptNumber: 1
      )
      await hub.beginLeasedStream(turnNoteId: turnNoteId, lease: lease)
      for _ in 0..<4 {
        await hub.publish(
          turnNoteId: turnNoteId,
          text: String(repeating: "x", count: 4_096),
          libraryId: LibraryID("library-default"),
          lease: lease
        )
      }
    }

    let retainedChunkCount = await hub.retainedChunkCount()
    let retainedChunkByteCount = await hub.retainedChunkByteCount()
    let victimRetained = await hub.containsStream(for: victim)
    XCTAssertLessThanOrEqual(retainedChunkCount, 4)
    XCTAssertLessThanOrEqual(retainedChunkByteCount, 16_384)
    XCTAssertTrue(victimRetained)

    await hub.finish(
      turnNoteId: victim,
      status: "answered",
      message: nil,
      libraryId: LibraryID("library-default"),
      lease: victimLease
    )
    let terminal = await pending.value
    XCTAssertTrue(terminal.done)
    XCTAssertEqual(terminal.status, "answered")
    XCTAssertTrue(terminal.resync)
  }

  func testPayloadBoundsEmptyAndTinyChunksWithoutQuadraticAccounting() async {
    let hub = AgentReplyStreamHub(maximumRetainedStreams: 1)
    let turnNoteId = NoteID("empty-and-tiny-chunks")

    for _ in 0..<300 {
      await hub.publish(turnNoteId: turnNoteId, text: "")
    }
    let retainedAfterEmptyChunks = await hub.retainedChunkCount()
    let retainedBytesAfterEmptyChunks = await hub.retainedChunkByteCount()
    XCTAssertLessThanOrEqual(
      retainedAfterEmptyChunks,
      AgentReplyStreamHub.maximumRetainedChunksPerStream
    )
    XCTAssertEqual(retainedBytesAfterEmptyChunks, 0)

    for _ in 0..<300 {
      await hub.publish(turnNoteId: turnNoteId, text: "x")
    }
    let retainedAfterTinyChunks = await hub.retainedChunkCount()
    let retainedBytesAfterTinyChunks = await hub.retainedChunkByteCount()
    XCTAssertLessThanOrEqual(
      retainedAfterTinyChunks,
      AgentReplyStreamHub.maximumRetainedChunksPerStream
    )
    XCTAssertLessThanOrEqual(retainedBytesAfterTinyChunks, 256)
    let poll = await hub.poll(turnNoteId: turnNoteId, cursor: 0, timeoutNanoseconds: 1_000_000)
    XCTAssertTrue(poll.resync)
  }

  func testPendingPollCapacityRejectsThirdConcurrentPollForOneTurn() async {
    let hub = AgentReplyStreamHub()
    let turnNoteId = NoteID("waiter-capacity-turn")
    let first = Task {
      await hub.poll(turnNoteId: turnNoteId, cursor: 0, timeoutNanoseconds: 5_000_000_000)
    }
    let second = Task {
      await hub.poll(turnNoteId: turnNoteId, cursor: 0, timeoutNanoseconds: 5_000_000_000)
    }
    await waitForPolls(on: hub, turnNoteId: turnNoteId, count: 2)

    let rejected = await hub.poll(turnNoteId: turnNoteId, cursor: 0, timeoutNanoseconds: 0)
    XCTAssertEqual(rejected.status, "overloaded")
    first.cancel()
    second.cancel()
    _ = await first.value
    _ = await second.value
  }

  private func waitForPolls(
    on hub: AgentReplyStreamHub,
    turnNoteId: NoteID,
    count: Int
  ) async {
    for _ in 0..<100 {
      if await hub.pendingPollCount(for: turnNoteId) == count { return }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("timed out waiting for \(count) polls on \(turnNoteId)")
  }

  private func waitForStream(
    on hub: AgentReplyStreamHub,
    turnNoteId: NoteID,
    exists: Bool
  ) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while await hub.containsStream(for: turnNoteId) != exists {
      guard clock.now < deadline else {
        XCTFail("timed out waiting for stream \(turnNoteId) existence \(exists)")
        return
      }
      try? await clock.sleep(for: .milliseconds(1))
    }
  }

  private func makeService(function: String = #function) throws -> NoteService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/AppServerTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
  }

}
