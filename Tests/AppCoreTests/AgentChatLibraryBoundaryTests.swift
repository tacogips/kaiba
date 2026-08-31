import Foundation
@testable import AppCore
import XCTest

private actor LibraryBoundaryChatInvoker: AgentInvoking {
  private var chatRequestCount = 0

  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    if request.purpose == .chat {
      chatRequestCount += 1
    }
    return AgentInvocationResult(markdown: "captured")
  }

  func recordedChatRequestCount() -> Int {
    chatRequestCount
  }
}

private actor PausingLibraryBoundaryChatInvoker: AgentInvoking {
  private let replyMarkdown: String
  private var hasStarted = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var release: CheckedContinuation<Void, Never>?

  init(replyMarkdown: String = "reply must not reach an open conversation") {
    self.replyMarkdown = replyMarkdown
  }

  func invoke(_: AgentInvocationRequest) async throws -> AgentInvocationResult {
    hasStarted = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation { continuation in
      release = continuation
    }
    return AgentInvocationResult(markdown: replyMarkdown)
  }

  func waitUntilStarted() async {
    guard !hasStarted else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func resume() {
    release?.resume()
    release = nil
  }
}

private actor CountingEditChatInvoker: AgentInvoking {
  private let replyMarkdown: String
  private var invocationCount = 0

  init(replyMarkdown: String) {
    self.replyMarkdown = replyMarkdown
  }

  func invoke(_: AgentInvocationRequest) async throws -> AgentInvocationResult {
    invocationCount += 1
    return AgentInvocationResult(markdown: replyMarkdown)
  }

  func count() -> Int {
    invocationCount
  }
}

final class AgentChatLibraryBoundaryTests: NoteTestCase {
  func testAgentConversationCreationRejectsSubjectDeletionAtPreinsertBoundary() throws {
    var service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\nInitial body")
    service.agentChatCreationPreinsertHook = { database in
      try deleteNoteRows(noteId: subject.noteId, in: database)
    }

    XCTAssertThrowsError(try service.startAgentConversation(subjectNoteId: subject.noteId)) { error in
      guard case .notFound = error as? NoteServiceError else {
        return XCTFail("expected missing deleted subject, got \(error)")
      }
    }
    XCTAssertTrue(try service.listAgentConversations(subjectNoteId: subject.noteId).isEmpty)
  }

  func testAgentConversationCreationRejectsSubjectMoveAtPreinsertBoundary() throws {
    var service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\nInitial body")
    let protected = try service.createLibrary(name: "protected-creation-boundary", authRequired: true)
    service.agentChatCreationPreinsertHook = { database in
      try database.execute(
        "UPDATE notebooks SET library_id = ? WHERE notebook_id = ?",
        bindings: [.id(protected.libraryId), .id(subject.notebookId)]
      )
    }

    XCTAssertThrowsError(try service.startAgentConversation(subjectNotebookId: subject.notebookId)) { error in
      guard case .conflict = error as? NoteServiceError else {
        return XCTFail("expected moved-subject conflict, got \(error)")
      }
    }
    XCTAssertTrue(try service.listAgentConversations(subjectNotebookId: subject.notebookId).isEmpty)
  }

  func testMovedSubjectCannotAppendIntoOpenConversationOrInvokeAgent() async throws {
    let bare = try makeService()
    let invoker = LibraryBoundaryChatInvoker()
    let dispatcher = KaibaAutoActionDispatcher(service: bare, invoker: invoker)
    var service = bare
    service.autoActionDispatcher = dispatcher
    let subject = try service.createNote(bodyMarkdown: "# Subject\nInitially open")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    _ = try service.createLibrary(name: "protected-moved-chat-subject", authRequired: true)
    try service.moveNotebook(subject.notebookId, toLibrary: "protected-moved-chat-subject")
    let dispatchCount = try service.listAutoActionDispatchAttempts().count

    XCTAssertThrowsError(try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Summarize the moved subject",
      agentAvailable: true
    )) { error in
      guard case .invalidInput = error as? NoteServiceError else {
        return XCTFail("expected invalidInput, got \(error)")
      }
    }
    await service.drainAutoActionDispatches()

    let chatRequestCount = await invoker.recordedChatRequestCount()
    XCTAssertEqual(chatRequestCount, 0)
    XCTAssertTrue(try service.listNotes(notebookId: conversation.notebookId).isEmpty)
    XCTAssertEqual(try service.listAutoActionDispatchAttempts().count, dispatchCount)
  }

  func testListAgentConversationsExcludesRevokedLibrariesBeforeApplyingLimit() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "conversation-reach@example.com", displayName: "Alice")
    let aliceService = service.scoped(to: alice.userId)
    let protectedLibrary = try aliceService.createLibrary(
      name: "revoked-conversation-reach",
      authRequired: true
    )
    let protectedScope = aliceService.scoped(toLibrary: protectedLibrary.libraryId)
    let subject = try protectedScope.createNote(bodyMarkdown: "# Subject\nInitially protected")
    let revokedConversation = try protectedScope.startAgentConversation(subjectNoteId: subject.noteId)

    try service.moveNotebook(subject.notebookId, toLibrary: NoteStoreSchema.defaultLibraryName)
    let reachableConversation = try aliceService.startAgentConversation(subjectNoteId: subject.noteId)
    try service.driver.withDatabase { database in
      try database.execute(
        "UPDATE notebooks SET updated_at = ? WHERE notebook_id = ?",
        bindings: [.text("9999-12-31T23:59:59.999Z"), .id(revokedConversation.notebookId)]
      )
    }
    try service.revokeLibraryAccess(libraryName: protectedLibrary.name, userId: alice.userId)

    XCTAssertEqual(
      try aliceService.listAgentConversations(subjectNoteId: subject.noteId, limit: 1)
        .map(\.notebook.notebookId),
      [reachableConversation.notebookId]
    )
  }

  func testReplyCannotPersistAfterSubjectAndConversationMoveOpenDuringProviderInvocation() async throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\nInitially protected")
    _ = try service.createLibrary(name: "protected-dispatch-snapshot", authRequired: true)
    try service.moveNotebook(subject.notebookId, toLibrary: "protected-dispatch-snapshot")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Summarize the subject",
      agentAvailable: true
    )
    let invoker = PausingLibraryBoundaryChatInvoker()
    let reply = Task { () -> Error? in
      do {
        try await service.generateAgentChatReply(turnNoteId: turn.noteId, invoker: invoker)
        return nil
      } catch {
        return error
      }
    }

    await invoker.waitUntilStarted()
    try service.moveNotebook(subject.notebookId, toLibrary: "default")
    try service.moveNotebook(conversation.notebookId, toLibrary: "default")
    await invoker.resume()

    let replyError = await reply.value
    XCTAssertNotNil(replyError)
    let storedTurn = try service.getNote(turn.noteId)
    XCTAssertEqual(NoteService.chatTurnState(of: storedTurn)?.status, .pending)
    XCTAssertFalse(storedTurn.bodyMarkdown.contains("reply must not reach an open conversation"))
  }

  func testEditReplyCannotMutateSubjectAfterSubjectAndConversationMoveOpenDuringProviderInvocation() async throws {
    let service = try makeService()
    let originalBody = "# Subject\nInitially protected"
    let subject = try service.createNote(bodyMarkdown: originalBody)
    _ = try service.createLibrary(name: "protected-edit-dispatch-snapshot", authRequired: true)
    try service.moveNotebook(subject.notebookId, toLibrary: "protected-edit-dispatch-snapshot")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Rewrite the subject",
      agentAvailable: true,
      mode: .edit
    )
    let invoker = PausingLibraryBoundaryChatInvoker(replyMarkdown: """
      <kaiba-note-body>
      # Subject
      provider-derived replacement must not persist
      </kaiba-note-body>
      Updated the subject.
      """)
    let reply = Task { () -> Error? in
      do {
        try await service.generateAgentChatReply(turnNoteId: turn.noteId, invoker: invoker)
        return nil
      } catch {
        return error
      }
    }

    await invoker.waitUntilStarted()
    try service.moveNotebook(subject.notebookId, toLibrary: "default")
    try service.moveNotebook(conversation.notebookId, toLibrary: "default")
    await invoker.resume()

    let replyError = await reply.value
    XCTAssertNotNil(replyError)
    XCTAssertEqual(try service.getNote(subject.noteId).bodyMarkdown, originalBody)
    XCTAssertEqual(
      NoteService.chatTurnState(of: try service.getNote(turn.noteId))?.status,
      .pending
    )
  }

  func testEditReplyCannotOverwriteConcurrentHumanEditDuringProviderInvocation() async throws {
    let service = try makeService()
    let originalBody = "# Subject\nInitial human content"
    let humanRevision = "# Subject\nConcurrent human revision"
    let subject = try service.createNote(bodyMarkdown: originalBody)
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Rewrite the subject",
      agentAvailable: true,
      mode: .edit
    )
    let invoker = PausingLibraryBoundaryChatInvoker(replyMarkdown: """
      <kaiba-note-body>
      # Subject
      stale provider replacement
      </kaiba-note-body>
      Updated the subject.
      """)
    let reply = Task { () -> Error? in
      do {
        try await service.generateAgentChatReply(turnNoteId: turn.noteId, invoker: invoker)
        return nil
      } catch {
        return error
      }
    }

    await invoker.waitUntilStarted()
    _ = try service.updateNoteBody(noteId: subject.noteId, bodyMarkdown: humanRevision)
    await invoker.resume()

    let replyError = await reply.value
    guard case .conflict = replyError as? NoteServiceError else {
      return XCTFail("expected stale edit conflict, got \(String(describing: replyError))")
    }
    XCTAssertEqual(try service.getNote(subject.noteId).bodyMarkdown, humanRevision)
    XCTAssertFalse(try service.getNote(subject.noteId).bodyMarkdown.contains("stale provider replacement"))
  }

  func testEditReplyRollsBackWithTurnCompletionAndRetriesOnce() async throws {
    var service = try makeService()
    let originalBody = "# Subject\nInitial content"
    let subject = try service.createNote(bodyMarkdown: originalBody)
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Rewrite the subject",
      agentAvailable: true,
      mode: .edit
    )
    let reply = """
      <kaiba-note-body>
      # Subject
      replacement body
      </kaiba-note-body>
      Updated the subject.
      """
    let invoker = CountingEditChatInvoker(replyMarkdown: reply)
    service.agentChatEditPrecompletionHook = { _ in
      throw NoteServiceError.conflict("simulated turn-completion interruption")
    }

    do {
      try await service.generateAgentChatReply(turnNoteId: turn.noteId, invoker: invoker)
      XCTFail("expected simulated completion interruption")
    } catch {}
    XCTAssertEqual(try service.getNote(subject.noteId).bodyMarkdown, originalBody)
    XCTAssertEqual(NoteService.chatTurnState(of: try service.getNote(turn.noteId))?.status, .failed)

    service.agentChatEditPrecompletionHook = nil
    try await service.generateAgentChatReply(turnNoteId: turn.noteId, invoker: invoker)
    let invocationCount = await invoker.count()
    XCTAssertEqual(invocationCount, 2)
    XCTAssertEqual(try service.getNote(subject.noteId).bodyMarkdown, "# Subject\nreplacement body")
    XCTAssertEqual(NoteService.chatTurnState(of: try service.getNote(turn.noteId))?.status, .answered)
  }
}
