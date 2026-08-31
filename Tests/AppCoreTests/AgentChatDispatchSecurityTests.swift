import Foundation
@testable import AppCore
import XCTest

private actor DisabledAccountCapturingInvoker: AgentInvoking {
  private var requests: [AgentInvocationRequest] = []

  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    requests.append(request)
    return AgentInvocationResult(markdown: "must not be returned")
  }

  func latestRequest() -> AgentInvocationRequest? {
    requests.last
  }
}

private actor PausingMidDispatchInvoker: AgentInvoking {
  private var started = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var resumeContinuation: CheckedContinuation<Void, Never>?

  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    started = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation { continuation in
      resumeContinuation = continuation
    }
    switch request.purpose {
    case .tagExtraction:
      return AgentInvocationResult(markdown: #"[{"name":"mid-dispatch-tag","class":"topic"}]"#)
    case .translation:
      return AgentInvocationResult(markdown: "translated after account disablement")
    case .chat:
      return AgentInvocationResult(markdown: "reply after account disablement")
    default:
      return AgentInvocationResult(markdown: "unused")
    }
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func resume() {
    resumeContinuation?.resume()
    resumeContinuation = nil
  }
}

private actor StaleLeaseTagInvoker: AgentInvoking {
  private var invocationCount = 0
  private var firstStartedWaiters: [CheckedContinuation<Void, Never>] = []
  private var secondCompletedWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstResume: CheckedContinuation<Void, Never>?

  func invoke(_: AgentInvocationRequest) async throws -> AgentInvocationResult {
    invocationCount += 1
    if invocationCount == 1 {
      let waiters = firstStartedWaiters
      firstStartedWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
      await withCheckedContinuation { continuation in
        firstResume = continuation
      }
      return AgentInvocationResult(markdown: #"[{"name":"stale-worker"}]"#)
    }
    let waiters = secondCompletedWaiters
    secondCompletedWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    return AgentInvocationResult(markdown: #"[{"name":"current-worker"}]"#)
  }

  func waitForFirstStart() async {
    guard invocationCount == 0 else { return }
    await withCheckedContinuation { firstStartedWaiters.append($0) }
  }

  func waitForSecondCompletion() async {
    guard invocationCount < 2 else { return }
    await withCheckedContinuation { secondCompletedWaiters.append($0) }
  }

  func resumeFirst() {
    firstResume?.resume()
    firstResume = nil
  }
}

private actor StaleLeaseChatInvoker: AgentStreamingInvoking {
  private var invocationCount = 0
  private var firstStartedWaiters: [CheckedContinuation<Void, Never>] = []
  private var secondCompletedWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstResume: CheckedContinuation<Void, Never>?

  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    guard request.purpose == .chat else {
      return AgentInvocationResult(markdown: #"[{"name":"unrelated"}]"#)
    }
    return try await invoke(request) { _ in true }
  }

  func invoke(
    _ request: AgentInvocationRequest,
    onChunk: @escaping @Sendable (String) -> Bool
  ) async throws -> AgentInvocationResult {
    invocationCount += 1
    if invocationCount == 1 {
      let waiters = firstStartedWaiters
      firstStartedWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
      await withCheckedContinuation { continuation in
        firstResume = continuation
      }
      _ = onChunk("stale-worker")
      return AgentInvocationResult(markdown: "stale-worker")
    }
    _ = onChunk("current-worker")
    let waiters = secondCompletedWaiters
    secondCompletedWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    return AgentInvocationResult(markdown: "current-worker")
  }

  func waitForFirstStart() async {
    guard invocationCount == 0 else { return }
    await withCheckedContinuation { firstStartedWaiters.append($0) }
  }

  func waitForSecondCompletion() async {
    guard invocationCount < 2 else { return }
    await withCheckedContinuation { secondCompletedWaiters.append($0) }
  }

  func resumeFirst() {
    firstResume?.resume()
    firstResume = nil
  }
}

private actor ExcessiveChunkChatInvoker: AgentStreamingInvoking {
  private var callbackCount = 0

  func invoke(_: AgentInvocationRequest) async throws -> AgentInvocationResult {
    AgentInvocationResult(markdown: "unreachable")
  }

  func invoke(
    _: AgentInvocationRequest,
    onChunk: @escaping @Sendable (String) -> Bool
  ) async throws -> AgentInvocationResult {
    for _ in 0..<(AgentReplyOutputLimits.maximumChunks + 2_000) {
      callbackCount += 1
      _ = onChunk("")
    }
    return AgentInvocationResult(markdown: "bounded reply")
  }

  func emittedChunkCount() -> Int { callbackCount }
}

private actor StreamLeaseValidationBarrier {
  private var firstLease: AgentReplyStreamLease?
  private var firstValidatedWaiters: [CheckedContinuation<Void, Never>] = []
  private var resumeFirstContinuation: CheckedContinuation<Void, Never>?

  func pauseFirstLeaseAfterValidation(_ lease: AgentReplyStreamLease) async {
    guard firstLease == nil else { return }
    firstLease = lease
    let waiters = firstValidatedWaiters
    firstValidatedWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    await withCheckedContinuation { resumeFirstContinuation = $0 }
  }

  func waitForFirstLeaseValidation() async -> AgentReplyStreamLease {
    if let firstLease { return firstLease }
    await withCheckedContinuation { firstValidatedWaiters.append($0) }
    guard let firstLease else {
      fatalError("first leased stream validation did not provide a lease")
    }
    return firstLease
  }

  func resumeFirstLease() {
    resumeFirstContinuation?.resume()
    resumeFirstContinuation = nil
  }
}

private final class RecordingReplyStreamPublisher: AgentReplyStreamPublishing, @unchecked Sendable {
  private let lock = NSLock()
  private var finishedTurnIds: [NoteID] = []
  private var chunks: [String] = []
  private var activeLeases: [NoteID: AgentReplyStreamLease] = [:]

  func publishAgentReplyChunk(turnNoteId _: NoteID, text: String, libraryId _: LibraryID) {
    lock.lock()
    chunks.append(text)
    lock.unlock()
  }

  func finishAgentReplyStream(
    turnNoteId: NoteID,
    status _: String,
    message _: String?,
    libraryId _: LibraryID
  ) {
    lock.lock()
    finishedTurnIds.append(turnNoteId)
    lock.unlock()
  }

  func beginLeasedAgentReplyStream(
    turnNoteId: NoteID,
    lease: AgentReplyStreamLease
  ) async {
    registerLease(turnNoteId: turnNoteId, lease: lease)
  }

  private func registerLease(turnNoteId: NoteID, lease: AgentReplyStreamLease) {
    lock.lock()
    if let activeLease = activeLeases[turnNoteId],
       activeLease.attemptNumber > lease.attemptNumber
        || (activeLease.attemptNumber == lease.attemptNumber && activeLease != lease) {
      lock.unlock()
      return
    }
    activeLeases[turnNoteId] = lease
    lock.unlock()
  }

  func publishLeasedAgentReplyChunk(
    turnNoteId: NoteID,
    text: String,
    libraryId _: LibraryID,
    lease: AgentReplyStreamLease
  ) async {
    recordLeasedChunk(turnNoteId: turnNoteId, text: text, lease: lease)
  }

  private func recordLeasedChunk(
    turnNoteId: NoteID,
    text: String,
    lease: AgentReplyStreamLease
  ) {
    lock.lock()
    defer { lock.unlock() }
    guard activeLeases[turnNoteId] == lease else { return }
    chunks.append(text)
  }

  func finishLeasedAgentReplyStream(
    turnNoteId: NoteID,
    status _: String,
    message _: String?,
    libraryId _: LibraryID,
    lease: AgentReplyStreamLease
  ) async {
    recordLeasedFinish(turnNoteId: turnNoteId, lease: lease)
  }

  private func recordLeasedFinish(turnNoteId: NoteID, lease: AgentReplyStreamLease) {
    lock.lock()
    defer { lock.unlock() }
    guard activeLeases[turnNoteId] == lease else { return }
    finishedTurnIds.append(turnNoteId)
  }

  func finishedTurns() -> [NoteID] {
    lock.lock()
    defer { lock.unlock() }
    return finishedTurnIds
  }

  func publishedChunks() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return chunks
  }
}

private struct DeferredAutoActionDispatcher: AutoActionDispatching {
  func dispatch(_: AutoActionDispatchRecord) async throws -> AutoActionDispatchOutcome {
    .failed("deferred until recovery")
  }
}

final class AgentChatDispatchSecurityTests: NoteTestCase {
  func testStreamingReplyBoundsPreHubChunksFromAnUncooperativeProvider() async throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\nBound output")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Answer",
      agentAvailable: true
    )
    let invoker = ExcessiveChunkChatInvoker()
    let publisher = RecordingReplyStreamPublisher()
    let dispatcher = KaibaAutoActionDispatcher(
      service: service,
      invoker: invoker,
      streamPublisher: publisher
    )
    let outcome = try await dispatcher.dispatch(AutoActionDispatchRecord(
      action: AutoAction(
        actionId: NoteStoreSchema.agentChatReplyActionId,
        trigger: .noteCreated,
        workflowId: NoteStoreSchema.agentChatReplyWorkflowId,
        createdAt: NoteStoreClock.system.now()
      ),
      event: NoteAutoActionEvent(
        trigger: .noteCreated,
        notebookId: conversation.notebookId,
        noteId: turn.noteId,
        originatingUserId: NoteStoreSchema.defaultUserId,
        originatingIsUnauthenticatedPrincipal: false
      )
    ))

    guard case .failed = outcome else {
      return XCTFail("expected bounded producer output to fail the chat dispatch")
    }
    let emittedChunkCount = await invoker.emittedChunkCount()
    XCTAssertEqual(emittedChunkCount, AgentReplyOutputLimits.maximumChunks + 2_000)
    XCTAssertLessThanOrEqual(publisher.publishedChunks().count, AgentReplyOutputLimits.maximumChunks)
    XCTAssertEqual(NoteService.chatTurnState(of: try service.getNote(turn.noteId))?.status, .failed)
  }

  func testSupersededLeaseCannotApplyStaleTagExtractionOutput() async throws {
    let bare = try makeService()
    let alice = try bare.createUser(email: "alice@example.com", displayName: "Alice")
    let note = try bare.scoped(to: alice.userId).createNote(bodyMarkdown: "# Private\nLease fencing")
    let initial = try XCTUnwrap(try bare.listAutoActionDispatchAttempts().first)
    let invoker = StaleLeaseTagInvoker()
    let dispatcher = KaibaAutoActionDispatcher(service: bare, invoker: invoker)
    let worker = try NoteService(driver: bare.driver, autoActionDispatcher: dispatcher)

    XCTAssertEqual(try worker.retryPendingAutoActionDispatches(), 1)
    await invoker.waitForFirstStart()

    // Simulate lost heartbeats: recovery reclaims the row and a new worker
    // finishes the retry while the original provider call is still blocked.
    try worker.driver.withDatabase { database in
      try database.execute(
        "UPDATE auto_action_dispatches SET leased_at = ? WHERE dispatch_id = ?",
        bindings: [.text("2000-01-01T00:00:00Z"), .id(initial.dispatchId)]
      )
    }
    XCTAssertEqual(try worker.recoverInterruptedAutoActionDispatches(olderThan: 1), 1)
    XCTAssertEqual(try worker.retryPendingAutoActionDispatches(), 1)
    await invoker.waitForSecondCompletion()
    await invoker.resumeFirst()
    await worker.drainAutoActionDispatches()

    let tags = try bare.getNote(note.noteId).tags.map(\.tag.name)
    XCTAssertTrue(tags.contains("current-worker"))
    XCTAssertFalse(tags.contains("stale-worker"))
    XCTAssertEqual(try bare.listAutoActionDispatchAttempts().first?.status, .dispatched)
  }

  func testLeasedChatStreamRejectsPublicationAfterLeaseReclaimBetweenValidationAndAdmission() async throws {
    let bare = try makeService()
    for action in AIAutoActionReconciliation.taggingActions {
      _ = try bare.configureAutoAction(
        actionId: action.actionId,
        trigger: action.trigger,
        workflowId: NoteStoreSchema.autoTaggingWorkflowId,
        enabled: false
      )
    }
    _ = try bare.configureAutoAction(
      actionId: NoteStoreSchema.agentChatReplyActionId,
      trigger: .noteCreated,
      workflowId: NoteStoreSchema.agentChatReplyWorkflowId,
      enabled: true
    )
    let alice = try bare.createUser(email: "alice@example.com", displayName: "Alice")
    let aliceService = bare.scoped(to: alice.userId)
    let subject = try aliceService.createNote(bodyMarkdown: "# Private\nLease-fenced stream")
    let conversation = try aliceService.startAgentConversation(subjectNoteId: subject.noteId)
    let turn = try aliceService.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Summarize",
      agentAvailable: true
    )
    let initial = try XCTUnwrap(try bare.listAutoActionDispatchAttempts().first {
      $0.record.action.actionId == NoteStoreSchema.agentChatReplyActionId
        && $0.record.event.noteId == turn.noteId
    })
    let invoker = StaleLeaseChatInvoker()
    let streamPublisher = RecordingReplyStreamPublisher()
    let validationBarrier = StreamLeaseValidationBarrier()
    var dispatcherService = bare
    dispatcherService.agentReplyStreamPostLeaseValidationHook = { lease in
      await validationBarrier.pauseFirstLeaseAfterValidation(lease)
    }
    let dispatcher = KaibaAutoActionDispatcher(
      service: dispatcherService,
      invoker: invoker,
      streamPublisher: streamPublisher
    )
    let worker = try NoteService(
      driver: bare.driver,
      autoActionDispatcher: dispatcher,
      autoActionDispatchLeaseStaleness: 0
    )

    let initialRetryCount = try worker.retryPendingAutoActionDispatches()
    guard initialRetryCount > 0 else {
      let attempt = try XCTUnwrap(try bare.listAutoActionDispatchAttempts().first {
        $0.dispatchId == initial.dispatchId
      })
      throw NoteServiceError.invalidRow(
        "could not dispatch initial leased chat attempt: \(attempt.status.rawValue), attempts \(attempt.attemptCount)"
      )
    }
    await invoker.waitForFirstStart()
    await invoker.resumeFirst()
    let staleLease = await validationBarrier.waitForFirstLeaseValidation()
    let currentLease = AgentReplyStreamLease(
      dispatchId: staleLease.dispatchId,
      token: "reclaimed-stream-lease",
      attemptNumber: staleLease.attemptNumber + 1
    )
    try worker.driver.withDatabase { database in
      try database.execute(
        "UPDATE auto_action_dispatches SET lease_token = ?, leased_at = ? WHERE dispatch_id = ?",
        bindings: [
          .text(currentLease.token),
          .text(NoteStoreClock.system.now()),
          .id(initial.dispatchId)
        ]
      )
    }
    await streamPublisher.beginLeasedAgentReplyStream(turnNoteId: turn.noteId, lease: currentLease)
    await streamPublisher.publishLeasedAgentReplyChunk(
      turnNoteId: turn.noteId,
      text: "current-worker",
      libraryId: conversation.libraryId ?? LibraryID("library-default"),
      lease: currentLease
    )
    await streamPublisher.finishLeasedAgentReplyStream(
      turnNoteId: turn.noteId,
      status: "answered",
      message: nil,
      libraryId: conversation.libraryId ?? LibraryID("library-default"),
      lease: currentLease
    )
    await validationBarrier.resumeFirstLease()
    await worker.drainAutoActionDispatches()
    try bare.driver.withDatabase { database in
      try database.execute(
        "UPDATE auto_action_dispatches SET status = ?, lease_token = NULL, leased_at = NULL WHERE dispatch_id = ? AND lease_token = ?",
        bindings: [
          .text(AutoActionDispatchStatus.dispatched.rawValue),
          .id(initial.dispatchId),
          .text(currentLease.token)
        ]
      )
    }

    XCTAssertEqual(streamPublisher.publishedChunks(), ["current-worker"])
    XCTAssertEqual(streamPublisher.finishedTurns(), [turn.noteId])
    XCTAssertFalse(try bare.getNote(turn.noteId).bodyMarkdown.contains("stale-worker"))
  }

  func testLeasedCancellationDoesNotFallbackToUnleasedTerminalAfterLeaseReclaim() async throws {
    let bare = try makeService()
    for action in AIAutoActionReconciliation.taggingActions {
      _ = try bare.configureAutoAction(
        actionId: action.actionId,
        trigger: action.trigger,
        workflowId: NoteStoreSchema.autoTaggingWorkflowId,
        enabled: false
      )
    }
    _ = try bare.configureAutoAction(
      actionId: NoteStoreSchema.agentChatReplyActionId,
      trigger: .noteCreated,
      workflowId: NoteStoreSchema.agentChatReplyWorkflowId,
      enabled: true
    )
    let alice = try bare.createUser(email: "cancel-stream@example.com", displayName: "Cancel stream")
    let aliceService = bare.scoped(to: alice.userId)
    let subject = try aliceService.createNote(bodyMarkdown: "# Private\nCancelled stream")
    let conversation = try aliceService.startAgentConversation(subjectNoteId: subject.noteId)
    let turn = try aliceService.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Summarize",
      agentAvailable: true
    )
    let attempt = try XCTUnwrap(try bare.listAutoActionDispatchAttempts().first {
      $0.record.action.actionId == NoteStoreSchema.agentChatReplyActionId
        && $0.record.event.noteId == turn.noteId
    })
    try claimAndAgeLease(dispatchId: attempt.dispatchId, service: bare)
    _ = try bare.setUserDisabled(userId: alice.userId, disabled: true)

    let streamPublisher = RecordingReplyStreamPublisher()
    let validationBarrier = StreamLeaseValidationBarrier()
    var dispatcherService = bare
    dispatcherService.agentReplyStreamPostLeaseValidationHook = { lease in
      await validationBarrier.pauseFirstLeaseAfterValidation(lease)
    }
    let dispatcher = KaibaAutoActionDispatcher(
      service: dispatcherService,
      invoker: DisabledAccountCapturingInvoker(),
      streamPublisher: streamPublisher
    )

    let cancellation = Task {
      try await dispatcher.dispatch(
        attempt.record,
        dispatchId: attempt.dispatchId,
        leaseToken: "simulated-lost-lease"
      )
    }
    let staleLease = await validationBarrier.waitForFirstLeaseValidation()
    let currentLease = AgentReplyStreamLease(
      dispatchId: staleLease.dispatchId,
      token: "reclaimed-cancellation-lease",
      attemptNumber: staleLease.attemptNumber + 1
    )
    try bare.driver.withDatabase { database in
      try database.execute(
        """
        UPDATE auto_action_dispatches
        SET lease_token = ?, attempt_count = attempt_count + 1, leased_at = ?
        WHERE dispatch_id = ? AND lease_token = ?
        """,
        bindings: [
          .text(currentLease.token),
          .text(NoteStoreClock.system.now()),
          .id(attempt.dispatchId),
          .text(staleLease.token)
        ]
      )
    }
    await streamPublisher.beginLeasedAgentReplyStream(turnNoteId: turn.noteId, lease: currentLease)
    await streamPublisher.finishLeasedAgentReplyStream(
      turnNoteId: turn.noteId,
      status: "answered",
      message: nil,
      libraryId: conversation.libraryId ?? LibraryID("library-default"),
      lease: currentLease
    )
    await validationBarrier.resumeFirstLease()

    let cancellationOutcome = try await cancellation.value
    XCTAssertEqual(cancellationOutcome, .cancelled("auto-action originating account is unavailable"))
    XCTAssertEqual(streamPublisher.finishedTurns(), [turn.noteId])
  }

  func testPreInvocationDisableCancelsChatWithoutProviderDisclosure() async throws {
    let bare = try makeService()
    let alice = try bare.createUser(email: "alice@example.com", displayName: "Alice")
    let aliceService = bare.scoped(to: alice.userId)
    let subject = try aliceService.createNote(bodyMarkdown: "# Subject\nPrivate")
    let conversation = try aliceService.startAgentConversation(subjectNoteId: subject.noteId)
    let turn = try aliceService.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Summarize",
      agentAvailable: true
    )
    let invoker = DisabledAccountCapturingInvoker()
    var dispatchService = bare
    dispatchService.providerInvocationPreAdmissionHook = {
      _ = try? bare.setUserDisabled(userId: alice.userId, disabled: true)
    }
    let dispatcher = KaibaAutoActionDispatcher(service: dispatchService, invoker: invoker)
    let record = AutoActionDispatchRecord(
      action: AutoAction(
        actionId: NoteStoreSchema.agentChatReplyActionId,
        trigger: .noteCreated,
        workflowId: NoteStoreSchema.agentChatReplyWorkflowId,
        createdAt: NoteStoreClock.system.now()
      ),
      event: NoteAutoActionEvent(
        trigger: .noteCreated,
        notebookId: conversation.notebookId,
        noteId: turn.noteId,
        originatingUserId: alice.userId,
        originatingIsUnauthenticatedPrincipal: false
      )
    )
    let dispatchedOutcome = try await dispatcher.dispatch(record)
    XCTAssertEqual(dispatchedOutcome, AutoActionDispatchOutcome.cancelled("auto-action originating account is unavailable"))
    let capturedRequest = await invoker.latestRequest()
    XCTAssertNil(capturedRequest)
    let storedTurn = try bare.getNote(turn.noteId)
    XCTAssertEqual(NoteService.chatTurnState(of: storedTurn)?.status, .cancelled)
    XCTAssertFalse(storedTurn.bodyMarkdown.contains("reply after account disablement"))
  }

  func testPreInvocationDisableCancelsTranslationWithoutProviderDisclosure() async throws {
    let bare = try makeService()
    let alice = try bare.createUser(email: "alice@example.com", displayName: "Alice")
    let aliceService = bare.scoped(to: alice.userId)
    let source = try aliceService.createNotebookWithNotes(
      title: "Private source",
      pages: [NotePageDraft(bodyMarkdown: "# Private\nDo not persist translation")]
    )
    let pending = try aliceService.startNotebookTranslation(
      sourceNotebookId: source.notebook.notebookId,
      targetLanguage: "English"
    )
    let invoker = DisabledAccountCapturingInvoker()
    var dispatchService = bare
    dispatchService.providerInvocationPreAdmissionHook = {
      _ = try? bare.setUserDisabled(userId: alice.userId, disabled: true)
    }
    let dispatcher = KaibaAutoActionDispatcher(service: dispatchService, invoker: invoker)
    let record = AutoActionDispatchRecord(
      action: AutoAction(
        actionId: AutoActionID("mid-dispatch-translation"),
        trigger: .notebookCreated,
        workflowId: NoteStoreSchema.notebookTranslationWorkflowId,
        createdAt: NoteStoreClock.system.now()
      ),
      event: NoteAutoActionEvent(
        trigger: .notebookCreated,
        notebookId: pending.notebookId,
        originatingUserId: alice.userId,
        originatingIsUnauthenticatedPrincipal: false
      )
    )
    let dispatchedOutcome = try await dispatcher.dispatch(record)
    XCTAssertEqual(dispatchedOutcome, AutoActionDispatchOutcome.cancelled("auto-action originating account is unavailable"))
    let capturedRequest = await invoker.latestRequest()
    XCTAssertNil(capturedRequest)
    XCTAssertEqual(NoteService.translationState(of: try bare.getNotebook(pending.notebookId))?.status, .cancelled)
    XCTAssertTrue(try bare.listNotes(notebookId: pending.notebookId, limit: 10, offset: 0).isEmpty)
  }

  func testPreInvocationDisableCancelsTagExtractionWithoutProviderDisclosure() async throws {
    let bare = try makeService()
    let alice = try bare.createUser(email: "alice@example.com", displayName: "Alice")
    let note = try bare.scoped(to: alice.userId).createNote(bodyMarkdown: "# Private\nNo tags after disable")
    let invoker = DisabledAccountCapturingInvoker()
    var dispatchService = bare
    dispatchService.providerInvocationPreAdmissionHook = {
      _ = try? bare.setUserDisabled(userId: alice.userId, disabled: true)
    }
    let dispatcher = KaibaAutoActionDispatcher(service: dispatchService, invoker: invoker)
    let record = AutoActionDispatchRecord(
      action: AutoAction(
        actionId: AutoActionID("mid-dispatch-tag"),
        trigger: .noteCreated,
        workflowId: NoteStoreSchema.autoTaggingWorkflowId,
        createdAt: NoteStoreClock.system.now()
      ),
      event: NoteAutoActionEvent(
        trigger: .noteCreated,
        notebookId: note.notebookId,
        noteId: note.noteId,
        originatingUserId: alice.userId,
        originatingIsUnauthenticatedPrincipal: false
      )
    )
    let dispatchedOutcome = try await dispatcher.dispatch(record)
    XCTAssertEqual(dispatchedOutcome, AutoActionDispatchOutcome.cancelled("auto-action originating account is unavailable"))
    let capturedRequest = await invoker.latestRequest()
    XCTAssertNil(capturedRequest)
    XCTAssertTrue(try bare.getNote(note.noteId).tags.isEmpty)
  }

  func testRecoveredQueuedReplyCancelsWhenOriginatingAccountWasDisabled() async throws {
    let bare = try makeService()
    for action in AIAutoActionReconciliation.taggingActions {
      _ = try bare.configureAutoAction(
        actionId: action.actionId,
        trigger: action.trigger,
        workflowId: NoteStoreSchema.autoTaggingWorkflowId,
        enabled: false
      )
    }
    let alice = try bare.createUser(email: "alice@example.com", displayName: "Alice")
    let aliceService = bare.scoped(to: alice.userId)
    let subject = try aliceService.createNote(bodyMarkdown: "# Subject\nPrivate context")
    let conversation = try aliceService.startAgentConversation(subjectNoteId: subject.noteId)
    try bare.configureAutoAction(
      actionId: NoteStoreSchema.agentChatReplyActionId,
      trigger: .noteCreated,
      workflowId: NoteStoreSchema.agentChatReplyWorkflowId,
      enabled: true
    )
    let turn = try aliceService.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Question",
      agentAvailable: true
    )
    _ = try bare.setUserDisabled(userId: alice.userId, disabled: true)

    let invoker = DisabledAccountCapturingInvoker()
    let dispatcher = KaibaAutoActionDispatcher(service: bare, invoker: invoker)
    let recovered = try NoteService(driver: bare.driver, autoActionDispatcher: dispatcher)
    XCTAssertEqual(try recovered.retryPendingAutoActionDispatches(), 1)
    await recovered.drainAutoActionDispatches()

    let capturedRequest = await invoker.latestRequest()
    XCTAssertNil(capturedRequest)
    XCTAssertEqual(NoteService.chatTurnState(of: try recovered.getNote(turn.noteId))?.status, .cancelled)
    let attempt = try XCTUnwrap(try recovered.listAutoActionDispatchAttempts().first)
    XCTAssertEqual(attempt.status, .cancelled)
    XCTAssertEqual(attempt.lastError, "auto-action originating account is unavailable")
    _ = try recovered.setUserDisabled(userId: alice.userId, disabled: false)
    XCTAssertEqual(try recovered.retryPendingAutoActionDispatches(), 0)
    XCTAssertEqual(NoteService.chatTurnState(of: try recovered.getNote(turn.noteId))?.status, .cancelled)
  }

  func testCancelledChatRecoveryAfterOutboxWriteBoundaryRemainsCancelled() async throws {
    let bare = try makeService()
    for action in AIAutoActionReconciliation.taggingActions {
      _ = try bare.configureAutoAction(
        actionId: action.actionId,
        trigger: action.trigger,
        workflowId: NoteStoreSchema.autoTaggingWorkflowId,
        enabled: false
      )
    }
    let alice = try bare.createUser(email: "alice@example.com", displayName: "Alice")
    let aliceService = bare.scoped(to: alice.userId)
    let subject = try aliceService.createNote(bodyMarkdown: "# Subject\nPrivate context")
    let conversation = try aliceService.startAgentConversation(subjectNoteId: subject.noteId)
    try bare.configureAutoAction(
      actionId: NoteStoreSchema.agentChatReplyActionId,
      trigger: .noteCreated,
      workflowId: NoteStoreSchema.agentChatReplyWorkflowId,
      enabled: true
    )
    let turn = try aliceService.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Question",
      agentAvailable: true
    )
    let initialAttempt = try XCTUnwrap(try bare.listAutoActionDispatchAttempts().first)
    let record = initialAttempt.record
    try claimAndAgeLease(dispatchId: initialAttempt.dispatchId, service: bare)
    _ = try bare.setUserDisabled(userId: alice.userId, disabled: true)

    let invoker = DisabledAccountCapturingInvoker()
    let streamPublisher = RecordingReplyStreamPublisher()
    let dispatcher = KaibaAutoActionDispatcher(
      service: bare,
      invoker: invoker,
      streamPublisher: streamPublisher
    )
    // Simulate termination completing just before the process loses the
    // leased outbox acknowledgement.
    let terminalizationOutcome = try await dispatcher.dispatch(record)
    XCTAssertEqual(terminalizationOutcome, .cancelled("auto-action originating account is unavailable"))
    XCTAssertEqual(NoteService.chatTurnState(of: try bare.getNote(turn.noteId))?.status, .cancelled)
    XCTAssertEqual(streamPublisher.finishedTurns(), [turn.noteId])
    XCTAssertEqual(try bare.listAutoActionDispatchAttempts().first?.status, .inFlight)

    _ = try bare.setUserDisabled(userId: alice.userId, disabled: false)
    let recovered = try NoteService(driver: bare.driver, autoActionDispatcher: dispatcher)
    let recoveredCount = try await recovered.recoverAndRetryAutoActionDispatches(olderThan: 1)
    XCTAssertEqual(recoveredCount, 1)

    let capturedRequest = await invoker.latestRequest()
    XCTAssertNil(capturedRequest)
    XCTAssertEqual(NoteService.chatTurnState(of: try recovered.getNote(turn.noteId))?.status, .cancelled)
    let attempt = try XCTUnwrap(try recovered.listAutoActionDispatchAttempts().first)
    XCTAssertEqual(attempt.status, .cancelled)
    XCTAssertEqual(attempt.lastError, "auto-action originating account is unavailable")
  }

  func testRecoveredTagExtractionCancelsWhenOriginatingAccountWasDisabled() async throws {
    let bare = try makeService()
    for action in AIAutoActionReconciliation.taggingActions {
      _ = try bare.configureAutoAction(
        actionId: action.actionId,
        trigger: action.trigger,
        workflowId: NoteStoreSchema.autoTaggingWorkflowId,
        enabled: false
      )
    }
    let alice = try bare.createUser(email: "alice@example.com", displayName: "Alice")
    try bare.configureAutoAction(
      actionId: AIAutoActionReconciliation.taggingActions[0].actionId,
      trigger: .noteCreated,
      workflowId: NoteStoreSchema.autoTaggingWorkflowId,
      enabled: true
    )
    let note = try bare.scoped(to: alice.userId).createNote(bodyMarkdown: "# Private\nDo not send")
    _ = try bare.setUserDisabled(userId: alice.userId, disabled: true)

    let invoker = DisabledAccountCapturingInvoker()
    let dispatcher = KaibaAutoActionDispatcher(service: bare, invoker: invoker)
    let recovered = try NoteService(driver: bare.driver, autoActionDispatcher: dispatcher)
    XCTAssertEqual(try recovered.retryPendingAutoActionDispatches(), 1)
    await recovered.drainAutoActionDispatches()

    let capturedRequest = await invoker.latestRequest()
    XCTAssertNil(capturedRequest)
    XCTAssertTrue(try recovered.getNote(note.noteId).tags.isEmpty)
    let attempt = try XCTUnwrap(try recovered.listAutoActionDispatchAttempts().first)
    XCTAssertEqual(attempt.status, .cancelled)
    XCTAssertEqual(attempt.lastError, "auto-action originating account is unavailable")
  }

  func testCancelledTagExtractionRecoveryAfterOutboxWriteBoundaryRemainsCancelled() async throws {
    let bare = try makeService()
    for action in AIAutoActionReconciliation.taggingActions {
      _ = try bare.configureAutoAction(
        actionId: action.actionId,
        trigger: action.trigger,
        workflowId: NoteStoreSchema.autoTaggingWorkflowId,
        enabled: false
      )
    }
    let alice = try bare.createUser(email: "alice@example.com", displayName: "Alice")
    try bare.configureAutoAction(
      actionId: AIAutoActionReconciliation.taggingActions[0].actionId,
      trigger: .noteCreated,
      workflowId: NoteStoreSchema.autoTaggingWorkflowId,
      enabled: true
    )
    let note = try bare.scoped(to: alice.userId).createNote(bodyMarkdown: "# Private\nDo not send")
    let initialAttempt = try XCTUnwrap(try bare.listAutoActionDispatchAttempts().first)
    try claimAndAgeLease(dispatchId: initialAttempt.dispatchId, service: bare)
    _ = try bare.setUserDisabled(userId: alice.userId, disabled: true)

    let invoker = DisabledAccountCapturingInvoker()
    let dispatcher = KaibaAutoActionDispatcher(service: bare, invoker: invoker)
    // Simulate cancellation finishing after the dispatch is leased but before
    // the caller can acknowledge its outcome to the outbox worker.
    let outcome = try await dispatcher.dispatch(
      initialAttempt.record,
      dispatchId: initialAttempt.dispatchId,
      leaseToken: "simulated-lost-lease"
    )
    XCTAssertEqual(outcome, .cancelled("auto-action originating account is unavailable"))
    XCTAssertEqual(try bare.listAutoActionDispatchAttempts().first?.status, .cancelled)

    _ = try bare.setUserDisabled(userId: alice.userId, disabled: false)
    let recovered = try NoteService(driver: bare.driver, autoActionDispatcher: dispatcher)
    let recoveredCount = try await recovered.recoverAndRetryAutoActionDispatches(olderThan: 1)
    XCTAssertEqual(recoveredCount, 0)

    let capturedRequest = await invoker.latestRequest()
    XCTAssertNil(capturedRequest)
    XCTAssertTrue(try recovered.getNote(note.noteId).tags.isEmpty)
    let attempt = try XCTUnwrap(try recovered.listAutoActionDispatchAttempts().first)
    XCTAssertEqual(attempt.status, .cancelled)
    XCTAssertEqual(attempt.lastError, "auto-action originating account is unavailable")
  }

  func testRecoveredTranslationCancelsWhenOriginatingAccountWasDisabled() async throws {
    let bare = try makeService()
    for action in AIAutoActionReconciliation.taggingActions {
      _ = try bare.configureAutoAction(
        actionId: action.actionId,
        trigger: action.trigger,
        workflowId: NoteStoreSchema.autoTaggingWorkflowId,
        enabled: false
      )
    }
    let alice = try bare.createUser(email: "alice@example.com", displayName: "Alice")
    let queued = try NoteService(
      driver: bare.driver,
      autoActionDispatcher: DeferredAutoActionDispatcher()
    ).scoped(to: alice.userId)
    let source = try queued.createNotebookWithNotes(
      title: "Private source",
      pages: [NotePageDraft(bodyMarkdown: "# Private\nDo not send")]
    )
    let (pending, didQueue) = try queued.requestNotebookTranslation(
      sourceNotebookId: source.notebook.notebookId,
      targetLanguage: "English"
    )
    XCTAssertTrue(didQueue)
    let pendingNotebook = try XCTUnwrap(pending)
    await queued.drainAutoActionDispatches()
    _ = try bare.setUserDisabled(userId: alice.userId, disabled: true)

    let invoker = DisabledAccountCapturingInvoker()
    let dispatcher = KaibaAutoActionDispatcher(service: bare, invoker: invoker)
    let recovered = try NoteService(driver: bare.driver, autoActionDispatcher: dispatcher)
    XCTAssertEqual(try recovered.retryPendingAutoActionDispatches(), 1)
    await recovered.drainAutoActionDispatches()

    let capturedRequest = await invoker.latestRequest()
    XCTAssertNil(capturedRequest)
    XCTAssertEqual(
      NoteService.translationState(of: try recovered.getNotebook(pendingNotebook.notebookId))?.status,
      .cancelled
    )
    let attempt = try XCTUnwrap(try recovered.listAutoActionDispatchAttempts().first)
    XCTAssertEqual(attempt.status, .cancelled)
    XCTAssertEqual(attempt.lastError, "auto-action originating account is unavailable")
    _ = try recovered.setUserDisabled(userId: alice.userId, disabled: false)
    XCTAssertEqual(try recovered.retryPendingAutoActionDispatches(), 0)
    XCTAssertEqual(
      NoteService.translationState(of: try recovered.getNotebook(pendingNotebook.notebookId))?.status,
      .cancelled
    )
  }

  func testCancelledTranslationRecoveryAfterOutboxWriteBoundaryRemainsCancelled() async throws {
    let bare = try makeService()
    for action in AIAutoActionReconciliation.taggingActions {
      _ = try bare.configureAutoAction(
        actionId: action.actionId,
        trigger: action.trigger,
        workflowId: NoteStoreSchema.autoTaggingWorkflowId,
        enabled: false
      )
    }
    let alice = try bare.createUser(email: "alice@example.com", displayName: "Alice")
    let queued = try NoteService(
      driver: bare.driver,
      autoActionDispatcher: DeferredAutoActionDispatcher()
    ).scoped(to: alice.userId)
    let source = try queued.createNotebookWithNotes(
      title: "Private source",
      pages: [NotePageDraft(bodyMarkdown: "# Private\nDo not send")]
    )
    let (pending, didQueue) = try queued.requestNotebookTranslation(
      sourceNotebookId: source.notebook.notebookId,
      targetLanguage: "English"
    )
    XCTAssertTrue(didQueue)
    let pendingNotebook = try XCTUnwrap(pending)
    await queued.drainAutoActionDispatches()
    let initialAttempt = try XCTUnwrap(try bare.listAutoActionDispatchAttempts().first)
    let record = initialAttempt.record
    try claimAndAgeLease(dispatchId: initialAttempt.dispatchId, service: bare)
    _ = try bare.setUserDisabled(userId: alice.userId, disabled: true)

    let invoker = DisabledAccountCapturingInvoker()
    let dispatcher = KaibaAutoActionDispatcher(service: bare, invoker: invoker)
    let terminalizationOutcome = try await dispatcher.dispatch(record)
    XCTAssertEqual(terminalizationOutcome, .cancelled("auto-action originating account is unavailable"))
    XCTAssertEqual(
      NoteService.translationState(of: try bare.getNotebook(pendingNotebook.notebookId))?.status,
      .cancelled
    )
    XCTAssertEqual(try bare.listAutoActionDispatchAttempts().first?.status, .inFlight)

    _ = try bare.setUserDisabled(userId: alice.userId, disabled: false)
    let recovered = try NoteService(driver: bare.driver, autoActionDispatcher: dispatcher)
    let recoveredCount = try await recovered.recoverAndRetryAutoActionDispatches(olderThan: 1)
    XCTAssertEqual(recoveredCount, 1)

    let capturedRequest = await invoker.latestRequest()
    XCTAssertNil(capturedRequest)
    let attempt = try XCTUnwrap(try recovered.listAutoActionDispatchAttempts().first)
    XCTAssertEqual(attempt.status, .cancelled)
    XCTAssertEqual(attempt.lastError, "auto-action originating account is unavailable")
    XCTAssertEqual(
      NoteService.translationState(of: try recovered.getNotebook(pendingNotebook.notebookId))?.status,
      .cancelled
    )
  }

  private func claimAndAgeLease(dispatchId: AutoActionDispatchID, service: NoteService) throws {
    try service.driver.withDatabase { database in
      let changedRows = try database.executeAndReturnChangedRowCount(
        """
        UPDATE auto_action_dispatches
        SET attempt_count = attempt_count + 1,
          status = ?,
          lease_token = ?,
          leased_at = ?,
          last_error = NULL,
          updated_at = ?
        WHERE dispatch_id = ? AND status = ?
        """,
        bindings: [
          .text(AutoActionDispatchStatus.inFlight.rawValue),
          .text("simulated-lost-lease"),
          .text("2000-01-01T00:00:00Z"),
          .text("2000-01-01T00:00:00Z"),
          .id(dispatchId),
          .text(AutoActionDispatchStatus.pending.rawValue)
        ]
      )
      guard changedRows == 1 else {
        throw NoteServiceError.invalidRow("could not simulate claimed auto-action dispatch")
      }
    }
  }
}
