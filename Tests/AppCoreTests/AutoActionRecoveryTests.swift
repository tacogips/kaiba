import Foundation
@testable import AppCore
import XCTest

final class AutoActionRecoveryTests: NoteTestCase {
  func testFinalRecoveryPreservesAnsweredTurnAfterOriginatingAccountIsDisabled() async throws {
    let service = try makeRecoveryService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let aliceService = service.scoped(to: alice.userId)
    let subject = try aliceService.createNote(bodyMarkdown: "# Subject\nPrivate")
    let conversation = try aliceService.startAgentConversation(subjectNoteId: subject.noteId)
    _ = try service.configureAutoAction(
      actionId: NoteStoreSchema.agentChatReplyActionId,
      trigger: .noteCreated,
      workflowId: NoteStoreSchema.agentChatReplyWorkflowId
    )
    let turn = try aliceService.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Answer before acknowledgement loss",
      agentAvailable: true
    )
    _ = try aliceService.completeAgentChatTurn(turnNoteId: turn.noteId, assistantMarkdown: "Durable answer")
    let dispatchId = try dispatchId(for: turn.noteId, service: service)
    try markFinalAttemptStaleAndSuppressOtherPendingDispatches(service: service, dispatchId: dispatchId)
    _ = try service.setUserDisabled(userId: alice.userId, disabled: true)

    let invoker = RecoveryCapturingInvoker()
    let dispatcher = KaibaAutoActionDispatcher(service: service, invoker: invoker)
    let recovered = try NoteService(driver: service.driver, autoActionDispatcher: dispatcher)
    let recoveredCount = try await recovered.recoverAndRetryAutoActionDispatches(olderThan: 1)
    XCTAssertEqual(recoveredCount, 1)

