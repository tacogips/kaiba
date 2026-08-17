import AppCore
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

final class AgentReplyStreamHubTests: XCTestCase {
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
      XCTAssertEqual(poll.chunks, ["chunk \(turnId)"])
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
      await hub.poll(turnNoteId: NoteID("turn"), cursor: 0, timeoutNanoseconds: 2_000_000_000)
    }
    await waitForPolls(on: hub, turnNoteId: NoteID("turn"), count: 1)
    await hub.finish(turnNoteId: NoteID("turn"), status: "answered", message: nil)
    await waitForDeferredPollResponses(on: hub, count: 1)
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
    for _ in 0..<100 {
      if await hub.containsStream(for: turnNoteId) == exists { return }
      await Task.yield()
    }
    XCTFail("timed out waiting for stream \(turnNoteId) existence \(exists)")
  }

  private func waitForDeferredPollResponses(on hub: AgentReplyStreamHub, count: Int) async {
    for _ in 0..<100 {
      if await hub.deferredPollResponseCount() == count { return }
      await Task.yield()
    }
    XCTFail("timed out waiting for \(count) deferred poll responses")
  }
}
