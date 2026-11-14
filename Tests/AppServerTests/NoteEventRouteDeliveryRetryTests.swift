import Foundation

import AppCore
@testable import AppServer
import XCTest

private struct DeliveryRetryEventAuthenticator: NoteAPIAuthenticating {
  let userId: UserID

  func authenticate(
    request _: ServerRequestEnvelope,
    context _: ServerRequestContext
  ) async -> NoteAPIAuthenticationResult {
    .accepted(NoteAPIAuthenticatedClient(
      clientId: APIClientID("delivery-retry-client"),
      displayName: "Alice",
      userId: userId
    ))
  }
}

final class NoteEventRouteDeliveryRetryTests: XCTestCase {
  func testEventFeedReplaysOwnerEventWhenFirstHTTPResponseIsDropped() async throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let note = try service.scoped(to: alice.userId).createNote(bodyMarkdown: "# Alice\nPrivate")
    let feed = NoteChangeFeed()
    let handler = makeHandler(service: service, feed: feed, userId: alice.userId)
    let cursor = try await eventCursor(handler: handler)
    let firstEvent = NoteChangeEvent(
      kind: NoteChangeEventKind.noteUpdated,
      notebookId: note.notebookId,
      tagNames: ["first"]
    )
    await feed.publish(firstEvent)

    // The transport may drop a successful response after the route has
    // prepared it. Do not inspect this response as a client would not have it.
    _ = await handler.route(pollRequest(since: cursor), context: .init(serviceName: "test"))
    let replay = await handler.route(pollRequest(since: cursor), context: .init(serviceName: "test"))
    XCTAssertEqual(replay.status, 200)
    XCTAssertEqual(replay.body["events"], expectedEvents(notebookId: note.notebookId, tagName: "first"))
    guard case let .string(successor)? = replay.body["revision"] else {
      return XCTFail("expected successor cursor")
    }
    XCTAssertNotEqual(successor, cursor)

    let secondEvent = NoteChangeEvent(
      kind: NoteChangeEventKind.noteUpdated,
      notebookId: note.notebookId,
      tagNames: ["second"]
    )
    await feed.publish(secondEvent)
    let acknowledged = await handler.route(pollRequest(since: successor), context: .init(serviceName: "test"))
    XCTAssertEqual(acknowledged.status, 200)
    XCTAssertEqual(acknowledged.body["events"], expectedEvents(notebookId: note.notebookId, tagName: "second"))
  }

  func testEventFeedOverlappingSameCursorPollsReplayTheSameOwnerEvent() async throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let note = try service.scoped(to: alice.userId).createNote(bodyMarkdown: "# Alice\nPrivate")
    let feed = NoteChangeFeed()
    let handler = makeHandler(service: service, feed: feed, userId: alice.userId)
    let cursor = try await eventCursor(handler: handler)
    let request = pollRequest(since: cursor, timeoutMilliseconds: 1_000)
    let context = ServerRequestContext(serviceName: "test")
    async let first = handler.route(request, context: context)
    async let second = handler.route(request, context: context)
    let activePolls = try await waitForActivePollCount(2, in: feed)
    XCTAssertEqual(activePolls, 2)

    await feed.publish(NoteChangeEvent(
      kind: NoteChangeEventKind.noteUpdated,
      notebookId: note.notebookId,
      tagNames: ["overlap"]
    ))
    let responses = await [first, second]

    XCTAssertEqual(responses.map(\.status), [200, 200])
    let expected = expectedEvents(notebookId: note.notebookId, tagName: "overlap")
    XCTAssertEqual(responses.map { $0.body["events"] }, [expected, expected])
    XCTAssertEqual(responses[0].body["revision"], responses[1].body["revision"])
    XCTAssertNotEqual(responses[0].body["revision"], .string(cursor))
  }

  func testEventFeedReplayHidesBatchAfterLibraryMembershipRevocation() async throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let library = try service.scoped(to: alice.userId).createLibrary(
      name: "alice-private", authRequired: true
    )
    let notebook = try service.scoped(to: alice.userId)
      .scoped(toLibrary: library.libraryId)
      .createNotebook(title: "Alice private notebook")
    let feed = NoteChangeFeed()
    let handler = makeHandler(service: service, feed: feed, userId: alice.userId)
    let cursor = try await eventCursor(handler: handler)
    await feed.publish(NoteChangeEvent(
      kind: NoteChangeEventKind.noteUpdated,
      notebookId: notebook.notebookId,
      tagNames: ["private"]
    ))

    _ = await handler.route(pollRequest(since: cursor), context: .init(serviceName: "test"))
    try service.revokeLibraryAccess(libraryName: library.name, userId: alice.userId)

    let replay = await handler.route(pollRequest(since: cursor), context: .init(serviceName: "test"))
    XCTAssertEqual(replay.status, 200)
    XCTAssertEqual(replay.body["events"], .array([]))
    XCTAssertEqual(replay.body["resync"], .bool(false))
  }

  private func makeHandler(
    service: NoteService,
    feed: NoteChangeFeed,
    userId: UserID
  ) -> DeterministicServerRouteHandler {
    DeterministicServerRouteHandler(
      noteAPIAuthenticator: DeliveryRetryEventAuthenticator(userId: userId),
      noteService: service,
      noteChangeFeed: feed
    )
  }

  private func eventCursor(handler: DeterministicServerRouteHandler) async throws -> String {
    let response = await handler.route(pollRequest(since: "0"), context: .init(serviceName: "test"))
    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.body["resync"], .bool(true))
    guard case let .string(cursor)? = response.body["revision"] else {
      throw NoteServiceError.invalidRow("event reset response has no opaque cursor")
    }
    return cursor
  }

  private func pollRequest(
    since: String,
    timeoutMilliseconds: UInt64 = 0
  ) -> ServerRequestEnvelope {
    ServerRequestEnvelope(
      method: "GET",
      path: "/note/events",
      headers: ["Authorization": "Bearer delivery-retry"],
      query: "since=\(since)&timeoutMs=\(timeoutMilliseconds)"
    )
  }

  private func expectedEvents(notebookId: NotebookID, tagName: String) -> JSONValue {
    .array([.object([
      "kind": .string(NoteChangeEventKind.noteUpdated),
      "notebookId": .string(notebookId.rawValue),
      "tagNames": .array([.string(tagName)])
    ])])
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

  private func makeService(function: String = #function) throws -> NoteService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/AppServerTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
  }
}
