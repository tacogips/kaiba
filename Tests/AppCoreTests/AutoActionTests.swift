import Foundation
@testable import AppCore
import XCTest

final class AutoActionTests: NoteTestCase {
  func testCreateNoteDispatchesSeededNoteCreatedActionAfterCommit() async throws {
    let dispatcher = RecordingAutoActionDispatcher()
    let service = try makeService(autoActionDispatcher: dispatcher)

    let note = try service.createNote(bodyMarkdown: "# Auto\nBody")
    await service.drainAutoActionDispatches()

    let records = dispatcher.records()
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(records.first?.action.actionId, AutoActionID("default-ai-tagging-note-created"))
    XCTAssertEqual(records.first?.event.trigger, .noteCreated)
    XCTAssertEqual(records.first?.event.noteId, note.noteId)
    XCTAssertEqual(records.first?.event.noteBodyMarkdown, note.bodyMarkdown)
    XCTAssertEqual(try service.getNote(note.noteId).noteId, note.noteId)
    let attempts = try service.listAutoActionDispatchAttempts()
    XCTAssertEqual(attempts.count, 1)
    XCTAssertEqual(attempts.first?.status, .dispatched)
    XCTAssertEqual(attempts.first?.attemptCount, 1)
  }

  func testUpdateNoteSuppressesAllDispatchWhenOriginatingActionIsSet() async throws {
    let dispatcher = RecordingAutoActionDispatcher()
    let service = try makeService(autoActionDispatcher: dispatcher)
    let note = try service.createNote(bodyMarkdown: "# Auto\nBody")
    await service.drainAutoActionDispatches()
    dispatcher.removeAll()
    _ = try service.configureAutoAction(
      actionId: AutoActionID("custom-update"),
      trigger: .noteUpdated,
      workflowId: WorkflowID("custom-workflow"),
      position: -1
    )

    _ = try service.updateNoteBody(
      noteId: note.noteId,
      bodyMarkdown: "# Auto\nChanged",
      originatingActionId: AutoActionID("custom-update")
    )
    await service.drainAutoActionDispatches()

    XCTAssertTrue(dispatcher.records().isEmpty)
  }

  func testConfiguredAutoActionCanBeDeleted() throws {
    let service = try makeService()
    _ = try service.configureAutoAction(
      actionId: AutoActionID("temporary-action"),
      trigger: .noteCreated,
      workflowId: WorkflowID("temporary-workflow")
    )
    XCTAssertTrue(try service.listAutoActions().contains { $0.actionId == AutoActionID("temporary-action") })

    try service.deleteAutoAction(actionId: AutoActionID("temporary-action"))

    XCTAssertFalse(try service.listAutoActions().contains { $0.actionId == AutoActionID("temporary-action") })
    XCTAssertThrowsError(try service.deleteAutoAction(actionId: AutoActionID("temporary-action"))) { error in
      XCTAssertEqual(error as? NoteServiceError, .notFound("auto action not found: temporary-action"))
    }
  }

  func testCreateNoteSuppressesDispatchWhenOriginatingActionIsSet() async throws {
    let dispatcher = RecordingAutoActionDispatcher()
    let service = try makeService(autoActionDispatcher: dispatcher)

    _ = try service.createNote(
      bodyMarkdown: "# Auto\nBody",
      originatingActionId: AutoActionID("workflow-action")
    )
    await service.drainAutoActionDispatches()

    XCTAssertTrue(dispatcher.records().isEmpty)
  }

  func testEnqueueWithoutDispatcherStillRecordsPendingRow() throws {
    // With no dispatcher wired, enqueue must still record a pending row so a
    // later `riela note auto-action retry` (or app tick) can run it.
    let service = try makeService()

    _ = try service.createNote(bodyMarkdown: "# Pending\nBody")

    let attempts = try service.listAutoActionDispatchAttempts()
    XCTAssertEqual(attempts.count, 1)
    XCTAssertEqual(attempts.first?.status, .pending)
    XCTAssertEqual(attempts.first?.attemptCount, 0)
  }

  func testQueuedDispatchDefersWithoutConsumingRetryWhenProviderAdmissionIsFull() async throws {
    let admission = AgentExecutionAdmission(
      maximumConcurrentExecutions: 1,
      maximumConcurrentExecutionsPerPrincipal: 1
    )
    let held = try XCTUnwrap(admission.acquire(principalId: "operator"))
    let dispatcher = RecordingAutoActionDispatcher()
    var service = try makeService(autoActionDispatcher: dispatcher)
    service.agentExecutionAdmission = admission

    _ = try service.createNote(bodyMarkdown: "# Admission controlled")
    await service.drainAutoActionDispatches()
    let deferred = try XCTUnwrap(try service.listAutoActionDispatchAttempts().first)
    XCTAssertEqual(deferred.status, .pending)
    XCTAssertEqual(deferred.attemptCount, 0)
    XCTAssertTrue(dispatcher.records().isEmpty)

    admission.release(held)
    XCTAssertEqual(try service.retryPendingAutoActionDispatches(), 1)
    await service.drainAutoActionDispatches()
    XCTAssertEqual(try service.listAutoActionDispatchAttempts().first?.status, .dispatched)
    XCTAssertEqual(dispatcher.records().count, 1)
  }

