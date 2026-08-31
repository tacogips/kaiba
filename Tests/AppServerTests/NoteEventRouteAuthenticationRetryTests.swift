import Foundation

import AppCore
@testable import AppServer
import XCTest

private actor FailOncePostPollAuthenticator: NoteAPIAuthenticating {
  private let authenticator: QRClientRegistrationAuthenticator
  private var authenticationCount = 0

  init(service: NoteService, registrationScope: String) {
    authenticator = QRClientRegistrationAuthenticator(service: service, registrationScope: registrationScope)
  }

  func authenticate(
    request: ServerRequestEnvelope,
    context: ServerRequestContext
  ) async -> NoteAPIAuthenticationResult {
    authenticationCount += 1
    // The initial cursor request authenticates twice. Reject only the
    // suspended poll's post-poll check, then recover on its same-cursor retry.
    if authenticationCount == 4 {
      return .rejected(noteAPIUnavailableResponse("injected transient authentication outage"))
    }
    return await authenticator.authenticate(request: request, context: context)
  }
}

private actor PausingPostPollAuthenticator: NoteAPIAuthenticating {
  private let authenticator: QRClientRegistrationAuthenticator
  private var authenticationCount = 0
  private var postPollAuthenticationStarted = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var release: CheckedContinuation<Void, Never>?

  init(service: NoteService, registrationScope: String) {
    authenticator = QRClientRegistrationAuthenticator(service: service, registrationScope: registrationScope)
  }

  func authenticate(
    request: ServerRequestEnvelope,
    context: ServerRequestContext
  ) async -> NoteAPIAuthenticationResult {
    authenticationCount += 1
    // The reset request authenticates twice. The fourth authentication is the
    // long poll's post-poll credential check after its event batch is ready.
    if authenticationCount == 4 {
      postPollAuthenticationStarted = true
      let waiters = startWaiters
      startWaiters.removeAll()
      waiters.forEach { $0.resume() }
      await withCheckedContinuation { continuation in
        release = continuation
      }
    }
    return await authenticator.authenticate(request: request, context: context)
  }

  func waitUntilPostPollAuthenticationStarted() async {
    guard !postPollAuthenticationStarted else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func resume() {
    release?.resume()
    release = nil
  }
}

final class NoteEventRouteAuthenticationRetryTests: XCTestCase {
  func testDisabledCredentialPostPollRestoresEventForSameCursorAfterReenable() async throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let note = try service.scoped(to: alice.userId).createNote(bodyMarkdown: "# Alice\nPrivate")
    let token = "disabled-event-token"
    _ = try service.registerAPIClient(
      displayName: "Alice event client",
      bearerToken: token,
      userId: alice.userId
    )
    let feed = NoteChangeFeed()
    let handler = DeterministicServerRouteHandler(
      noteAPIAuthenticator: QRClientRegistrationAuthenticator(service: service, registrationScope: "event-disable"),
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
    let activePolls = try await waitForActivePollCount(1, in: feed)
    XCTAssertEqual(activePolls, 1)
    _ = try service.setUserDisabled(userId: alice.userId, disabled: true)
    await feed.publish(NoteChangeEvent(kind: NoteChangeEventKind.noteUpdated, notebookId: note.notebookId))

    let rejected = await poll.value
    XCTAssertEqual(rejected.status, 401)
    XCTAssertNil(rejected.body["events"])
    XCTAssertNil(rejected.body["revision"])

    _ = try service.setUserDisabled(userId: alice.userId, disabled: false)
    let retried = await handler.route(
      request(path: "/note/events", token: token, query: "since=\(cursor)&timeoutMs=0"),
      context: .init(serviceName: "test")
    )
    XCTAssertEqual(retried.status, 200)
    XCTAssertNotEqual(retried.body["revision"], .string(cursor))
    XCTAssertEqual(retried.body["resync"], .bool(false))
    try assertSingleRestoredEvent(in: retried)
  }

  func testTransientPostPollAuthenticationFailureRestoresEventForSameCursor() async throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let note = try service.scoped(to: alice.userId).createNote(bodyMarkdown: "# Alice\nPrivate")
    let token = "transient-event-token"
    _ = try service.registerAPIClient(
      displayName: "Alice event client",
      bearerToken: token,
      userId: alice.userId
    )
    let feed = NoteChangeFeed()
    let handler = DeterministicServerRouteHandler(
      noteAPIAuthenticator: FailOncePostPollAuthenticator(service: service, registrationScope: "event-transient"),
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
    let activePolls = try await waitForActivePollCount(1, in: feed)
    XCTAssertEqual(activePolls, 1)
    await feed.publish(NoteChangeEvent(kind: NoteChangeEventKind.noteUpdated, notebookId: note.notebookId))

    let rejected = await poll.value
    XCTAssertEqual(rejected.status, 503)
    XCTAssertNil(rejected.body["events"])
    XCTAssertNil(rejected.body["revision"])

    let retried = await handler.route(
      request(path: "/note/events", token: token, query: "since=\(cursor)&timeoutMs=0"),
      context: .init(serviceName: "test")
    )
    XCTAssertEqual(retried.status, 200)
    XCTAssertNotEqual(retried.body["revision"], .string(cursor))
    XCTAssertEqual(retried.body["resync"], .bool(false))
    try assertSingleRestoredEvent(in: retried)
  }

  func testPostPollReauthorizationHidesEventAfterLibraryRevocationDuringAuthentication() async throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let library = try service.scoped(to: alice.userId).createLibrary(
      name: "alice-post-poll-private", authRequired: true
    )
    let notebook = try service.scoped(to: alice.userId)
      .scoped(toLibrary: library.libraryId)
      .createNotebook(title: "Alice private notebook")
    let token = "post-poll-revocation-token"
    _ = try service.registerAPIClient(
      displayName: "Alice event client",
      bearerToken: token,
      userId: alice.userId
    )
    let feed = NoteChangeFeed()
    let authenticator = PausingPostPollAuthenticator(
      service: service,
      registrationScope: "event-post-poll-library-revocation"
    )
    let handler = DeterministicServerRouteHandler(
      noteAPIAuthenticator: authenticator,
      noteService: service,
      noteChangeFeed: feed
    )
    let cursor = try await eventCursor(
      handler: handler,
      request: request(path: "/note/events", token: token, query: "since=0&timeoutMs=0")
    )
    let pollRequest = request(path: "/note/events", token: token, query: "since=\(cursor)&timeoutMs=1000")
    let responseTask = Task {
      await handler.route(pollRequest, context: .init(serviceName: "test"))
    }
    let activePolls = try await waitForActivePollCount(1, in: feed)
    XCTAssertEqual(activePolls, 1)
    await feed.publish(NoteChangeEvent(
      kind: NoteChangeEventKind.noteUpdated,
      notebookId: notebook.notebookId,
      tagNames: ["private"]
    ))
    await authenticator.waitUntilPostPollAuthenticationStarted()
    try service.revokeLibraryAccess(libraryName: library.name, userId: alice.userId)
    await authenticator.resume()

    let response = await responseTask.value
    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.body["events"], .array([]))
  }

  private func assertSingleRestoredEvent(in response: ServerResponseDescriptor) throws {
    guard case let .array(events)? = response.body["events"] else {
      throw NoteServiceError.invalidRow("expected restored events")
    }
    XCTAssertEqual(events.count, 1)
  }

  private func request(path: String, token: String, query: String) -> ServerRequestEnvelope {
    ServerRequestEnvelope(
      method: "GET",
      path: path,
      headers: ["Authorization": "Bearer \(token)"],
      query: query
    )
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
