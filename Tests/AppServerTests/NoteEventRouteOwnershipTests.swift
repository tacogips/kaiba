import Foundation

import AppCore
@testable import AppServer
import XCTest

private struct EventRouteAuthenticator: NoteAPIAuthenticating {
  var usersByToken: [String: UserID]
  var clientIdsByToken: [String: APIClientID] = [:]

  func authenticate(
    request _: ServerRequestEnvelope,
    context: ServerRequestContext
  ) async -> NoteAPIAuthenticationResult {
    guard let token = context.bearerToken, let userId = usersByToken[token] else {
      return .rejected(noteAPIUnauthorizedResponse("note API bearer token is invalid or revoked"))
    }
    return .accepted(NoteAPIAuthenticatedClient(
      clientId: clientIdsByToken[token] ?? APIClientID("client-\(userId.rawValue)"),
      displayName: userId.rawValue,
      userId: userId
    ))
  }
}

private struct FailingEventAuthorizationDriver: NoteDatabaseDriving {
  let databasePath = "injected-event-authorization-failure"

  func withDatabase<T>(_: (SQLiteDatabase) throws -> T) throws -> T {
    throw NoteServiceError.invalidRow("injected event authorization failure")
  }
}

private final class FailOnceEventAuthorizationDriver: NoteDatabaseDriving, @unchecked Sendable {
  let databasePath: String
  private let backing: any NoteDatabaseDriving
  private let failureCall: Int
  private let lock = NSLock()
  private var callCount = 0

  init(backing: any NoteDatabaseDriving, failureCall: Int) {
    databasePath = backing.databasePath
    self.backing = backing
    self.failureCall = failureCall
  }

  func withDatabase<T>(_ body: (SQLiteDatabase) throws -> T) throws -> T {
    lock.lock()
    callCount += 1
    let fail = callCount == failureCall
    lock.unlock()
    if fail {
      throw NoteServiceError.invalidRow("injected one-time event authorization failure")
    }
    return try backing.withDatabase(body)
  }
}

private actor PausingStreamingReplyInvoker: AgentStreamingInvoking {
  private var emittedChunk = false
  private var chunkWaiters: [CheckedContinuation<Void, Never>] = []
  private var release: CheckedContinuation<Void, Never>?

  func invoke(_: AgentInvocationRequest) async throws -> AgentInvocationResult {
    AgentInvocationResult(markdown: "protected streamed reply")
  }

  func invoke(
    _: AgentInvocationRequest,
    onChunk: @escaping @Sendable (String) -> Bool
  ) async throws -> AgentInvocationResult {
    _ = onChunk("protected streamed chunk")
    emittedChunk = true
    let waiters = chunkWaiters
    chunkWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation { continuation in
      release = continuation
    }
    return AgentInvocationResult(markdown: "protected streamed reply")
  }

  func waitUntilChunkEmitted() async {
    guard !emittedChunk else { return }
    await withCheckedContinuation { continuation in
      chunkWaiters.append(continuation)
    }
  }

  func resume() {
    release?.resume()
    release = nil
  }
}

