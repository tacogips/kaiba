import AppCore
@testable import AppServer
import XCTest

final class NoteChangeFeedOverflowTests: XCTestCase {
  func testOverflowResyncStaysPrincipalLocal() async throws {
    let feed = NoteChangeFeed()
    let event = NoteChangeEvent(kind: NoteChangeEventKind.noteUpdated)
    let allowEvents: @Sendable (NoteChangeEvent) throws -> Bool = { _ in true }
    let rejectEvents: @Sendable (NoteChangeEvent) throws -> Bool = { _ in false }
    let aliceCursor = try await feed.poll(
      since: "0", principalId: "alice", timeoutNanoseconds: 0, eventAuthorizer: allowEvents
    ).revision
    let bobCursor = try await feed.poll(
      since: "0", principalId: "bob", timeoutNanoseconds: 0, eventAuthorizer: rejectEvents
    ).revision
    let bobPoll = Task<NoteChangeFeedPoll?, Never> {
      try? await feed.poll(
        since: bobCursor, principalId: "bob", timeoutNanoseconds: 300_000_000, eventAuthorizer: rejectEvents
      )
    }
    let activePollsBeforeOverflow = try await waitForActivePollCount(1, in: feed)
    XCTAssertEqual(activePollsBeforeOverflow, 1)

    for _ in 0 ... NoteChangeFeed.maximumPendingEventsPerCursor {
      await feed.publish(event)
    }

    let activePollsAfterOverflow = await feed.activePollCount
    XCTAssertEqual(activePollsAfterOverflow, 1)
    let aliceResponse = try await feed.poll(
      since: aliceCursor, principalId: "alice", timeoutNanoseconds: 0, eventAuthorizer: allowEvents
    )
    let bobResponse = await bobPoll.value

    XCTAssertNotEqual(aliceResponse.revision, aliceCursor)
    XCTAssertTrue(aliceResponse.resync)
    XCTAssertEqual(aliceResponse.events, [])
    XCTAssertEqual(bobResponse?.revision, bobCursor)
    XCTAssertFalse(bobResponse?.resync ?? true)
    XCTAssertEqual(bobResponse?.events, [])
  }

  func testWaiterCapacityRejectsThirdConcurrentPollForOneCursor() async throws {
    let feed = NoteChangeFeed()
    let authorizer: @Sendable (NoteChangeEvent) throws -> Bool = { _ in true }
    let cursor = try await feed.poll(
      since: "0", principalId: "alice", timeoutNanoseconds: 0, eventAuthorizer: authorizer
    ).revision
    let first = Task { try? await feed.poll(
      since: cursor, principalId: "alice", timeoutNanoseconds: 5_000_000_000, eventAuthorizer: authorizer
    ) }
    let second = Task { try? await feed.poll(
      since: cursor, principalId: "alice", timeoutNanoseconds: 5_000_000_000, eventAuthorizer: authorizer
    ) }
    let activePollCount = try await waitForActivePollCount(2, in: feed)
    XCTAssertEqual(activePollCount, 2)

    do {
      _ = try await feed.poll(
        since: cursor, principalId: "alice", timeoutNanoseconds: 0, eventAuthorizer: authorizer
      )
      XCTFail("expected waiter capacity rejection")
    } catch NoteChangeFeedError.waiterCapacityReached {
      // Expected: excess waits are refused instead of retaining continuations.
    }
    first.cancel()
    second.cancel()
    _ = await first.value
    _ = await second.value
  }

  private func waitForActivePollCount(
    _ expectedCount: Int,
    in feed: NoteChangeFeed,
    timeout: Duration = .seconds(1)
  ) async throws -> Int {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      let actualCount = await feed.activePollCount
      if actualCount == expectedCount {
        return actualCount
      }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    return await feed.activePollCount
  }
}