    let request = await invoker.latestRequest()
    XCTAssertNil(request)
    let recoveredTurn = try recovered.getNote(turn.noteId)
    XCTAssertEqual(NoteService.chatTurnState(of: recoveredTurn)?.status, .answered)
    XCTAssertTrue(recoveredTurn.bodyMarkdown.contains("Durable answer"))
    XCTAssertEqual(
      try recovered.listAutoActionDispatchAttempts().first(where: { $0.dispatchId == dispatchId })?.status,
      .dispatched
    )
  }

  func testFinalRecoveryPreservesCompletedTranslationAfterOriginatingAccountIsDisabled() async throws {
    let service = try makeRecoveryService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let aliceService = try NoteService(
      driver: service.driver,
      autoActionDispatcher: RecoveryDeferredDispatcher()
    ).scoped(to: alice.userId)
    let source = try aliceService.createNotebookWithNotes(
      title: "Private source",
      pages: [NotePageDraft(bodyMarkdown: "# Private\nSource")]
    )
    let (pendingTranslation, didQueue) = try aliceService.requestNotebookTranslation(
      sourceNotebookId: source.notebook.notebookId,
      targetLanguage: "Japanese"
    )
    XCTAssertTrue(didQueue)
    let translation = try XCTUnwrap(pendingTranslation)
    await aliceService.drainAutoActionDispatches()
    _ = try aliceService.setNotebookTranslationStatus(translation.notebookId, status: .completed)
    let dispatchId = try XCTUnwrap(
      try service.listAutoActionDispatchAttempts().first(where: {
        $0.record.event.notebookId == translation.notebookId
          && $0.record.action.workflowId == NoteStoreSchema.notebookTranslationWorkflowId
      })?.dispatchId
    )
    try markFinalAttemptStaleAndSuppressOtherPendingDispatches(service: service, dispatchId: dispatchId)
    _ = try service.setUserDisabled(userId: alice.userId, disabled: true)

    let invoker = RecoveryCapturingInvoker()
    let dispatcher = KaibaAutoActionDispatcher(service: service, invoker: invoker)
    let recovered = try NoteService(driver: service.driver, autoActionDispatcher: dispatcher)
    let recoveredCount = try await recovered.recoverAndRetryAutoActionDispatches(olderThan: 1)
    XCTAssertEqual(recoveredCount, 1)

    let request = await invoker.latestRequest()
    XCTAssertNil(request)
    XCTAssertEqual(
      NoteService.translationState(of: try recovered.getNotebook(translation.notebookId))?.status,
      .completed
    )
    XCTAssertEqual(
      try recovered.listAutoActionDispatchAttempts().first(where: { $0.dispatchId == dispatchId })?.status,
      .dispatched
    )
  }

  func testStaleFinalAttemptWithDeletedAnsweredTurnTerminallyCancels() throws {
    let service = try makeRecoveryService()
    let subject = try service.createNote(bodyMarkdown: "# Deleted durable subject\nBody")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    _ = try service.configureAutoAction(
      actionId: NoteStoreSchema.agentChatReplyActionId,
      trigger: .noteCreated,
      workflowId: NoteStoreSchema.agentChatReplyWorkflowId
    )
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Answer before deletion",
      agentAvailable: true
    )
    _ = try service.completeAgentChatTurn(turnNoteId: turn.noteId, assistantMarkdown: "Durable answer")
    let dispatchId = try dispatchId(for: turn.noteId, service: service)
    try markFinalAttemptStaleAndSuppressOtherPendingDispatches(service: service, dispatchId: dispatchId)
    try service.deleteNote(noteId: turn.noteId)

    let recovered = try NoteService(
      driver: service.driver,
      autoActionDispatcher: FailingFinalReconciliationDispatcher()
    )
    XCTAssertEqual(try recovered.recoverInterruptedAutoActionDispatches(olderThan: 1), 1)
    XCTAssertEqual(try recovered.retryPendingAutoActionDispatches(), 0)
    let attempt = try XCTUnwrap(
      try recovered.listAutoActionDispatchAttempts().first(where: { $0.dispatchId == dispatchId })
    )
    XCTAssertEqual(attempt.status, .cancelled)
    XCTAssertEqual(attempt.attemptCount, 3)
  }

  func testFailedFinalReconciliationTerminallyCancelsWithoutProviderRetry() async throws {
    let service = try makeRecoveryService()
    let subject = try service.createNote(bodyMarkdown: "# Final reconciliation subject\nBody")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    _ = try service.configureAutoAction(
      actionId: NoteStoreSchema.agentChatReplyActionId,
      trigger: .noteCreated,
      workflowId: NoteStoreSchema.agentChatReplyWorkflowId
    )
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Answer before reconciliation failure",
      agentAvailable: true
    )
    _ = try service.completeAgentChatTurn(turnNoteId: turn.noteId, assistantMarkdown: "Durable answer")
    let dispatchId = try dispatchId(for: turn.noteId, service: service)
    try markFinalAttemptStaleAndSuppressOtherPendingDispatches(service: service, dispatchId: dispatchId)

    let recovered = try NoteService(
      driver: service.driver,
      autoActionDispatcher: FailingFinalReconciliationDispatcher()
    )
    XCTAssertEqual(try recovered.recoverInterruptedAutoActionDispatches(olderThan: 1), 1)
    XCTAssertEqual(try recovered.retryPendingAutoActionDispatches(), 1)
    await recovered.drainAutoActionDispatches()

    let attempt = try XCTUnwrap(
      try recovered.listAutoActionDispatchAttempts().first(where: { $0.dispatchId == dispatchId })
    )
    XCTAssertEqual(attempt.status, .cancelled)
    XCTAssertEqual(attempt.attemptCount, 3)
    XCTAssertTrue(attempt.lastError?.contains("final auto-action reconciliation failed") == true)
  }

  private func makeRecoveryService() throws -> NoteService {
    let service = try NoteService(driver: try makeNoteDriver(function: #function))
    try enableSeededAutoActions(driver: service.driver)
    return service
  }

  private func dispatchId(for turnNoteId: NoteID, service: NoteService) throws -> AutoActionDispatchID {
    try XCTUnwrap(
      try service.listAutoActionDispatchAttempts().first(where: {
        $0.record.event.noteId == turnNoteId
          && $0.record.action.workflowId == NoteStoreSchema.agentChatReplyWorkflowId
      })?.dispatchId
    )
  }

  private func markFinalAttemptStaleAndSuppressOtherPendingDispatches(
    service: NoteService,
    dispatchId: AutoActionDispatchID
  ) throws {
    try service.driver.withDatabase { database in
      try database.execute(
        """
        UPDATE auto_action_dispatches
        SET attempt_count = 3, status = ?, lease_token = ?, leased_at = ?
        WHERE dispatch_id = ?
        """,
        bindings: [
          .text(AutoActionDispatchStatus.inFlight.rawValue),
          .text("final-stale-lease"),
          .text("1970-01-01T00:00:00.000Z"),
          .id(dispatchId)
        ]
      )
      try database.execute(
        """
        UPDATE auto_action_dispatches
        SET status = ?, lease_token = NULL, leased_at = NULL
        WHERE dispatch_id != ? AND status = ?
        """,
        bindings: [
          .text(AutoActionDispatchStatus.dispatched.rawValue),
          .id(dispatchId),
          .text(AutoActionDispatchStatus.pending.rawValue)
        ]
      )
    }
  }
}

private struct FailingFinalReconciliationDispatcher: FinalAutoActionReconciliationDispatching {
  func dispatch(_: AutoActionDispatchRecord) async throws -> AutoActionDispatchOutcome {
    .failed("ordinary dispatch must not run during final reconciliation")
  }

  func dispatch(
    _: AutoActionDispatchRecord,
    dispatchId _: AutoActionDispatchID,
    leaseToken _: String
  ) async throws -> AutoActionDispatchOutcome {
    .failed("leased dispatch must not run during final reconciliation")
  }

  func reconcile(
    _: AutoActionDispatchRecord,
    dispatchId _: AutoActionDispatchID,
    leaseToken _: String
  ) async throws -> AutoActionDispatchOutcome {
    .failed("simulated reconciliation failure")
  }
}

private struct RecoveryDeferredDispatcher: AutoActionDispatching {
  func dispatch(_: AutoActionDispatchRecord) async throws -> AutoActionDispatchOutcome {
    .failed("translation fixture intentionally defers execution")
  }
}

private actor RecoveryCapturingInvoker: AgentInvoking {
  private var request: AgentInvocationRequest?

  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    self.request = request
    return AgentInvocationResult(markdown: "must not be invoked during durable reconciliation")
  }

  func latestRequest() -> AgentInvocationRequest? {
    request
  }
}