  func testDispatchFailureDoesNotFailOriginatingWrite() async throws {
    let dispatcher = RecordingAutoActionDispatcher(shouldThrow: true)
    let service = try makeService(autoActionDispatcher: dispatcher)

    let note = try service.createNote(bodyMarkdown: "# Durable\nBody")
    await service.drainAutoActionDispatches()

    XCTAssertEqual(try service.getNote(note.noteId).title, "Durable")
    XCTAssertEqual(dispatcher.records().count, 1)
    let attempts = try service.listAutoActionDispatchAttempts(status: .pending)
    XCTAssertEqual(attempts.count, 1)
    XCTAssertEqual(attempts.first?.record.event.noteId, note.noteId)
    XCTAssertEqual(attempts.first?.attemptCount, 1)
    XCTAssertNotNil(attempts.first?.lastError)
  }

  func testPendingAutoActionDispatchCanBeRetried() async throws {
    let dispatcher = RecordingAutoActionDispatcher(failuresBeforeSuccess: 1)
    let service = try makeService(autoActionDispatcher: dispatcher)

    let note = try service.createNote(bodyMarkdown: "# Retry\nBody")
    await service.drainAutoActionDispatches()

    XCTAssertEqual(try service.listAutoActionDispatchAttempts(status: .pending).count, 1)
    XCTAssertEqual(try service.retryPendingAutoActionDispatches(), 1)
    await service.drainAutoActionDispatches()
    let attempts = try service.listAutoActionDispatchAttempts()
    XCTAssertEqual(attempts.count, 1)
    XCTAssertEqual(attempts.first?.record.event.noteId, note.noteId)
    XCTAssertEqual(attempts.first?.status, .dispatched)
    XCTAssertEqual(attempts.first?.attemptCount, 2)
    XCTAssertNil(attempts.first?.lastError)
    XCTAssertEqual(dispatcher.records().count, 2)
  }

  func testAutoActionRetryAndRecoveryHoldAdministratorAuthorizationAgainstConcurrentDemotion() async throws {
    let service = try makeService()
    let administrator = try service.createUser(
      email: "auto-action-admin@example.com",
      displayName: "Auto-action Administrator",
      isAdmin: true
    )
    _ = try service.createNote(bodyMarkdown: "# Pending\nBody")
    let dispatchId = try XCTUnwrap(try service.listAutoActionDispatchAttempts().first?.dispatchId)
    let databasePath = service.driver.databasePath
    var administratorService = service.scoped(to: administrator.userId)
    let dispatcher = RecordingAutoActionDispatcher()
    administratorService.autoActionDispatcher = dispatcher
    administratorService.autoActionMaintenanceAuthHook = { _ in
      let concurrent = try SQLiteDatabase.open(
        path: databasePath,
        options: SQLiteOpenOptions(
          enableWAL: false,
          busyTimeoutMilliseconds: 0,
          requireJSONB: false,
          requireFTS5: false
        )
      )
      let updateSucceeded: Bool
      do {
        try concurrent.execute(
          "UPDATE users SET is_admin = 0 WHERE user_id = ?",
          bindings: [.id(administrator.userId)]
        )
        updateSucceeded = true
      } catch {
        updateSucceeded = false
      }
      guard !updateSucceeded else {
        throw NoteServiceError.conflict(
          "administrator demotion interleaved with auto-action control-plane work"
        )
      }
    }

    // The hook runs inside the authorization/selection transaction. The
    // concurrent demotion must fail before retry can claim this pending row.
    XCTAssertEqual(try administratorService.retryPendingAutoActionDispatches(), 1)
    await administratorService.drainAutoActionDispatches()
    XCTAssertEqual(dispatcher.records().count, 1)

    try service.driver.withDatabase { database in
      try database.execute(
        """
        UPDATE auto_action_dispatches
        SET status = ?, lease_token = ?, leased_at = ?
        WHERE dispatch_id = ?
        """,
        bindings: [
          .text(AutoActionDispatchStatus.inFlight.rawValue),
          .text("expired-lease"),
          .text("1970-01-01T00:00:00.000Z"),
          .id(dispatchId)
        ]
      )
    }

    XCTAssertEqual(try administratorService.recoverInterruptedAutoActionDispatches(), 1)
    XCTAssertEqual(try service.listAutoActionDispatchAttempts(status: .pending).count, 1)
    XCTAssertTrue(try XCTUnwrap(service.user(id: administrator.userId)).isAdmin)
  }

