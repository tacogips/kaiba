import Foundation

import AppCore
@testable import AppServer
import XCTest

private struct TerminalAcknowledgementAuthenticator: NoteAPIAuthenticating {
  let userId: UserID

  func authenticate(
    request _: ServerRequestEnvelope,
    context: ServerRequestContext
  ) async -> NoteAPIAuthenticationResult {
    guard context.bearerToken == "alice" else {
      return .rejected(noteAPIUnauthorizedResponse("note API bearer token is invalid or revoked"))
    }
    return .accepted(NoteAPIAuthenticatedClient(
      clientId: APIClientID("terminal-acknowledgement-client"),
      displayName: "Alice",
      userId: userId
    ))
  }
}

private final class RouteManualGraceExpiryScheduler: @unchecked Sendable {
  private let lock = NSLock()
  private var pending: [@Sendable () -> Void] = []

  func schedule(_: UInt64, action: @escaping @Sendable () -> Void) {
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

private actor PausingSecondAgentStreamAuthentication: NoteAPIAuthenticating {
  private let userId: UserID
  private var authenticationCount = 0
  private var postPollAuthenticationStarted = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var release: CheckedContinuation<Void, Never>?

  init(userId: UserID) {
    self.userId = userId
  }

  func authenticate(
    request _: ServerRequestEnvelope,
    context: ServerRequestContext
  ) async -> NoteAPIAuthenticationResult {
    authenticationCount += 1
    if authenticationCount == 2 {
      postPollAuthenticationStarted = true
      let waiters = startWaiters
      startWaiters.removeAll()
      waiters.forEach { $0.resume() }
      await withCheckedContinuation { release = $0 }
    }
    guard context.bearerToken == "alice" else {
      return .rejected(noteAPIUnauthorizedResponse("note API bearer token is invalid or revoked"))
    }
    return .accepted(NoteAPIAuthenticatedClient(
      clientId: APIClientID("nonterminal-delivery-client"),
      displayName: "Alice",
      userId: userId
    ))
  }

  func waitUntilPostPollAuthenticationStarted() async {
    guard !postPollAuthenticationStarted else { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func resume() {
    release?.resume()
    release = nil
  }
}

final class AgentReplyStreamRouteAuthorizationTests: XCTestCase {
  func testReauthorizesAfterDeferredTerminalAcknowledgement() async throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let library = try service.scoped(to: alice.userId).createLibrary(
      name: "alice-terminal-ack-private", authRequired: true
    )
    let aliceService = service.scoped(to: alice.userId).scoped(toLibrary: library.libraryId)
    let subject = try aliceService.createNote(bodyMarkdown: "# Alice\nPrivate subject")
    let conversation = try aliceService.startAgentConversation(subjectNoteId: subject.noteId)
    let turn = try aliceService.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Private turn",
      agentAvailable: true
    )
    let hub = AgentReplyStreamHub(
      maximumRetainedStreams: AgentReplyStreamHub.maximumStreams,
      firstTerminalDeliveryGraceNanoseconds: 35_000_000_000,
      graceExpiryScheduling: { _, _ in },
      defersTerminalAckForTesting: true
    )
    await hub.publish(turnNoteId: turn.noteId, text: "must not reach revoked library", libraryId: library.libraryId)
    await hub.finish(
      turnNoteId: turn.noteId,
      status: "answered",
      message: nil,
      libraryId: library.libraryId
    )
    let handler = DeterministicServerRouteHandler(
      noteAPIAuthenticator: TerminalAcknowledgementAuthenticator(userId: alice.userId),
      noteService: service,
      agentReplyStreamHub: hub
    )
    let request = ServerRequestEnvelope(
      method: "GET",
      path: "/note/agent-stream",
      headers: ["Authorization": "Bearer alice"],
      query: "turn=\(turn.noteId.rawValue)&timeoutMs=0"
    )
    let responseTask = Task {
      await handler.route(request, context: .init(serviceName: "test"))
    }
    await hub.waitForTerminalDeliveryAcknowledgementRegistration()
    try service.revokeLibraryAccess(libraryName: library.name, userId: alice.userId)
    await hub.resumeDeferredTerminalDeliveryAcknowledgements()

    let response = await responseTask.value
    XCTAssertEqual(response.status, 404)
    XCTAssertNil(response.body["chunks"])
  }

  func testNonterminalSnapshotRetainsTerminalTailThroughPostPollAuthentication() async throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let library = try service.scoped(to: alice.userId).createLibrary(
      name: "alice-nonterminal-delivery-private", authRequired: true
    )
    let aliceService = service.scoped(to: alice.userId).scoped(toLibrary: library.libraryId)
    let subject = try aliceService.createNote(bodyMarkdown: "# Alice\nPrivate subject")
    let conversation = try aliceService.startAgentConversation(subjectNoteId: subject.noteId)
    let turn = try aliceService.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Private turn",
      agentAvailable: true
    )
    let scheduler = RouteManualGraceExpiryScheduler()
    let hub = AgentReplyStreamHub(
      maximumRetainedStreams: 1,
      firstTerminalDeliveryGraceNanoseconds: 35_000_000_000,
      graceExpiryScheduling: scheduler.schedule
    )
    let authenticator = PausingSecondAgentStreamAuthentication(userId: alice.userId)
    let handler = DeterministicServerRouteHandler(
      noteAPIAuthenticator: authenticator,
      noteService: service,
      agentReplyStreamHub: hub
    )
    let request = ServerRequestEnvelope(
      method: "GET",
      path: "/note/agent-stream",
      headers: ["Authorization": "Bearer alice"],
      query: "turn=\(turn.noteId.rawValue)&timeoutMs=1000"
    )
    let responseTask = Task {
      await handler.route(request, context: .init(serviceName: "test"))
    }

    await hub.waitForPendingPollRegistration(for: turn.noteId)
    await hub.publish(turnNoteId: turn.noteId, text: "first chunk", libraryId: library.libraryId)
    await authenticator.waitUntilPostPollAuthenticationStarted()

    await hub.finish(
      turnNoteId: turn.noteId,
      status: "answered",
      message: nil,
      libraryId: library.libraryId
    )
    scheduler.fireAll()
    await hub.waitForGraceExpiryWhileDeliveryIsPending(for: turn.noteId)
    let pressureTurnId = NoteID("nonterminal-delivery-retention-pressure")
    await hub.finish(turnNoteId: pressureTurnId, status: "answered", message: nil)
    _ = await hub.poll(turnNoteId: pressureTurnId, cursor: 0, timeoutNanoseconds: 0)
    let retainedDuringPostPollAuthentication = await hub.containsStream(for: turn.noteId)
    XCTAssertTrue(retainedDuringPostPollAuthentication)

    await authenticator.resume()
    let chunkResponse = await responseTask.value
    XCTAssertEqual(chunkResponse.status, 200)
    XCTAssertEqual(chunkResponse.body["chunks"], .array([.string("first chunk")]))
    XCTAssertEqual(chunkResponse.body["done"], .bool(false))
    guard let cursor = chunkResponse.body["cursor"]?.asInt else {
      return XCTFail("chunk response must include a cursor")
    }

    let terminalResponse = await handler.route(
      ServerRequestEnvelope(
        method: "GET",
        path: "/note/agent-stream",
        headers: ["Authorization": "Bearer alice"],
        query: "turn=\(turn.noteId.rawValue)&cursor=\(cursor)&timeoutMs=0"
      ),
      context: .init(serviceName: "test")
    )
    XCTAssertEqual(terminalResponse.status, 200)
    XCTAssertEqual(terminalResponse.body["chunks"], .array([]))
    XCTAssertEqual(terminalResponse.body["done"], .bool(true))
    XCTAssertEqual(terminalResponse.body["status"], .string("answered"))
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