private actor PausingFailingStreamingReplyInvoker: AgentStreamingInvoking {
  private var started = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var release: CheckedContinuation<Void, Never>?

  func invoke(_: AgentInvocationRequest) async throws -> AgentInvocationResult {
    throw NSError(domain: "sensitive-provider-sentinel", code: 1)
  }

  func invoke(
    _: AgentInvocationRequest,
    onChunk _: @escaping @Sendable (String) -> Bool
  ) async throws -> AgentInvocationResult {
    started = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation { continuation in
      release = continuation
    }
    throw NSError(domain: "sensitive-provider-sentinel", code: 1)
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func resume() {
    release?.resume()
    release = nil
  }
}

final class NoteEventRouteOwnershipTests: XCTestCase {
  func testEventFeedDropsForeignNotebookMetadata() async throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let bob = try service.createUser(email: "bob@example.com", displayName: "Bob")
    let aliceNote = try service.scoped(to: alice.userId).createNote(bodyMarkdown: "# Alice\nPrivate")
    let bobNote = try service.scoped(to: bob.userId).createNote(bodyMarkdown: "# Bob\nPrivate")
    let feed = NoteChangeFeed()
    let handler = DeterministicServerRouteHandler(
      noteAPIAuthenticator: EventRouteAuthenticator(usersByToken: ["alice": alice.userId]),
      noteService: service,
      noteChangeFeed: feed
    )
    let cursor = try await eventCursor(
      handler: handler,
      request: request(path: "/note/events", token: "alice", query: "since=0&timeoutMs=0")
    )
    await feed.publish(NoteChangeEvent(
      kind: NoteChangeEventKind.noteUpdated,
      notebookId: bobNote.notebookId,
      tagNames: ["bob-private"]
    ))
    await feed.publish(NoteChangeEvent(
      kind: NoteChangeEventKind.noteUpdated,
      notebookId: aliceNote.notebookId,
      tagNames: ["alice-visible"]
    ))

    let response = await handler.route(
      request(path: "/note/events", token: "alice", query: "since=\(cursor)&timeoutMs=0"),
      context: .init(serviceName: "test")
    )

    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.headers["Cache-Control"], "private, no-store")
    XCTAssertEqual(response.body["events"], .array([.object([
      "kind": .string(NoteChangeEventKind.noteUpdated),
      "notebookId": .string(aliceNote.notebookId.rawValue),
      "tagNames": .array([.string("alice-visible")])
    ])]))
  }

  func testEventFeedDeliversDeletedNotebookOnlyToItsOwner() async throws {
    let feed = NoteChangeFeed()
    let service = try makeService(changeObserver: NoteChangeFeedObserver(feed: feed))
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let bob = try service.createUser(email: "bob@example.com", displayName: "Bob")
    let notebook = try service.scoped(to: alice.userId).createNotebook(title: "Alice private")
    let handler = DeterministicServerRouteHandler(
      noteAPIAuthenticator: EventRouteAuthenticator(usersByToken: ["alice": alice.userId, "bob": bob.userId]),
      noteService: service,
      noteChangeFeed: feed
    )
    let aliceCursor = try await eventCursor(
      handler: handler,
      request: request(path: "/note/events", token: "alice", query: "since=0&timeoutMs=0")
    )
    let bobCursor = try await eventCursor(
      handler: handler,
      request: request(path: "/note/events", token: "bob", query: "since=0&timeoutMs=0")
    )
    let beforeDeletion = await feed.currentRevision
    try service.scoped(to: alice.userId).deleteNotebook(notebookId: notebook.notebookId)
    let revisionAfterDeletion = try await waitForFeedRevision(in: feed, after: beforeDeletion)
    XCTAssertNotEqual(revisionAfterDeletion, beforeDeletion)
    let aliceResponse = await handler.route(
      request(path: "/note/events", token: "alice", query: "since=\(aliceCursor)&timeoutMs=0"),
      context: .init(serviceName: "test")
    )
    let bobResponse = await handler.route(
      request(path: "/note/events", token: "bob", query: "since=\(bobCursor)&timeoutMs=0"),
      context: .init(serviceName: "test")
    )

    XCTAssertEqual(aliceResponse.status, 200)
    XCTAssertEqual(aliceResponse.body["events"], .array([.object([
      "kind": .string(NoteChangeEventKind.notebookDeleted),
      "notebookId": .string(notebook.notebookId.rawValue),
      "tagNames": .array([])
    ])]))
    XCTAssertEqual(bobResponse.status, 200)
    XCTAssertEqual(bobResponse.body["events"], .array([]))
  }

  func testUnauthenticatedEventFeedHidesDeletedAuthRequiredNotebook() async throws {
    let feed = NoteChangeFeed()
    let service = try makeService(changeObserver: NoteChangeFeedObserver(feed: feed))
    let privateLibrary = try service.createLibrary(name: "private", authRequired: true)
    let notebook = try service.scoped(to: NoteStoreSchema.defaultUserId)
      .scoped(toLibrary: privateLibrary.libraryId)
      .createNotebook(title: "Private default notebook")
    let handler = DeterministicServerRouteHandler(
      allowUnauthenticatedNoteAPI: true,
      noteService: service,
      noteChangeFeed: feed
    )
    let cursor = try await eventCursor(
      handler: handler,
      request: ServerRequestEnvelope(method: "GET", path: "/note/events", query: "since=0&timeoutMs=0")
    )
    let beforeDeletion = await feed.currentRevision
    try service.scoped(to: NoteStoreSchema.defaultUserId).deleteNotebook(notebookId: notebook.notebookId)
    let revisionAfterDeletion = try await waitForFeedRevision(in: feed, after: beforeDeletion)
    XCTAssertNotEqual(revisionAfterDeletion, beforeDeletion)

    let response = await handler.route(
      ServerRequestEnvelope(
        method: "GET",
        path: "/note/events",
        query: "since=\(cursor)&timeoutMs=0"
      ),
      context: .init(serviceName: "test")
    )

    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.body["events"], .array([]))
  }

  func testEventFeedHidesDeletedNotebookAfterLibraryMembershipRevocation() async throws {
    let feed = NoteChangeFeed()
    let service = try makeService(changeObserver: NoteChangeFeedObserver(feed: feed))
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let privateLibrary = try service.scoped(to: alice.userId)
      .createLibrary(name: "alice-private", authRequired: true)
    let notebook = try service.scoped(to: alice.userId)
      .scoped(toLibrary: privateLibrary.libraryId)
      .createNotebook(title: "Alice private notebook")
    let handler = DeterministicServerRouteHandler(
      noteAPIAuthenticator: EventRouteAuthenticator(usersByToken: ["alice": alice.userId]),
      noteService: service,
      noteChangeFeed: feed
    )
    let cursor = try await eventCursor(
      handler: handler,
      request: request(path: "/note/events", token: "alice", query: "since=0&timeoutMs=0")
    )
    let beforeDeletion = await feed.currentRevision
    try service.scoped(to: alice.userId).deleteNotebook(notebookId: notebook.notebookId)
    let revisionAfterDeletion = try await waitForFeedRevision(in: feed, after: beforeDeletion)
    XCTAssertNotEqual(revisionAfterDeletion, beforeDeletion)
    try service.revokeLibraryAccess(libraryName: privateLibrary.name, userId: alice.userId)

    let response = await handler.route(
      request(path: "/note/events", token: "alice", query: "since=\(cursor)&timeoutMs=0"),
      context: .init(serviceName: "test")
    )

    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.body["events"], .array([]))
  }

  func testEventFeedReturnsServerErrorWhenAuthorizationReadFails() async throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let feed = NoteChangeFeed()
    var failingService = service
    failingService.driver = FailingEventAuthorizationDriver()
    let handler = DeterministicServerRouteHandler(
      noteAPIAuthenticator: EventRouteAuthenticator(usersByToken: ["alice": alice.userId]),
      noteService: failingService,
      noteChangeFeed: feed
    )

    let cursor = try await eventCursor(
      handler: handler,
      request: request(path: "/note/events", token: "alice", query: "since=0&timeoutMs=0")
    )
    await feed.publish(NoteChangeEvent(
      kind: NoteChangeEventKind.noteUpdated,
      notebookId: NotebookID.generate(),
      tagNames: ["must-not-advance"]
    ))

    let response = await handler.route(
      request(path: "/note/events", token: "alice", query: "since=\(cursor)&timeoutMs=0"),
      context: .init(serviceName: "test")
    )

    XCTAssertEqual(response.status, 500)
    XCTAssertEqual(response.body, ["error": .string("note event authorization failed")])
    XCTAssertNil(response.body["revision"])
  }

  func testEventFeedRetainsEventsAfterPublicationAuthorizationFailure() async throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let aliceNote = try service.scoped(to: alice.userId).createNote(bodyMarkdown: "# Alice\nPrivate")
    let feed = NoteChangeFeed()
    var failingService = service
    failingService.driver = FailOnceEventAuthorizationDriver(backing: service.driver, failureCall: 1)
    let handler = DeterministicServerRouteHandler(
      noteAPIAuthenticator: EventRouteAuthenticator(usersByToken: ["alice": alice.userId]),
      noteService: failingService,
      noteChangeFeed: feed
    )
    let cursor = try await eventCursor(
      handler: handler,
      request: request(path: "/note/events", token: "alice", query: "since=0&timeoutMs=0")
    )
    await feed.publish(NoteChangeEvent(
      kind: NoteChangeEventKind.noteUpdated,
      notebookId: aliceNote.notebookId,
      tagNames: ["alice-visible"]
    ))

    let failedResponse = await handler.route(
      request(path: "/note/events", token: "alice", query: "since=\(cursor)&timeoutMs=0"),
      context: .init(serviceName: "test")
    )
    let retryResponse = await handler.route(
      request(path: "/note/events", token: "alice", query: "since=\(cursor)&timeoutMs=0"),
      context: .init(serviceName: "test")
    )

    XCTAssertEqual(failedResponse.status, 500)
    XCTAssertNil(failedResponse.body["revision"])
    XCTAssertEqual(retryResponse.status, 200)
    XCTAssertNotEqual(retryResponse.body["revision"], .string(cursor))
    XCTAssertEqual(retryResponse.body["resync"], .bool(false))
    XCTAssertEqual(retryResponse.body["events"], .array([.object([
      "kind": .string(NoteChangeEventKind.noteUpdated),
      "notebookId": .string(aliceNote.notebookId.rawValue),
      "tagNames": .array([.string("alice-visible")])
    ])]))
  }

  func testEventFeedRetainsEventsAfterDeliveryAuthorizationFailure() async throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let aliceNote = try service.scoped(to: alice.userId).createNote(bodyMarkdown: "# Alice\nPrivate")
    let feed = NoteChangeFeed()
    var failingService = service
    failingService.driver = FailOnceEventAuthorizationDriver(backing: service.driver, failureCall: 2)
    let handler = DeterministicServerRouteHandler(
      noteAPIAuthenticator: EventRouteAuthenticator(usersByToken: ["alice": alice.userId]),
      noteService: failingService,
      noteChangeFeed: feed
    )
    let cursor = try await eventCursor(
      handler: handler,
      request: request(path: "/note/events", token: "alice", query: "since=0&timeoutMs=0")
    )
    await feed.publish(NoteChangeEvent(
      kind: NoteChangeEventKind.noteUpdated,
      notebookId: aliceNote.notebookId,
      tagNames: ["alice-visible"]
    ))

    let failedResponse = await handler.route(
      request(path: "/note/events", token: "alice", query: "since=\(cursor)&timeoutMs=0"),
      context: .init(serviceName: "test")
    )
    let retryResponse = await handler.route(
      request(path: "/note/events", token: "alice", query: "since=\(cursor)&timeoutMs=0"),
      context: .init(serviceName: "test")
    )

    XCTAssertEqual(failedResponse.status, 500)
    XCTAssertNil(failedResponse.body["revision"])
    XCTAssertEqual(retryResponse.status, 200)
    XCTAssertNotEqual(retryResponse.body["revision"], .string(cursor))
    XCTAssertEqual(retryResponse.body["resync"], .bool(false))
    XCTAssertEqual(retryResponse.body["events"], .array([.object([
      "kind": .string(NoteChangeEventKind.noteUpdated),
      "notebookId": .string(aliceNote.notebookId.rawValue),
      "tagNames": .array([.string("alice-visible")])
    ])]))
  }

  func testEventFeedReportsAuthorizationFailureBeforeOverflowResync() async throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let aliceNote = try service.scoped(to: alice.userId).createNote(bodyMarkdown: "# Alice\nPrivate")
    let feed = NoteChangeFeed()
    var failingService = service
    failingService.driver = FailOnceEventAuthorizationDriver(backing: service.driver, failureCall: 1)
    let handler = DeterministicServerRouteHandler(
      noteAPIAuthenticator: EventRouteAuthenticator(usersByToken: ["alice": alice.userId]),
      noteService: failingService,
      noteChangeFeed: feed
    )
    let cursor = try await eventCursor(
      handler: handler,
      request: request(path: "/note/events", token: "alice", query: "since=0&timeoutMs=0")
    )
    let event = NoteChangeEvent(kind: NoteChangeEventKind.noteUpdated, notebookId: aliceNote.notebookId)
    await feed.publish(event)
    for _ in 0 ..< NoteChangeFeed.maximumPendingEventsPerCursor {
      await feed.publish(event)
    }

    let failedResponse = await handler.route(
      request(path: "/note/events", token: "alice", query: "since=\(cursor)&timeoutMs=0"),
      context: .init(serviceName: "test")
    )
    let retryResponse = await handler.route(
      request(path: "/note/events", token: "alice", query: "since=\(cursor)&timeoutMs=0"),
      context: .init(serviceName: "test")
    )

    XCTAssertEqual(failedResponse.status, 500)
    XCTAssertNil(failedResponse.body["revision"])
    XCTAssertEqual(retryResponse.status, 200)
    XCTAssertNotEqual(retryResponse.body["revision"], .string(cursor))
    XCTAssertEqual(retryResponse.body["resync"], .bool(true))
    XCTAssertEqual(retryResponse.body["events"], .array([]))
  }

  func testForeignOnlyEventsDoNotAdvanceOrWakeScopedCursor() async throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let bob = try service.createUser(email: "bob@example.com", displayName: "Bob")
    let bobNote = try service.scoped(to: bob.userId).createNote(bodyMarkdown: "# Bob\nPrivate")
    let feed = NoteChangeFeed()
    let handler = DeterministicServerRouteHandler(
      noteAPIAuthenticator: EventRouteAuthenticator(usersByToken: ["alice": alice.userId]),
      noteService: service,
      noteChangeFeed: feed
    )
    let cursor = try await eventCursor(
      handler: handler,
      request: request(path: "/note/events", token: "alice", query: "since=0&timeoutMs=0")
    )

    let pollRequest = ServerRequestEnvelope(
      method: "GET",
      path: "/note/events",
      headers: ["Authorization": "Bearer alice"],
      query: "since=\(cursor)&timeoutMs=300"
    )
    let responseTask = Task { await handler.route(pollRequest, context: .init(serviceName: "test")) }
    let activePollCountBeforeForeignEvent = try await waitForActivePollCount(1, in: feed)
    XCTAssertEqual(activePollCountBeforeForeignEvent, 1)
    await feed.publish(NoteChangeEvent(
      kind: NoteChangeEventKind.noteUpdated,
      notebookId: bobNote.notebookId,
      tagNames: ["bob-private"]
    ))
    let activePollCountAfterForeignEvent = await feed.activePollCount
    XCTAssertEqual(activePollCountAfterForeignEvent, 1)

    let response = await responseTask.value
    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.body["revision"], .string(cursor))
    XCTAssertEqual(response.body["resync"], .bool(false))
    XCTAssertEqual(response.body["events"], .array([]))
  }

  func testRevokedCredentialCannotReceiveEventAfterSuspendedPoll() async throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let note = try service.scoped(to: alice.userId).createNote(bodyMarkdown: "# Alice\nPrivate")
    let token = "revoked-event-token"
    let client = try service.registerAPIClient(
      displayName: "Alice event client",
      bearerToken: token,
      userId: alice.userId
    )
    let feed = NoteChangeFeed()
    let handler = DeterministicServerRouteHandler(
      noteAPIAuthenticator: QRClientRegistrationAuthenticator(service: service, registrationScope: "event-revocation"),
      noteService: service,
      noteChangeFeed: feed
    )
    let cursor = try await eventCursor(
      handler: handler,
      request: request(path: "/note/events", token: token, query: "since=0&timeoutMs=0")
    )

    let pollRequest = request(path: "/note/events", token: token, query: "since=\(cursor)&timeoutMs=1000")
    let poll = Task {
      await handler.route(pollRequest, context: .init(serviceName: "test"))
    }
    let activeEventPolls = try await waitForActivePollCount(1, in: feed)
    XCTAssertEqual(activeEventPolls, 1)
    _ = try service.revokeAPIClient(clientId: client.clientId)
    await feed.publish(NoteChangeEvent(kind: NoteChangeEventKind.noteUpdated, notebookId: note.notebookId))

    let response = await poll.value
    XCTAssertEqual(response.status, 401)
    XCTAssertNil(response.body["events"])
    XCTAssertNil(response.body["revision"])
  }

  func testForeignCursorPressureDoesNotWakeScopedCursor() async throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let bob = try service.createUser(email: "bob@example.com", displayName: "Bob")
    let feed = NoteChangeFeed()
    let handler = DeterministicServerRouteHandler(
      noteAPIAuthenticator: EventRouteAuthenticator(usersByToken: ["alice": alice.userId, "bob": bob.userId]),
      noteService: service,
      noteChangeFeed: feed
    )
    let aliceCursor = try await eventCursor(
      handler: handler,
      request: request(path: "/note/events", token: "alice", query: "since=0&timeoutMs=0")
    )

    let alicePollRequest = ServerRequestEnvelope(
      method: "GET",
      path: "/note/events",
      headers: ["Authorization": "Bearer alice"],
      query: "since=\(aliceCursor)&timeoutMs=1000"
    )
    let alicePoll = Task {
      await handler.route(alicePollRequest, context: .init(serviceName: "test"))
    }
    let activePollCountBeforePressure = try await waitForActivePollCount(1, in: feed)
    XCTAssertEqual(activePollCountBeforePressure, 1)

    var pressureStatuses: [Int] = []
    for _ in 0 ... NoteChangeFeed.maximumCursorsPerPrincipal {
      let response = await handler.route(
        request(path: "/note/events", token: "bob", query: "since=0&timeoutMs=0"),
        context: .init(serviceName: "test")
      )
      pressureStatuses.append(response.status)
    }

    XCTAssertTrue(pressureStatuses.contains(429))
    let activePollCountAfterPressure = await feed.activePollCount
    XCTAssertEqual(activePollCountAfterPressure, 1)
    let response = await alicePoll.value
    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.body["revision"], .string(aliceCursor))
    XCTAssertEqual(response.body["resync"], .bool(false))
    XCTAssertEqual(response.body["events"], .array([]))
  }

  func testSameAccountCursorPressureDoesNotWakeAnotherClient() async throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let feed = NoteChangeFeed()
    let handler = DeterministicServerRouteHandler(
      noteAPIAuthenticator: EventRouteAuthenticator(
        usersByToken: ["alice-primary": alice.userId, "alice-secondary": alice.userId],
        clientIdsByToken: [
          "alice-primary": APIClientID("alice-primary-client"),
          "alice-secondary": APIClientID("alice-secondary-client")
        ]
      ),
      noteService: service,
      noteChangeFeed: feed
    )
    let primaryCursor = try await eventCursor(
      handler: handler,
      request: request(path: "/note/events", token: "alice-primary", query: "since=0&timeoutMs=0")
    )
    let primaryPollRequest = ServerRequestEnvelope(
      method: "GET",
      path: "/note/events",
      headers: ["Authorization": "Bearer alice-primary"],
      query: "since=\(primaryCursor)&timeoutMs=1000"
    )
    let primaryPoll = Task {
      await handler.route(primaryPollRequest, context: .init(serviceName: "test"))
    }
    let activePollCountBeforePressure = try await waitForActivePollCount(1, in: feed)
    XCTAssertEqual(activePollCountBeforePressure, 1)

    var pressureStatuses: [Int] = []
    for _ in 0 ... NoteChangeFeed.maximumCursorsPerPrincipal {
      let response = await handler.route(
        request(path: "/note/events", token: "alice-secondary", query: "since=0&timeoutMs=0"),
        context: .init(serviceName: "test")
      )
      pressureStatuses.append(response.status)
    }

    XCTAssertTrue(pressureStatuses.contains(429))
    let activePollCountAfterPressure = await feed.activePollCount
    XCTAssertEqual(activePollCountAfterPressure, 1)
    let response = await primaryPoll.value
    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.body["revision"], .string(primaryCursor))
    XCTAssertEqual(response.body["resync"], .bool(false))
    XCTAssertEqual(response.body["events"], .array([]))
  }

  func testUnauthenticatedCursorPressureDoesNotWakeAnotherPoll() async throws {
    let service = try makeService()
    let feed = NoteChangeFeed()
    let handler = DeterministicServerRouteHandler(
      allowUnauthenticatedNoteAPI: true,
      noteService: service,
      noteChangeFeed: feed
    )
    let initialRequest = ServerRequestEnvelope(
      method: "GET",
      path: "/note/events",
      query: "since=0&timeoutMs=0"
    )
    let cursor = try await eventCursor(handler: handler, request: initialRequest)
    let poll = Task {
      await handler.route(
        ServerRequestEnvelope(
          method: "GET",
          path: "/note/events",
          query: "since=\(cursor)&timeoutMs=1000"
        ),
        context: .init(serviceName: "test")
      )
    }
    let activePollCountBeforePressure = try await waitForActivePollCount(1, in: feed)
    XCTAssertEqual(activePollCountBeforePressure, 1)

    var pressureStatuses: [Int] = []
    for _ in 0 ... NoteChangeFeed.maximumCursorsPerPrincipal {
      let response = await handler.route(initialRequest, context: .init(serviceName: "test"))
      pressureStatuses.append(response.status)
    }

    XCTAssertTrue(pressureStatuses.contains(429))
    let activePollCountAfterPressure = await feed.activePollCount
    XCTAssertEqual(activePollCountAfterPressure, 1)
    let response = await poll.value
    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.body["revision"], .string(cursor))
    XCTAssertEqual(response.body["resync"], .bool(false))
    XCTAssertEqual(response.body["events"], .array([]))
  }

  func testAgentReplyStreamRefusesForeignTurnBeforePolling() async throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let bob = try service.createUser(email: "bob@example.com", displayName: "Bob")
    let bobService = service.scoped(to: bob.userId)
    let bobSubject = try bobService.createNote(bodyMarkdown: "# Bob\nPrivate subject")
    let bobConversation = try bobService.startAgentConversation(subjectNoteId: bobSubject.noteId)
    let bobTurn = try bobService.appendPendingAgentChatTurn(
      conversationNotebookId: bobConversation.notebookId,
      userMarkdown: "Private turn",
      agentAvailable: true
    )
    let hub = AgentReplyStreamHub()
    await hub.publish(turnNoteId: bobTurn.noteId, text: "Bob stream content")
    let handler = DeterministicServerRouteHandler(
      noteAPIAuthenticator: EventRouteAuthenticator(usersByToken: ["alice": alice.userId, "bob": bob.userId]),
      noteService: service,
      agentReplyStreamHub: hub
    )

    let aliceResponse = await handler.route(
      request(path: "/note/agent-stream", token: "alice", query: "turn=\(bobTurn.noteId.rawValue)&timeoutMs=0"),
      context: .init(serviceName: "test")
    )
    let bobResponse = await handler.route(
      request(path: "/note/agent-stream", token: "bob", query: "turn=\(bobTurn.noteId.rawValue)&timeoutMs=0"),
      context: .init(serviceName: "test")
    )

    XCTAssertEqual(aliceResponse.status, 404)
    XCTAssertEqual(bobResponse.status, 200)
    XCTAssertEqual(bobResponse.headers["Cache-Control"], "private, no-store")
    XCTAssertEqual(bobResponse.body["chunks"], .array([.string("Bob stream content")]))
  }

  func testRevokedCredentialCannotReceiveStreamAfterSuspendedPoll() async throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let aliceService = service.scoped(to: alice.userId)
    let subject = try aliceService.createNote(bodyMarkdown: "# Alice\nPrivate subject")
    let conversation = try aliceService.startAgentConversation(subjectNoteId: subject.noteId)
    let turn = try aliceService.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Private turn",
      agentAvailable: true
    )
    let token = "revoked-stream-token"
    let client = try service.registerAPIClient(
      displayName: "Alice stream client",
      bearerToken: token,
      userId: alice.userId
    )
    let hub = AgentReplyStreamHub()
    let handler = DeterministicServerRouteHandler(
      noteAPIAuthenticator: QRClientRegistrationAuthenticator(service: service, registrationScope: "stream-revocation"),
      noteService: service,
      agentReplyStreamHub: hub
    )

    let pollRequest = request(
      path: "/note/agent-stream",
      token: token,
      query: "turn=\(turn.noteId.rawValue)&timeoutMs=1000"
    )
    let poll = Task {
      await handler.route(pollRequest, context: .init(serviceName: "test"))
    }
    let activeStreamPolls = try await waitForAgentReplyStreamPollCount(1, in: hub)
    XCTAssertEqual(activeStreamPolls, 1)
    _ = try service.revokeAPIClient(clientId: client.clientId)
    await hub.publish(turnNoteId: turn.noteId, text: "must not reach revoked client")

    let response = await poll.value
    XCTAssertEqual(response.status, 401)
    XCTAssertNil(response.body["chunks"])
  }

  func testAgentReplyStreamRetainsProtectedLibraryVisibilityAfterConversationMoves() async throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Protected subject")
    _ = try service.createLibrary(name: "protected-stream-snapshot", authRequired: true)
    try service.moveNotebook(subject.notebookId, toLibrary: "protected-stream-snapshot")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Summarize this subject",
      agentAvailable: true
    )
    let hub = AgentReplyStreamHub()
    let invoker = PausingStreamingReplyInvoker()
    let generation = Task { () -> Error? in
      do {
        try await service.generateAgentChatReply(
          turnNoteId: turn.noteId,
          invoker: invoker,
          streamPublisher: AgentReplyStreamHubPublisher(hub: hub)
        )
        return nil
      } catch {
        return error
      }
    }

    await invoker.waitUntilChunkEmitted()
    let rawPoll = await hub.poll(
      turnNoteId: turn.noteId,
      cursor: 0,
      timeoutNanoseconds: 1_000_000_000
    )
    XCTAssertEqual(rawPoll.chunks, ["protected streamed chunk"])
    XCTAssertEqual(rawPoll.requiredLibraryIds.count, 1)

    try service.moveNotebook(conversation.notebookId, toLibrary: "default")
    let handler = DeterministicServerRouteHandler(
      allowUnauthenticatedNoteAPI: true,
      noteService: service,
      agentReplyStreamHub: hub
    )
    let response = await handler.route(
      ServerRequestEnvelope(
        method: "GET",
        path: "/note/agent-stream",
        query: "turn=\(turn.noteId.rawValue)&timeoutMs=0"
      ),
      context: .init(serviceName: "test")
    )
    XCTAssertEqual(response.status, 404)

    await invoker.resume()
    let generationError = await generation.value
    XCTAssertNotNil(generationError)
  }

  func testRejectedAgentReplyStreamPollDoesNotEvictProtectedTerminalStream() async throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Protected subject")
    let protectedLibrary = try service.createLibrary(name: "protected-terminal-stream", authRequired: true)
    try service.moveNotebook(subject.notebookId, toLibrary: protectedLibrary.name)
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Summarize this subject",
      agentAvailable: false
    )
    let hub = AgentReplyStreamHub(maximumRetainedStreams: 1)
    await hub.publish(
      turnNoteId: turn.noteId,
      text: "protected terminal chunk",
      libraryId: protectedLibrary.libraryId
    )
    await hub.finish(turnNoteId: turn.noteId, status: "answered", message: nil)
    try service.moveNotebook(conversation.notebookId, toLibrary: "default")
    XCTAssertThrowsError(
      try service
        .scoped(to: NoteStoreSchema.defaultUserId)
        .unauthenticated()
        .requireLibraryAccess(protectedLibrary.libraryId)
    )

    let unauthenticatedHandler = DeterministicServerRouteHandler(
      allowUnauthenticatedNoteAPI: true,
      noteService: service,
      agentReplyStreamHub: hub
    )
    let rejected = await unauthenticatedHandler.route(
      ServerRequestEnvelope(
        method: "GET",
        path: "/note/agent-stream",
        query: "turn=\(turn.noteId.rawValue)&timeoutMs=0"
      ),
      context: .init(serviceName: "test")
    )
    XCTAssertEqual(rejected.status, 404)

    // A second delivered terminal stream applies retention pressure. The
    // rejected poll above must not make this protected stream evictable.
    let pressureTurnId = NoteID("retention-pressure-turn")
    await hub.finish(turnNoteId: pressureTurnId, status: "answered", message: nil)
    _ = await hub.poll(turnNoteId: pressureTurnId, cursor: 0, timeoutNanoseconds: 0)

    let authorizedHandler = DeterministicServerRouteHandler(
      noteAPIAuthenticator: EventRouteAuthenticator(usersByToken: ["default": NoteStoreSchema.defaultUserId]),
      noteService: service,
      agentReplyStreamHub: hub
    )
    let authorized = await authorizedHandler.route(
      request(
        path: "/note/agent-stream",
        token: "default",
        query: "turn=\(turn.noteId.rawValue)&timeoutMs=0"
      ),
      context: .init(serviceName: "test")
    )
    XCTAssertEqual(authorized.status, 200)
    XCTAssertEqual(authorized.body["chunks"], .array([.string("protected terminal chunk")]))
  }

  func testFailedProtectedReplyAfterMoveDoesNotPersistOrStreamProviderFailure() async throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Protected subject")
    let protectedLibrary = try service.createLibrary(name: "protected-failure-stream", authRequired: true)
    try service.moveNotebook(subject.notebookId, toLibrary: protectedLibrary.name)
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Summarize this subject",
      agentAvailable: true
    )
    let hub = AgentReplyStreamHub()
    let invoker = PausingFailingStreamingReplyInvoker()
    let generation = Task { () -> Error? in
      do {
        try await service.generateAgentChatReply(
          turnNoteId: turn.noteId,
          invoker: invoker,
          streamPublisher: AgentReplyStreamHubPublisher(hub: hub)
        )
        return nil
      } catch {
        return error
      }
    }

    await invoker.waitUntilStarted()
    try service.moveNotebook(subject.notebookId, toLibrary: "default")
    try service.moveNotebook(conversation.notebookId, toLibrary: "default")
    await invoker.resume()
    let generationError = await generation.value
    XCTAssertNotNil(generationError)

    let storedTurn = try service.getNote(turn.noteId)
    XCTAssertFalse(storedTurn.bodyMarkdown.contains("sensitive-provider-sentinel"))
    XCTAssertEqual(NoteService.chatTurnState(of: storedTurn)?.status, .pending)

    let handler = DeterministicServerRouteHandler(
      allowUnauthenticatedNoteAPI: true,
      noteService: service,
      agentReplyStreamHub: hub
    )
    let response = await handler.route(
      ServerRequestEnvelope(
        method: "GET",
        path: "/note/agent-stream",
        query: "turn=\(turn.noteId.rawValue)&timeoutMs=1000"
      ),
      context: .init(serviceName: "test")
    )
    XCTAssertEqual(response.status, 404)
    XCTAssertFalse(String(describing: response.body).contains("sensitive-provider-sentinel"))
  }

  private func request(path: String, token: String, query: String) -> ServerRequestEnvelope {
    ServerRequestEnvelope(
      method: "GET",
      path: path,
      headers: ["Authorization": "Bearer \(token)"],
      query: query
    )
  }

  private func waitForFeedRevision(
    in feed: NoteChangeFeed,
    after revision: UInt64,
    timeout: Duration = .seconds(1)
  ) async throws -> UInt64 {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      let currentRevision = await feed.currentRevision
      if currentRevision != revision {
        return currentRevision
      }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    return await feed.currentRevision
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

  private func waitForAgentReplyStreamPollCount(
    _ expectedCount: Int,
    in hub: AgentReplyStreamHub,
    timeout: Duration = .seconds(1)
  ) async throws -> Int {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      let actualCount = await hub.activePollCount
      if actualCount == expectedCount {
        return actualCount
      }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    return await hub.activePollCount
  }

  private func eventCursor(
    handler: DeterministicServerRouteHandler,
    request: ServerRequestEnvelope
  ) async throws -> String {
    let response = await handler.route(request, context: .init(serviceName: "test"))
    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.body["resync"], .bool(true))
    guard case let .string(cursor)? = response.body["revision"] else {
      throw NoteServiceError.invalidRow("event reset response has no opaque cursor")
    }
    return cursor
  }

  private func makeService(
    function: String = #function,
    changeObserver: (any NoteChangeObserving)? = nil
  ) throws -> NoteService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/AppServerTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return try NoteService(
      driver: SQLiteNoteDatabaseDriver(noteRoot: root.path),
      changeObserver: changeObserver
    )
  }
}