  func testAutoActionListingsHoldAdministratorAuthorizationAgainstConcurrentDemotion() throws {
    let service = try makeService()
    let administrator = try service.createUser(
      email: "listing-auto-action-admin@example.com",
      displayName: "Listing Auto-action Administrator",
      isAdmin: true
    )
    _ = try service.createNote(bodyMarkdown: "# Pending\nBody")
    let databasePath = service.driver.databasePath

    func assertListingIsTransactional(_ list: (NoteService) throws -> Void) throws {
      var scoped = service.scoped(to: administrator.userId)
      scoped.autoActionListAfterAuthorizationHook = { _ in
        let concurrent = try SQLiteDatabase.open(
          path: databasePath,
          options: SQLiteOpenOptions(
            enableWAL: false,
            busyTimeoutMilliseconds: 0,
            requireJSONB: false,
            requireFTS5: false
          )
        )
        let updateSucceeded: Bool
        do {
          try concurrent.execute(
            "UPDATE users SET is_admin = 0 WHERE user_id = ?",
            bindings: [.id(administrator.userId)]
          )
          updateSucceeded = true
        } catch {
          updateSucceeded = false
        }
        guard !updateSucceeded else {
          throw NoteServiceError.conflict(
            "administrator demotion interleaved with auto-action listing"
          )
        }
      }
      try list(scoped)
    }

    try assertListingIsTransactional { scoped in
      XCTAssertFalse(try scoped.listAutoActions().isEmpty)
    }
    try assertListingIsTransactional { scoped in
      XCTAssertFalse(try scoped.listAutoActionDispatchAttempts().isEmpty)
    }
  }

  func testInFlightAutoActionDispatchCannotBeClaimedAgain() async throws {
    let dispatcher = DelayedAutoActionDispatcher()
    let service = try makeService(autoActionDispatcher: dispatcher)

    _ = try service.createNote(bodyMarkdown: "# In Flight\nBody")
    await dispatcher.waitForFirstDispatch()

    XCTAssertEqual(dispatcher.records().count, 1)
    XCTAssertEqual(try service.listAutoActionDispatchAttempts(status: .inFlight).count, 1)
    // A fresh in-flight lease is not eligible for retry (still pending-only).
    XCTAssertEqual(try service.retryPendingAutoActionDispatches(), 0)
    XCTAssertEqual(dispatcher.records().count, 1)

    dispatcher.completeAll(.succeeded)
    await service.drainAutoActionDispatches()

    let attempts = try service.listAutoActionDispatchAttempts()
    XCTAssertEqual(attempts.first?.status, .dispatched)
    XCTAssertEqual(attempts.first?.attemptCount, 1)
  }

  func testSecondServiceDoesNotResetOrRerunFreshInFlightRow() async throws {
    // A second NoteService opened over the same DB must not re-run a live,
    // freshly in-flight row: recovery is gated on the staleness window.
    let noteRoot = try makeNoteRoot(function: #function)
    let driver = SQLiteNoteDatabaseDriver(noteRoot: noteRoot)
    let delayedDispatcher = DelayedAutoActionDispatcher()
    let service = try NoteService(driver: driver, autoActionDispatcher: delayedDispatcher)
    try enableSeededAutoActions(driver: driver)

    _ = try service.createNote(bodyMarkdown: "# Live\nBody")
    await delayedDispatcher.waitForFirstDispatch()
    XCTAssertEqual(try service.listAutoActionDispatchAttempts(status: .inFlight).count, 1)

    let retryDispatcher = RecordingAutoActionDispatcher()
    let recoveredService = try NoteService(driver: driver, autoActionDispatcher: retryDispatcher)
    // init no longer recovers; an explicit recover with the default 15-min
    // window leaves the fresh lease alone.
    _ = try await recoveredService.recoverAndRetryAutoActionDispatches()

    XCTAssertTrue(retryDispatcher.records().isEmpty)
    XCTAssertEqual(try recoveredService.listAutoActionDispatchAttempts(status: .inFlight).count, 1)

    delayedDispatcher.completeAll(.succeeded)
    await service.drainAutoActionDispatches()
  }

  func testExpiredInFlightLeaseIsReclaimedExactlyOnce() async throws {
    let noteRoot = try makeNoteRoot(function: #function)
    let driver = SQLiteNoteDatabaseDriver(noteRoot: noteRoot)
    let delayedDispatcher = DelayedAutoActionDispatcher()
    let service = try NoteService(driver: driver, autoActionDispatcher: delayedDispatcher)
    try enableSeededAutoActions(driver: driver)

    _ = try service.createNote(bodyMarkdown: "# Stale\nBody")
    await delayedDispatcher.waitForFirstDispatch()
    let dispatchId = try XCTUnwrap(try service.listAutoActionDispatchAttempts(status: .inFlight).first?.dispatchId)
    ageAutoActionLease(driver: driver, dispatchId: dispatchId, by: -3600)

    let retryDispatcher = RecordingAutoActionDispatcher()
    let recoveredService = try NoteService(driver: driver, autoActionDispatcher: retryDispatcher)

    // First recover reclaims the stale lease and re-dispatches it once.
    _ = try await recoveredService.recoverAndRetryAutoActionDispatches()
    XCTAssertEqual(retryDispatcher.records().count, 1)
    // Second recover finds nothing to reclaim.
    _ = try await recoveredService.recoverAndRetryAutoActionDispatches()
    XCTAssertEqual(retryDispatcher.records().count, 1)

    let attempts = try recoveredService.listAutoActionDispatchAttempts()
    XCTAssertEqual(attempts.first?.status, .dispatched)
    XCTAssertEqual(attempts.first?.attemptCount, 2)

    // The superseded original attempt now completes with a stale lease token.
    delayedDispatcher.completeAll(.succeeded)
    await service.drainAutoActionDispatches()

    // Stale-token completion must not overwrite the reclaimed row's state.
    let final = try recoveredService.listAutoActionDispatchAttempts()
    XCTAssertEqual(final.count, 1)
    XCTAssertEqual(final.first?.status, .dispatched)
    XCTAssertEqual(final.first?.attemptCount, 2)
  }

  func testStaleLeaseCompletionDoesNotMarkReclaimedRowDispatched() async throws {
    // A failing original attempt whose lease has been reclaimed must not flip
    // the now-pending row when it eventually records its outcome.
    let noteRoot = try makeNoteRoot(function: #function)
    let driver = SQLiteNoteDatabaseDriver(noteRoot: noteRoot)
    let delayedDispatcher = DelayedAutoActionDispatcher()
    let service = try NoteService(driver: driver, autoActionDispatcher: delayedDispatcher)
    try enableSeededAutoActions(driver: driver)

    _ = try service.createNote(bodyMarkdown: "# Superseded\nBody")
    await delayedDispatcher.waitForFirstDispatch()
    let dispatchId = try XCTUnwrap(try service.listAutoActionDispatchAttempts(status: .inFlight).first?.dispatchId)
    ageAutoActionLease(driver: driver, dispatchId: dispatchId, by: -3600)

    // Reclaim to pending only (no dispatcher on the recovering service means no
    // new attempt is launched), so the row sits pending.
    let recoveredService = try NoteService(driver: driver)
    XCTAssertEqual(try recoveredService.recoverInterruptedAutoActionDispatches(), 1)
    XCTAssertEqual(try recoveredService.listAutoActionDispatchAttempts(status: .pending).count, 1)

    // The original attempt now completes against its stale lease token.
    delayedDispatcher.completeAll(.succeeded)
    await service.drainAutoActionDispatches()

    let attempts = try recoveredService.listAutoActionDispatchAttempts()
    XCTAssertEqual(attempts.first?.status, .pending)
  }

  func testHeartbeatingAttemptIsNotReclaimedPastStalenessWindow() async throws {
    // A workflow that runs longer than the staleness window keeps its lease
    // fresh through the heartbeat, so a concurrent recovery reclaims nothing and
    // never re-dispatches it. Staleness 0.6s → heartbeat every 0.2s.
    let noteRoot = try makeNoteRoot(function: #function)
    let driver = SQLiteNoteDatabaseDriver(noteRoot: noteRoot)
    let staleness: TimeInterval = 0.6
    let delayedDispatcher = DelayedAutoActionDispatcher()
    let service = try NoteService(
      driver: driver,
      autoActionDispatcher: delayedDispatcher,
      autoActionDispatchLeaseStaleness: staleness
    )
    try enableSeededAutoActions(driver: driver)

    _ = try service.createNote(bodyMarkdown: "# Heartbeat\nBody")
    await delayedDispatcher.waitForFirstDispatch()
    let dispatchId = try XCTUnwrap(try service.listAutoActionDispatchAttempts(status: .inFlight).first?.dispatchId)
    let initialLease = leasedAt(driver: driver, dispatchId: dispatchId)

    // Run well past the staleness window so several heartbeats fire.
    try await Task.sleep(nanoseconds: UInt64(staleness * 3 * 1_000_000_000))

    // The heartbeat has re-stamped the lease, so recovery with the same window
    // finds nothing stale and the row is still the live in-flight attempt.
    let reclaimed = try service.recoverInterruptedAutoActionDispatches(olderThan: staleness)
    XCTAssertEqual(reclaimed, 0)
    XCTAssertEqual(try service.listAutoActionDispatchAttempts(status: .inFlight).count, 1)
    let refreshedLease = leasedAt(driver: driver, dispatchId: dispatchId)
    XCTAssertNotNil(refreshedLease)
    XCTAssertNotEqual(refreshedLease, initialLease, "heartbeat should have re-stamped leased_at")

    delayedDispatcher.completeAll(.succeeded)
    await service.drainAutoActionDispatches()
    XCTAssertEqual(try service.listAutoActionDispatchAttempts().first?.status, .dispatched)
  }

  func testDeadAttemptWithoutHeartbeatIsReclaimed() async throws {
    // A process that died mid-dispatch leaves an in-flight row whose lease is no
    // longer heartbeated. Once it ages past the window, recovery reclaims it.
    let noteRoot = try makeNoteRoot(function: #function)
    let driver = SQLiteNoteDatabaseDriver(noteRoot: noteRoot)
    let delayedDispatcher = DelayedAutoActionDispatcher()
    let service = try NoteService(driver: driver, autoActionDispatcher: delayedDispatcher)
    try enableSeededAutoActions(driver: driver)

    _ = try service.createNote(bodyMarkdown: "# Dead\nBody")
    await delayedDispatcher.waitForFirstDispatch()
    let dispatchId = try XCTUnwrap(try service.listAutoActionDispatchAttempts(status: .inFlight).first?.dispatchId)

    // Simulate a dead attempt: no live heartbeat, lease aged past the window.
    ageAutoActionLease(driver: driver, dispatchId: dispatchId, by: -3600)

    let recoveredService = try NoteService(driver: driver)
    XCTAssertEqual(try recoveredService.recoverInterruptedAutoActionDispatches(), 1)
    XCTAssertEqual(try recoveredService.listAutoActionDispatchAttempts(status: .pending).count, 1)

    delayedDispatcher.completeAll(.succeeded)
    await service.drainAutoActionDispatches()
  }

  func testHeartbeatWithSupersededLeaseTokenUpdatesNothing() async throws {
    // A heartbeat is keyed on the lease token, so an attempt whose lease was
    // reclaimed and re-issued to another attempt cannot refresh the row.
    let noteRoot = try makeNoteRoot(function: #function)
    let driver = SQLiteNoteDatabaseDriver(noteRoot: noteRoot)
    let delayedDispatcher = DelayedAutoActionDispatcher()
    let service = try NoteService(driver: driver, autoActionDispatcher: delayedDispatcher)
    try enableSeededAutoActions(driver: driver)

    _ = try service.createNote(bodyMarkdown: "# Superseded\nBody")
    await delayedDispatcher.waitForFirstDispatch()
    let dispatchId = try XCTUnwrap(try service.listAutoActionDispatchAttempts(status: .inFlight).first?.dispatchId)
    let leaseBefore = leasedAt(driver: driver, dispatchId: dispatchId)

    // Renewing with a token this attempt does not own updates nothing.
    let renewed = try service.renewAutoActionDispatchLease(
      dispatchId: dispatchId,
      leaseToken: "auto-action-lease-not-the-current-token"
    )
    XCTAssertFalse(renewed)
    XCTAssertEqual(leasedAt(driver: driver, dispatchId: dispatchId), leaseBefore)

    delayedDispatcher.completeAll(.succeeded)
    await service.drainAutoActionDispatches()
  }

  func testAutoActionRetryStopsAtMaximumAttempts() async throws {
    let dispatcher = RecordingAutoActionDispatcher(shouldThrow: true)
    let service = try makeService(autoActionDispatcher: dispatcher)

    _ = try service.createNote(bodyMarkdown: "# Exhausted\nBody")
    await service.drainAutoActionDispatches()
    XCTAssertEqual(try service.retryPendingAutoActionDispatches(), 1)
    await service.drainAutoActionDispatches()
    XCTAssertEqual(try service.retryPendingAutoActionDispatches(), 1)
    await service.drainAutoActionDispatches()
    XCTAssertEqual(try service.retryPendingAutoActionDispatches(), 0)

    let attempts = try service.listAutoActionDispatchAttempts(status: .pending)
    XCTAssertEqual(attempts.first?.attemptCount, 3)
    XCTAssertEqual(dispatcher.records().count, 3)
  }

  func testStaleFinalAttemptIsTerminallyReconciledWithoutFourthProviderDispatch() async throws {
    let delayed = DelayedAutoActionDispatcher()
    let service = try makeService(autoActionDispatcher: delayed)
    _ = try service.createNote(bodyMarkdown: "# Final stale\nBody")
    await delayed.waitForFirstDispatch()
    let dispatchId = try XCTUnwrap(try service.listAutoActionDispatchAttempts().first?.dispatchId)
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
    }
    let retry = RecordingAutoActionDispatcher()
    let recovered = try NoteService(driver: service.driver, autoActionDispatcher: retry)
    XCTAssertEqual(try recovered.recoverInterruptedAutoActionDispatches(olderThan: 1), 1)
    XCTAssertEqual(try recovered.retryPendingAutoActionDispatches(), 0)
    await recovered.drainAutoActionDispatches()
    XCTAssertTrue(retry.records().isEmpty)
    let attempt = try XCTUnwrap(try recovered.listAutoActionDispatchAttempts().first)
    XCTAssertEqual(attempt.status, .cancelled)
    XCTAssertEqual(attempt.attemptCount, 3)
    XCTAssertEqual(attempt.lastError, "auto-action dispatch exhausted after stale final lease; provider invocation was not retried")
  }

  func testStaleFinalAttemptReconcilesDurablyAnsweredTurnWithoutFourthProviderInvocation() async throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Durable subject\nBody")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    _ = try service.configureAutoAction(
      actionId: NoteStoreSchema.agentChatReplyActionId,
      trigger: .noteCreated,
      workflowId: NoteStoreSchema.agentChatReplyWorkflowId
    )
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Answer before the worker crashes",
      agentAvailable: true
    )
    _ = try service.completeAgentChatTurn(turnNoteId: turn.noteId, assistantMarkdown: "Durable answer")
    let dispatchId = try XCTUnwrap(
      try service.listAutoActionDispatchAttempts().first(where: {
        $0.record.event.noteId == turn.noteId
          && $0.record.action.workflowId == NoteStoreSchema.agentChatReplyWorkflowId
      })?.dispatchId
    )
    try service.driver.withDatabase { database in
      try database.execute(
        """
        UPDATE auto_action_dispatches
        SET attempt_count = 3, status = ?, lease_token = ?, leased_at = ?
        WHERE dispatch_id = ?
        """,
        bindings: [
          .text(AutoActionDispatchStatus.inFlight.rawValue),
          .text("answered-final-stale-lease"),
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

    let invoker = NeverInvokedAutoActionAgent()
    let dispatcher = KaibaAutoActionDispatcher(
      service: try NoteService(driver: service.driver),
      invoker: invoker
    )
    let recovered = try NoteService(driver: service.driver, autoActionDispatcher: dispatcher)
    XCTAssertEqual(try recovered.recoverInterruptedAutoActionDispatches(olderThan: 1), 1)
    XCTAssertEqual(try recovered.retryPendingAutoActionDispatches(), 1)
    await recovered.drainAutoActionDispatches()

    let invocationCount = await invoker.invocationCount()
    XCTAssertEqual(invocationCount, 0)
    let attempt = try XCTUnwrap(try recovered.listAutoActionDispatchAttempts().first(where: { $0.dispatchId == dispatchId }))
    XCTAssertEqual(attempt.status, .dispatched)
    XCTAssertEqual(attempt.attemptCount, 3)
  }

  func testDeletedDefaultAutoActionDoesNotReappearAfterSchemaPrepare() throws {
    let service = try makeService()

    try service.deleteAutoAction(actionId: AutoActionID("default-ai-tagging-note-created"))
    _ = try makeService()

    XCTAssertFalse(try service.listAutoActions().contains { $0.actionId == AutoActionID("default-ai-tagging-note-created") })
    XCTAssertTrue(try service.listAutoActions().contains { $0.actionId == AutoActionID("default-ai-tagging-note-updated") })
  }

  func testAutoActionNoteTagFilterRestrictsDispatch() async throws {
    let dispatcher = RecordingAutoActionDispatcher()
    let service = try makeService(autoActionDispatcher: dispatcher)
    _ = try service.configureAutoAction(
      actionId: AutoActionID("tag-filtered"),
      trigger: .noteCreated,
      workflowId: WorkflowID("tagged-workflow"),
      filterJSON: #"{"noteTags":["dispatch-me"]}"#,
      position: 10
    )

    _ = try service.createNote(bodyMarkdown: "# Other\nBody")
    _ = try service.createNote(
      bodyMarkdown: "# Tagged\nBody",
      tags: [NoteTagInput(name: "dispatch-me", classId: TagClassID("topic"))]
    )
    await service.drainAutoActionDispatches()

    XCTAssertEqual(
      dispatcher.records().map(\.action.actionId),
      [
        AutoActionID("default-ai-tagging-note-created"),
        AutoActionID("default-ai-tagging-note-created"),
        AutoActionID("tag-filtered")
      ]
    )
  }

  func testAutoActionNotebookKindFilterRestrictsDispatch() async throws {
    let dispatcher = RecordingAutoActionDispatcher()
    let service = try makeService(autoActionDispatcher: dispatcher)
    _ = try service.configureAutoAction(
      actionId: AutoActionID("memo-kind"),
      trigger: .notebookCreated,
      workflowId: WorkflowID("memo-workflow"),
      filterJSON: #"{"notebookKindTag":"notebook-kind:user-memo"}"#
    )

    _ = try service.createNotebook(title: "Plain")
    _ = try service.createNotebook(title: "Memo", kindTagName: "notebook-kind:user-memo")
    await service.drainAutoActionDispatches()

    XCTAssertEqual(dispatcher.records().map(\.action.actionId), [AutoActionID("memo-kind")])
  }

  func testAutoActionNotebookKindFilterUsesNonFolderTagIdentity() async throws {
    let dispatcher = RecordingAutoActionDispatcher()
    let service = try makeService(autoActionDispatcher: dispatcher)
    let kindName = "notebook-kind:shared-display"
    _ = try service.configureAutoAction(
      actionId: AutoActionID("shared-kind"),
      trigger: .notebookCreated,
      workflowId: WorkflowID("shared-kind-workflow"),
      filterJSON: #"{"notebookKindTag":"notebook-kind:shared-display"}"#
    )

    _ = try service.createNotebook(title: "Folder only", folderPath: [kindName])
    _ = try service.createNotebook(title: "Actual kind", kindTagName: kindName)
    await service.drainAutoActionDispatches()

    XCTAssertEqual(dispatcher.records().map(\.action.actionId), [AutoActionID("shared-kind")])
  }

  func testSaveConversationDispatchesNotebookAndNoteCreatedActions() async throws {
    let dispatcher = RecordingAutoActionDispatcher()
    let service = try makeService(autoActionDispatcher: dispatcher)
    _ = try service.configureAutoAction(
      actionId: AutoActionID("conversation-notebook"),
      trigger: .notebookCreated,
      workflowId: WorkflowID("conversation-workflow"),
      filterJSON: #"{"notebookKindTag":"notebook-kind:agent-conversation"}"#,
      position: -1
    )

    let saved = try service.saveConversation(
      title: "Agent Conversation",
      transcript: [
        NoteConversationTurn(userMarkdown: "Hi", assistantMarkdown: "Hello")
      ]
    )
    await service.drainAutoActionDispatches()

    XCTAssertEqual(
      dispatcher.records().map(\.action.actionId),
      [AutoActionID("conversation-notebook"), AutoActionID("default-ai-tagging-note-created")]
    )
    XCTAssertEqual(dispatcher.records().first?.event.notebookId, saved.notebook.notebookId)
    XCTAssertEqual(dispatcher.records().last?.event.noteId, saved.notes.first?.noteId)
    let attempts = try service.listAutoActionDispatchAttempts()
    XCTAssertEqual(attempts.map(\.status), [.dispatched, .dispatched])
  }

  func testAppendConversationTurnDispatchesNoteCreatedAction() async throws {
    let dispatcher = RecordingAutoActionDispatcher()
    let service = try makeService(autoActionDispatcher: dispatcher)
    let saved = try service.saveConversation(
      title: "Agent Conversation",
      transcript: [NoteConversationTurn(userMarkdown: "Hi", assistantMarkdown: "Hello")]
    )
    await service.drainAutoActionDispatches()
    dispatcher.removeAll()

    let appended = try service.appendConversationTurn(
      notebookId: saved.notebook.notebookId,
      turn: NoteConversationTurn(userMarkdown: "Again", assistantMarkdown: "Still here")
    )
    await service.drainAutoActionDispatches()

    XCTAssertEqual(dispatcher.records().map(\.action.actionId), [AutoActionID("default-ai-tagging-note-created")])
    XCTAssertEqual(dispatcher.records().first?.event.noteId, appended.noteId)
  }

  func testConversationWritesSuppressDispatchWhenOriginatingActionIsSet() async throws {
    let dispatcher = RecordingAutoActionDispatcher()
    let service = try makeService(autoActionDispatcher: dispatcher)

    let saved = try service.saveConversation(
      title: "Agent Conversation",
      transcript: [NoteConversationTurn(userMarkdown: "Hi", assistantMarkdown: "Hello")],
      originatingActionId: AutoActionID("workflow-action")
    )
    _ = try service.appendConversationTurn(
      notebookId: saved.notebook.notebookId,
      turn: NoteConversationTurn(userMarkdown: "Again", assistantMarkdown: "Still here"),
      originatingActionId: AutoActionID("workflow-action")
    )
    await service.drainAutoActionDispatches()

    XCTAssertTrue(dispatcher.records().isEmpty)
    XCTAssertTrue(try service.listAutoActionDispatchAttempts().isEmpty)
  }

  func testConfigureAutoActionRejectsMalformedFilterShape() throws {
    let service = try makeService()

    XCTAssertThrowsError(try service.configureAutoAction(
      actionId: AutoActionID("bad-filter"),
      trigger: .noteCreated,
      workflowId: WorkflowID("bad-workflow"),
      filterJSON: #"{"noteTags":"dispatch-me"}"#
    )) { error in
      guard case let NoteServiceError.invalidInput(message) = error else {
        return XCTFail("expected invalid input, got \(error)")
      }
      XCTAssertTrue(message.contains("invalid auto action filter JSON"))
    }
  }

  func testMalformedAutoActionFilterDoesNotSuppressOtherDispatches() async throws {
    let dispatcher = RecordingAutoActionDispatcher()
    let diagnostics = RecordingNoteAutoActionDiagnostics()
    let service = try makeService(autoActionDispatcher: dispatcher, autoActionDiagnosticRecorder: diagnostics)
    try insertMalformedAutoAction(
      service: service,
      actionId: AutoActionID("bad-filter"),
      filterJSON: #"{"noteTags":"dispatch-me"}"#,
      position: -10
    )
    _ = try service.configureAutoAction(
      actionId: AutoActionID("good-filtered"),
      trigger: .noteCreated,
      workflowId: WorkflowID("good-workflow"),
      filterJSON: #"{"noteTags":["dispatch-me"]}"#,
      position: 10
    )

    _ = try service.createNote(
      bodyMarkdown: "# Tagged\nBody",
      tags: [NoteTagInput(name: "dispatch-me", classId: TagClassID("topic"))]
    )
    await service.drainAutoActionDispatches()

    let dispatchedActionIds = dispatcher.records().map(\.action.actionId)
    XCTAssertEqual(dispatchedActionIds.count, 2)
    XCTAssertEqual(
      Set(dispatchedActionIds),
      Set([AutoActionID("default-ai-tagging-note-created"), AutoActionID("good-filtered")])
    )
    XCTAssertEqual(diagnostics.records().map(\.actionId), [AutoActionID("bad-filter")])
    XCTAssertEqual(diagnostics.records().first?.code, .filterEvaluationFailed)
    XCTAssertTrue(diagnostics.records().first?.message.contains("filter_json") == true)
  }
}

private func makeService(
  function: String = #function,
  autoActionDispatcher: AutoActionDispatching? = nil,
  autoActionDiagnosticRecorder: NoteAutoActionFilterDiagnosticRecording? = nil
) throws -> NoteService {
  let service = try NoteService(
    driver: try makeNoteDriver(function: function),
    autoActionDispatcher: autoActionDispatcher,
    autoActionDiagnosticRecorder: autoActionDiagnosticRecorder
  )
  try enableSeededAutoActions(driver: service.driver)
  return service
}

private func insertMalformedAutoAction(
  service: NoteService,
  actionId: AutoActionID,
  filterJSON: String,
  position: Int
) throws {
  try service.driver.withDatabase { database in
    try database.execute(
      """
      INSERT INTO auto_actions (
        action_id, trigger, workflow_id, filter_json, enabled, position, created_at
      ) VALUES (?, ?, ?, jsonb(?), 1, ?, ?)
      """,
      bindings: [
        .id(actionId),
        .text(NoteAutoActionTrigger.noteCreated.rawValue),
        .text("bad-filter-workflow"),
        .text(filterJSON),
        .int(Int64(position)),
        .text("2026-07-04T00:00:00Z")
      ]
    )
  }
}

/// Reads the current `leased_at` timestamp for a dispatch row, if any.
private func leasedAt(driver: NoteDatabaseDriving, dispatchId: AutoActionDispatchID) -> String? {
  let rows = try? driver.withDatabase { database in
    try database.query(
      "SELECT leased_at FROM auto_action_dispatches WHERE dispatch_id = ? LIMIT 1",
      bindings: [.id(dispatchId)]
    )
  }
  return rows?.first?["leased_at"] ?? nil
}

/// Backdates an in-flight lease so recovery treats it as stale.
private func ageAutoActionLease(driver: NoteDatabaseDriving, dispatchId: AutoActionDispatchID, by seconds: TimeInterval) {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  let aged = formatter.string(from: Date().addingTimeInterval(seconds))
  try? driver.withDatabase { database in
    try database.execute(
      "UPDATE auto_action_dispatches SET leased_at = ? WHERE dispatch_id = ?",
      bindings: [.text(aged), .id(dispatchId)]
    )
  }
}

private actor NeverInvokedAutoActionAgent: AgentInvoking {
  private var count = 0

  func invoke(_: AgentInvocationRequest) async throws -> AgentInvocationResult {
    count += 1
    return AgentInvocationResult(markdown: "provider must not be invoked during durable reconciliation")
  }

  func invocationCount() -> Int {
    count
  }
}

private final class RecordingAutoActionDispatcher: AutoActionDispatching, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [AutoActionDispatchRecord] = []
  private var remainingFailures: Int

  init(shouldThrow: Bool = false, failuresBeforeSuccess: Int = 0) {
    remainingFailures = shouldThrow ? Int.max : failuresBeforeSuccess
  }

  func dispatch(_ record: AutoActionDispatchRecord) async throws -> AutoActionDispatchOutcome {
    if recordAndShouldThrow(record) {
      throw NSError(domain: "RecordingAutoActionDispatcher", code: 1)
    }
    return .succeeded
  }

  private func recordAndShouldThrow(_ record: AutoActionDispatchRecord) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(record)
    let shouldThrow = remainingFailures > 0
    if remainingFailures > 0 {
      remainingFailures -= 1
    }
    return shouldThrow
  }

  func records() -> [AutoActionDispatchRecord] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func removeAll() {
    lock.lock()
    recorded.removeAll()
    lock.unlock()
  }
}

/// Holds each dispatch open until `completeAll` releases it, so tests can
/// observe the in-flight lease state before the outcome is recorded.
private final class DelayedAutoActionDispatcher: AutoActionDispatching, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [AutoActionDispatchRecord] = []
  private var gates: [CheckedContinuation<AutoActionDispatchOutcome, Never>] = []
  private var pendingOutcome: AutoActionDispatchOutcome?
  private var dispatchWaiters: [CheckedContinuation<Void, Never>] = []
  private var dispatchCount = 0

  func dispatch(_ record: AutoActionDispatchRecord) async throws -> AutoActionDispatchOutcome {
    let (waiters, resolved) = enterDispatch(record)
    for waiter in waiters {
      waiter.resume()
    }
    if let resolved {
      return resolved
    }
    return await withCheckedContinuation { continuation in
      appendGate(continuation)
    }
  }

  func records() -> [AutoActionDispatchRecord] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  /// Suspends until at least one dispatch has entered `dispatch(_:)`.
  func waitForFirstDispatch() async {
    await withCheckedContinuation { continuation in
      if registerDispatchWaiter(continuation) {
        continuation.resume()
      }
    }
  }

  func completeAll(_ outcome: AutoActionDispatchOutcome) {
    let pending = takeGates(setting: outcome)
    for continuation in pending {
      continuation.resume(returning: outcome)
    }
  }

  private func enterDispatch(
    _ record: AutoActionDispatchRecord
  ) -> (waiters: [CheckedContinuation<Void, Never>], resolved: AutoActionDispatchOutcome?) {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(record)
    dispatchCount += 1
    let waiters = dispatchWaiters
    dispatchWaiters.removeAll()
    return (waiters, pendingOutcome)
  }

  private func appendGate(_ continuation: CheckedContinuation<AutoActionDispatchOutcome, Never>) {
    lock.lock()
    defer { lock.unlock() }
    gates.append(continuation)
  }

  /// Registers a waiter, returning true if a dispatch has already occurred.
  private func registerDispatchWaiter(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if dispatchCount > 0 {
      return true
    }
    dispatchWaiters.append(continuation)
    return false
  }

  private func takeGates(setting outcome: AutoActionDispatchOutcome) -> [CheckedContinuation<AutoActionDispatchOutcome, Never>] {
    lock.lock()
    defer { lock.unlock() }
    let pending = gates
    gates.removeAll()
    pendingOutcome = outcome
    return pending
  }
}

private final class RecordingNoteAutoActionDiagnostics: NoteAutoActionFilterDiagnosticRecording, @unchecked Sendable {
  private let lock = NSLock()
  private var diagnostics: [NoteAutoActionDiagnostic] = []

  func record(_ diagnostic: NoteAutoActionDiagnostic) {
    lock.lock()
    diagnostics.append(diagnostic)
    lock.unlock()
  }

  func records() -> [NoteAutoActionDiagnostic] {
    lock.lock()
    defer { lock.unlock() }
    return diagnostics
  }
}
