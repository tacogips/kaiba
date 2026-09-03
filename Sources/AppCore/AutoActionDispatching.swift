import Foundation

let maximumAutoActionDispatchAttempts = 3

struct AutoActionDispatchLease: Equatable, Sendable {
  let dispatchId: AutoActionDispatchID
  let token: String
}

/// Default window after which an in-flight dispatch lease is treated as stale
/// and eligible to be reclaimed by the recovery path (15 minutes).
public let defaultAutoActionDispatchLeaseStaleness: TimeInterval = 15 * 60

/// Interval at which a running dispatch attempt re-stamps its lease, expressed
/// in nanoseconds. A third of the staleness window keeps the lease comfortably
/// fresh (two heartbeats are lost before reclamation becomes possible). Returns
/// 0 for a non-positive staleness, disabling the heartbeat.
private func autoActionDispatchLeaseHeartbeatIntervalNanos(staleness: TimeInterval) -> UInt64 {
  let interval = staleness / 3
  guard interval > 0 else {
    return 0
  }
  return UInt64(interval * 1_000_000_000)
}

func autoActionDispatchLeaseCutoff(olderThan staleness: TimeInterval) -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter.string(from: Date().addingTimeInterval(-staleness))
}

public struct NoteAutoActionEvent: Codable, Equatable, Sendable {
  public var trigger: NoteAutoActionTrigger
  public var notebookId: NotebookID?
  public var noteId: NoteID?
  public var noteBodyMarkdown: String?
  public var originatingActionId: AutoActionID?
  /// The request principal that caused this work. Dispatchers run later using
  /// their own service value, so they must not silently regain the unscoped
  /// operator view while producing context or a reply for a user request.
  /// `originatingUserId` is nil for the unscoped local operator (the CLI,
  /// internal bootstrap paths). The flag is required, so no event can be
  /// built or stored without saying which kind of principal queued it; a
  /// stored row that lacks it fails to decode and is cancelled in place.
  public var originatingUserId: UserID?
  public var originatingIsUnauthenticatedPrincipal: Bool

  public init(
    trigger: NoteAutoActionTrigger,
    notebookId: NotebookID? = nil,
    noteId: NoteID? = nil,
    noteBodyMarkdown: String? = nil,
    originatingActionId: AutoActionID? = nil,
    originatingUserId: UserID?,
    originatingIsUnauthenticatedPrincipal: Bool
  ) {
    self.trigger = trigger
    self.notebookId = notebookId
    self.noteId = noteId
    self.noteBodyMarkdown = noteBodyMarkdown
    self.originatingActionId = originatingActionId
    self.originatingUserId = originatingUserId
    self.originatingIsUnauthenticatedPrincipal = originatingIsUnauthenticatedPrincipal
  }
}

public struct AutoActionDispatchRecord: Codable, Equatable, Sendable {
  public var action: AutoAction
  public var event: NoteAutoActionEvent

  public init(action: AutoAction, event: NoteAutoActionEvent) {
    self.action = action
    self.event = event
  }
}

public protocol AutoActionDispatching: Sendable {
  /// Runs the workflow for a claimed dispatch. Throwing signals the attempt
  /// could not be launched (e.g. workflow resolution failed); a returned
  /// `.failed` signals the workflow ran but did not succeed. Both leave the
  /// lease reclaimable by the recovery path.
  func dispatch(_ record: AutoActionDispatchRecord) async throws -> AutoActionDispatchOutcome
}

/// A dispatcher that can atomically record a terminal outcome against the
/// outbox row it currently owns. The ordinary protocol remains sufficient for
/// dispatchers that only execute work; this capability is used when a safety
/// cancellation must survive loss of the caller's later acknowledgement.
protocol LeasedAutoActionDispatching: AutoActionDispatching {
  func dispatch(
    _ record: AutoActionDispatchRecord,
    dispatchId: AutoActionDispatchID,
    leaseToken: String
  ) async throws -> AutoActionDispatchOutcome
}

public enum AutoActionDispatchOutcome: Equatable, Sendable {
  case succeeded
  /// Durable work yielded after a bounded chunk. The row returns to pending
  /// without consuming a provider retry attempt; a later maintenance pass
  /// claims the persisted continuation.
  case deferred
  case failed(String)
  /// The work can never safely run, so it must leave the retry queue.
  case cancelled(String)
}

public enum NoteAutoActionDiagnosticCode: String, Codable, Equatable, Sendable {
  case filterEvaluationFailed = "filter-evaluation-failed"
}

public struct NoteAutoActionDiagnostic: Codable, Equatable, Sendable {
  public var code: NoteAutoActionDiagnosticCode
  public var actionId: AutoActionID
  public var trigger: NoteAutoActionTrigger
  public var message: String

  public init(
    code: NoteAutoActionDiagnosticCode,
    actionId: AutoActionID,
    trigger: NoteAutoActionTrigger,
    message: String
  ) {
    self.code = code
    self.actionId = actionId
    self.trigger = trigger
    self.message = message
  }
}

public protocol NoteAutoActionFilterDiagnosticRecording: Sendable {
  func record(_ diagnostic: NoteAutoActionDiagnostic)
}

struct QueuedAutoActionDispatch: Sendable {
  var dispatchId: AutoActionDispatchID
  var record: AutoActionDispatchRecord
  var isFinalReconciliation = false
}

/// Tracks the background tasks spawned by fire-and-record dispatch so that a
/// caller (a CLI command, an app tick) can `await` their completion before
/// exiting. Shared by every copy of a `NoteService` value.
public final class AutoActionDispatchTaskTracker: @unchecked Sendable {
  private let lock = NSLock()
  private var inFlight: [Task<Void, Never>] = []

  public init() {}

  func register(_ task: Task<Void, Never>) {
    lock.lock()
    inFlight.append(task)
    lock.unlock()
  }

  /// Awaits every currently-registered task, then clears the registry.
  /// Tasks registered while draining are awaited on the next pass so a
  /// dispatch that enqueues follow-up work still completes.
  func drain() async {
    while true {
      let pending = takePending()
      if pending.isEmpty {
        return
      }
      for task in pending {
        await task.value
      }
    }
  }

  private func takePending() -> [Task<Void, Never>] {
    lock.lock()
    defer { lock.unlock() }
    let pending = inFlight
    inFlight.removeAll()
    return pending
  }
}

public extension NoteService {
  @discardableResult
  func configureAutoAction(
    actionId: AutoActionID,
    trigger: NoteAutoActionTrigger,
    workflowId: WorkflowID,
    filterJSON: String? = nil,
    enabled: Bool = true,
    position: Int = 0
  ) throws -> AutoAction {
    try validateAutoActionFilterJSON(filterJSON)
    return try driver.withDatabase { database in
      try database.transaction { db in
        try requireStoreAdministrator(in: db)
        try db.execute(
          """
          INSERT INTO auto_actions (
            action_id, trigger, workflow_id, filter_json, enabled, position, created_at
          ) VALUES (?, ?, ?, jsonb(?), ?, ?, ?)
          ON CONFLICT(action_id) DO UPDATE SET
            trigger = excluded.trigger,
            workflow_id = excluded.workflow_id,
            filter_json = excluded.filter_json,
            enabled = excluded.enabled,
            position = excluded.position
          """,
          bindings: [
            .id(actionId),
            .text(trigger.rawValue),
            .id(workflowId),
            .optionalText(filterJSON),
            .int(enabled ? 1 : 0),
            .int(Int64(position)),
            .text(NoteStoreClock.system.now())
          ]
        )
        return try requireAutoAction(actionId: actionId, in: db)
      }
    }
  }

  func deleteAutoAction(actionId: AutoActionID) throws {
    try driver.withDatabase { database in
      try database.transaction { db in
        try requireStoreAdministrator(in: db)
        _ = try requireAutoAction(actionId: actionId, in: db)
        try db.execute("DELETE FROM auto_actions WHERE action_id = ?", bindings: [.id(actionId)])
      }
    }
  }

  @discardableResult
  func retryPendingAutoActionDispatches(limit: Int = 50) throws -> Int {
    let queued: [QueuedAutoActionDispatch] = try driver.withDatabase { database in
      try database.transaction { db in
        try requireStoreAdministrator(in: db)
        try autoActionMaintenanceAuthHook?(db)
        guard autoActionDispatcher != nil else {
          return []
        }
        let rows = try db.query(
          """
          SELECT dispatch_id, action_id, action_trigger, workflow_id,
            CASE WHEN filter_json IS NULL THEN NULL ELSE json(filter_json) END AS filter_json,
            action_enabled, action_position, action_created_at,
            CASE WHEN event_json IS NULL THEN NULL ELSE json(event_json) END AS event_json,
            status, attempt_count, last_error, created_at, updated_at
          FROM auto_action_dispatches
          WHERE status = ?
            AND (
              attempt_count < ?
              OR (attempt_count = ? AND last_error = ?)
            )
          ORDER BY created_at, dispatch_id
          LIMIT ?
          """,
          bindings: [
            .text(AutoActionDispatchStatus.pending.rawValue),
            .int(Int64(maximumAutoActionDispatchAttempts)),
            .int(Int64(maximumAutoActionDispatchAttempts)),
            .text(finalAutoActionReconciliationMarker),
            .int(Int64(limit))
          ]
        )
        var queued: [QueuedAutoActionDispatch] = []
        for row in rows {
          do {
            queued.append(try queuedAutoActionDispatch(from: row))
          } catch {
            try cancelUndecodableAutoActionDispatch(row: row, error: error, in: db)
          }
        }
        return queued
      }
    }
    dispatchQueuedAutoActions(queued)
    return queued.count
  }

  /// Explicit recovery+retry entry point. Reclaims stale leases, dispatches
  /// pending rows, then awaits the fired background tasks so callers (a CLI
  /// command, an app maintenance tick) observe completion before returning.
  @discardableResult
  func recoverAndRetryAutoActionDispatches(
    olderThan staleness: TimeInterval = defaultAutoActionDispatchLeaseStaleness,
    limit: Int = 50
  ) async throws -> Int {
    _ = try recoverInterruptedAutoActionDispatches(olderThan: staleness)
    let count = try retryPendingAutoActionDispatches(limit: limit)
    await drainAutoActionDispatches()
    return count
  }

  /// Awaits every background dispatch task fired by this service value.
  func drainAutoActionDispatches() async {
    await autoActionDispatchTasks.drain()
  }
}

extension NoteService {
  /// Returns a service value whose provider-derived writes are fenced by the
  /// currently claimed outbox lease.  The actual check occurs in each write
  /// transaction, never only when dispatch begins.
  func scoped(toAutoActionDispatch dispatchId: AutoActionDispatchID, leaseToken: String) -> NoteService {
    var copy = self
    copy.activeAutoActionDispatchLease = AutoActionDispatchLease(
      dispatchId: dispatchId,
      token: leaseToken
    )
    return copy
  }

  func activeAgentReplyStreamLease() throws -> AgentReplyStreamLease? {
    guard let activeAutoActionDispatchLease else { return nil }
    return try driver.withDatabase { database in
      let rows = try database.query(
        """
        SELECT attempt_count
        FROM auto_action_dispatches
        WHERE dispatch_id = ? AND status = ? AND lease_token = ?
        LIMIT 1
        """,
        bindings: [
          .id(activeAutoActionDispatchLease.dispatchId),
          .text(AutoActionDispatchStatus.inFlight.rawValue),
          .text(activeAutoActionDispatchLease.token)
        ]
      )
      guard let row = rows.first,
            let attemptNumber = Int(row.string("attempt_count")) else {
        return nil
      }
      return AgentReplyStreamLease(
        dispatchId: activeAutoActionDispatchLease.dispatchId,
        token: activeAutoActionDispatchLease.token,
        attemptNumber: attemptNumber
      )
    }
  }

  /// The last admission boundary before private workflow context leaves this
  /// process. It atomically confirms both the originating account and the
  /// claimed outbox lease still permit a provider call.
  func admitAutoActionProviderInvocation() async throws {
    await providerInvocationPreAdmissionHook?()
    try driver.withDatabase { database in
      try database.transaction { db in
        try requireEnabledActingUser(in: db)
      }
    }
  }

  /// True when this service is executing a claimed outbox attempt.  A missing
  /// database lease for such a service means ownership was lost; it must not
  /// fall back to an unleased side effect.
  var requiresActiveAutoActionDispatchLease: Bool {
    activeAutoActionDispatchLease != nil
  }

  func requireActiveAutoActionDispatchLease(in database: SQLiteDatabase) throws {
    guard let activeAutoActionDispatchLease else { return }
    let rows = try database.query(
      """
      SELECT 1
      FROM auto_action_dispatches
      WHERE dispatch_id = ? AND status = ? AND lease_token = ?
      LIMIT 1
      """,
      bindings: [
        .id(activeAutoActionDispatchLease.dispatchId),
        .text(AutoActionDispatchStatus.inFlight.rawValue),
        .text(activeAutoActionDispatchLease.token)
      ]
    )
    guard !rows.isEmpty else {
      throw NoteServiceError.conflict("auto-action dispatch lease is no longer active")
    }
  }

  func hasActiveAutoActionDispatchLease() -> Bool {
    do {
      return try driver.withDatabase { database in
        try requireActiveAutoActionDispatchLease(in: database)
        return true
      }
    } catch {
      return false
    }
  }

  /// Builds the event for work this service value is about to queue, stamped
  /// with the principal of the request that caused it. Every outbox row is
  /// written through this so a dispatcher can always re-scope to that
  /// principal instead of running as the unscoped operator.
  func makeAutoActionEvent(
    trigger: NoteAutoActionTrigger,
    notebookId: NotebookID? = nil,
    noteId: NoteID? = nil,
    noteBodyMarkdown: String? = nil,
    originatingActionId: AutoActionID? = nil
  ) -> NoteAutoActionEvent {
    NoteAutoActionEvent(
      trigger: trigger,
      notebookId: notebookId,
      noteId: noteId,
      noteBodyMarkdown: noteBodyMarkdown,
      originatingActionId: originatingActionId,
      originatingUserId: actingUserId,
      originatingIsUnauthenticatedPrincipal: isUnauthenticatedPrincipal
    )
  }

  func enqueueAutoActions(
    for event: NoteAutoActionEvent,
    in database: SQLiteDatabase
  ) throws -> [QueuedAutoActionDispatch] {
    // Pending rows are recorded regardless of whether a dispatcher is wired,
    // so a later retry entry point (`kaiba serve` startup recovery or its
    // maintenance tick) can run them.
    // Workflow-originated writes are still suppressed to avoid dispatch loops.
    guard event.originatingActionId == nil else {
      return []
    }
    let actions = try matchingAutoActions(for: event, in: database)
    var queued: [QueuedAutoActionDispatch] = []
    for action in actions {
      let dispatchId = AutoActionDispatchID.generate()
      let now = NoteStoreClock.system.now()
      try database.execute(
        """
        INSERT INTO auto_action_dispatches (
          dispatch_id, action_id, action_trigger, workflow_id, filter_json,
          action_enabled, action_position, action_created_at, event_json,
          status, attempt_count, created_at, updated_at
        ) VALUES (?, ?, ?, ?, jsonb(?), ?, ?, ?, jsonb(?), ?, 0, ?, ?)
        """,
        bindings: [
          .id(dispatchId),
          .id(action.actionId),
          .text(action.trigger.rawValue),
          .id(action.workflowId),
          .optionalText(action.filterJSON),
          .int(action.enabled ? 1 : 0),
          .int(Int64(action.position)),
          .text(action.createdAt),
          .text(try autoActionEventJSON(event)),
          .text(AutoActionDispatchStatus.pending.rawValue),
          .text(now),
          .text(now)
        ]
      )
      queued.append(QueuedAutoActionDispatch(
        dispatchId: dispatchId,
        record: AutoActionDispatchRecord(action: action, event: event)
      ))
    }
    return queued
  }

  /// Fire-and-record: claims each queued row's lease synchronously, then
  /// spawns a background task that runs the async dispatcher and records the
  /// outcome keyed on the claimed lease token. The spawned tasks are tracked
  /// so a caller can drain them before exit; if the process dies first, the
  /// lease + recovery path owns eventual completion.
  func dispatchQueuedAutoActions(_ queued: [QueuedAutoActionDispatch]) {
    guard let autoActionDispatcher else {
      return
    }
    for dispatch in queued {
      let admission = agentExecutionAdmission
      let principalId: String
      if dispatch.record.event.originatingIsUnauthenticatedPrincipal {
        principalId = "unauthenticated:\((dispatch.record.event.originatingUserId ?? NoteStoreSchema.defaultUserId).rawValue)"
      } else if let userId = dispatch.record.event.originatingUserId {
        principalId = "user:\(userId.rawValue)"
      } else {
        // The unscoped local operator (the CLI, internal bootstrap paths).
        principalId = "operator"
      }
      guard let admissionLease = admission.acquire(principalId: principalId) else {
        // Do not claim a durable lease before capacity is available. The row
        // remains pending for the next maintenance/retry pass, avoiding both
        // a task backlog and a provider/process backlog.
        continue
      }
      let leaseToken: String
      do {
        guard let claimed = try beginAutoActionDispatchAttempt(dispatchId: dispatch.dispatchId) else {
          admission.release(admissionLease)
          continue
        }
        leaseToken = claimed
      } catch {
        admission.release(admissionLease)
        continue
      }
      let service = self
      let staleness = autoActionDispatchLeaseStaleness
      let task = Task<Void, Never> { [autoActionDispatcher] in
        defer { admission.release(admissionLease) }
        // Heartbeat the lease for the duration of the attempt so a workflow that
        // runs longer than the staleness window is not reclaimed and re-dispatched
        // concurrently.  Lease loss cancels the execution task as a best-effort
        // provider stop; every later durable write is independently fenced by
        // the lease token in case a provider does not honor cancellation.
        let execution = Task<AutoActionDispatchOutcome, Error> {
          if dispatch.isFinalReconciliation {
            guard let reconciler = autoActionDispatcher as? any FinalAutoActionReconciliationDispatching else {
              return .cancelled("final auto-action reconciliation is unavailable")
            }
            return try await reconciler.reconcile(
              dispatch.record,
              dispatchId: dispatch.dispatchId,
              leaseToken: leaseToken
            )
          }
          if let leasedDispatcher = autoActionDispatcher as? any LeasedAutoActionDispatching {
            return try await leasedDispatcher.dispatch(
              dispatch.record,
              dispatchId: dispatch.dispatchId,
              leaseToken: leaseToken
            )
          }
          return try await autoActionDispatcher.dispatch(dispatch.record)
        }
        let heartbeat = Task<Void, Never> {
          let intervalNanos = autoActionDispatchLeaseHeartbeatIntervalNanos(staleness: staleness)
          guard intervalNanos > 0 else {
            return
          }
          while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: intervalNanos)
            if Task.isCancelled {
              return
            }
            let stillOwned = (try? service.renewAutoActionDispatchLease(
              dispatchId: dispatch.dispatchId,
              leaseToken: leaseToken
            )) ?? false
            if !stillOwned {
              execution.cancel()
              return
            }
          }
        }
        do {
          let outcome = try await execution.value
          switch outcome {
          case .succeeded:
            try? service.markAutoActionDispatchDispatched(
              dispatchId: dispatch.dispatchId,
              leaseToken: leaseToken
            )
          case .deferred:
            try? service.deferAutoActionDispatch(
              dispatchId: dispatch.dispatchId,
              leaseToken: leaseToken
            )
          case .failed(let message):
            if dispatch.isFinalReconciliation {
              try? service.markAutoActionDispatchCancelled(
                dispatchId: dispatch.dispatchId,
                leaseToken: leaseToken,
                reason: "final auto-action reconciliation failed: \(message)"
              )
            } else {
              try? service.recordAutoActionDispatchFailure(
                dispatchId: dispatch.dispatchId,
                leaseToken: leaseToken,
                error: message
              )
            }
          case .cancelled(let message):
            try? service.markAutoActionDispatchCancelled(
              dispatchId: dispatch.dispatchId,
              leaseToken: leaseToken,
              reason: message
            )
          }
        } catch {
          if dispatch.isFinalReconciliation {
            try? service.markAutoActionDispatchCancelled(
              dispatchId: dispatch.dispatchId,
              leaseToken: leaseToken,
              reason: "final auto-action reconciliation failed: \(error)"
            )
          } else {
            try? service.recordAutoActionDispatchFailure(
              dispatchId: dispatch.dispatchId,
              leaseToken: leaseToken,
              error: "\(error)"
            )
          }
        }
        execution.cancel()
        heartbeat.cancel()
        await heartbeat.value
      }
      autoActionDispatchTasks.register(task)
    }
  }

  /// Re-stamps `leased_at` for a still-owned in-flight lease so a long-running
  /// attempt is not reclaimed by the recovery path mid-run. Keyed on the lease
  /// token so a superseded attempt (whose lease was already reclaimed and
  /// re-issued) updates nothing. Returns true when this attempt still owns the
  /// lease and the timestamp was refreshed.
  @discardableResult
  func renewAutoActionDispatchLease(dispatchId: AutoActionDispatchID, leaseToken: String) throws -> Bool {
    try driver.withDatabase { database in
      let changedRows = try database.executeAndReturnChangedRowCount(
        """
        UPDATE auto_action_dispatches
        SET leased_at = ?,
          updated_at = ?
        WHERE dispatch_id = ? AND status = ? AND lease_token = ?
        """,
        bindings: [
          .text(NoteStoreClock.system.now()),
          .text(NoteStoreClock.system.now()),
          .id(dispatchId),
          .text(AutoActionDispatchStatus.inFlight.rawValue),
          .text(leaseToken)
        ]
      )
      return changedRows == 1
    }
  }
}

private extension NoteService {
  /// A pending row whose stored event cannot be decoded (for example one that
  /// lacks the originating principal) can never be dispatched safely. It is
  /// cancelled in place with the decode failure as its reason, so the rest of
  /// the pass proceeds and no dispatcher ever runs it as an unscoped stand-in.
  func cancelUndecodableAutoActionDispatch(
    row: SQLiteRow,
    error: Error,
    in database: SQLiteDatabase
  ) throws {
    guard let dispatchId = row.identifier("dispatch_id", as: AutoActionDispatchID.self) else {
      throw error
    }
    try database.execute(
      """
      UPDATE auto_action_dispatches
      SET status = ?,
        lease_token = NULL,
        leased_at = NULL,
        last_error = ?,
        updated_at = ?
      WHERE dispatch_id = ? AND status = ?
      """,
      bindings: [
        .text(AutoActionDispatchStatus.cancelled.rawValue),
        .text("auto-action dispatch row could not be decoded: \(error)"),
        .text(NoteStoreClock.system.now()),
        .id(dispatchId),
        .text(AutoActionDispatchStatus.pending.rawValue)
      ]
    )
  }

  /// Atomically claims a pending row: bumps the attempt count, marks it
  /// in-flight, and stamps a fresh lease token + timestamp. Returns the lease
  /// token when the claim wins (exactly one caller can), or nil otherwise.
  func beginAutoActionDispatchAttempt(dispatchId: AutoActionDispatchID) throws -> String? {
    let leaseToken = makeOpaqueToken(prefix: "auto-action-lease")
    return try driver.withDatabase { database in
      let changedRows = try database.executeAndReturnChangedRowCount(
        """
        UPDATE auto_action_dispatches
        SET attempt_count = CASE
            WHEN attempt_count < ? THEN attempt_count + 1
            ELSE attempt_count
          END,
          status = ?,
          lease_token = ?,
          leased_at = ?,
          last_error = NULL,
          updated_at = ?
        WHERE dispatch_id = ?
          AND status = ?
          AND (
            attempt_count < ?
            OR (attempt_count = ? AND last_error = ?)
          )
        """,
        bindings: [
          .int(Int64(maximumAutoActionDispatchAttempts)),
          .text(AutoActionDispatchStatus.inFlight.rawValue),
          .text(leaseToken),
          .text(NoteStoreClock.system.now()),
          .text(NoteStoreClock.system.now()),
          .id(dispatchId),
          .text(AutoActionDispatchStatus.pending.rawValue),
          .int(Int64(maximumAutoActionDispatchAttempts)),
          .int(Int64(maximumAutoActionDispatchAttempts)),
          .text(finalAutoActionReconciliationMarker)
        ]
      )
      return changedRows == 1 ? leaseToken : nil
    }
  }

  func recordAutoActionDispatchFailure(dispatchId: AutoActionDispatchID, leaseToken: String, error: String) throws {
    try driver.withDatabase { database in
      try database.execute(
        """
        UPDATE auto_action_dispatches
        SET status = ?,
          lease_token = NULL,
          leased_at = NULL,
          last_error = ?,
          updated_at = ?
        WHERE dispatch_id = ? AND status = ? AND lease_token = ?
        """,
        bindings: [
          .text(AutoActionDispatchStatus.pending.rawValue),
          .text(error),
          .text(NoteStoreClock.system.now()),
          .id(dispatchId),
          .text(AutoActionDispatchStatus.inFlight.rawValue),
          .text(leaseToken)
        ]
      )
    }
  }

  /// Returns a bounded continuation to the durable pending queue without
  /// charging it as a failed provider attempt. The next claim gets a new lease
  /// token; source/output hashes make continuation idempotent across restart.
  func deferAutoActionDispatch(dispatchId: AutoActionDispatchID, leaseToken: String) throws {
    try driver.withDatabase { database in
      try database.execute(
        """
        UPDATE auto_action_dispatches
        SET status = ?,
          attempt_count = CASE WHEN attempt_count > 0 THEN attempt_count - 1 ELSE 0 END,
          lease_token = NULL,
          leased_at = NULL,
          last_error = NULL,
          updated_at = ?
        WHERE dispatch_id = ? AND status = ? AND lease_token = ?
        """,
        bindings: [
          .text(AutoActionDispatchStatus.pending.rawValue),
          .text(NoteStoreClock.system.now()),
          .id(dispatchId),
          .text(AutoActionDispatchStatus.inFlight.rawValue),
          .text(leaseToken)
        ]
      )
    }
  }

  func markAutoActionDispatchDispatched(dispatchId: AutoActionDispatchID, leaseToken: String) throws {
    try driver.withDatabase { database in
      try database.execute(
        """
        UPDATE auto_action_dispatches
        SET status = ?,
          lease_token = NULL,
          leased_at = NULL,
          last_error = NULL,
          updated_at = ?
        WHERE dispatch_id = ? AND status = ? AND lease_token = ?
        """,
        bindings: [
          .text(AutoActionDispatchStatus.dispatched.rawValue),
          .text(NoteStoreClock.system.now()),
          .id(dispatchId),
          .text(AutoActionDispatchStatus.inFlight.rawValue),
          .text(leaseToken)
        ]
      )
    }
  }
}

extension NoteService {
  /// Records a terminal safety stop against the row this attempt still owns.
  /// Keyed on the lease token so a superseded attempt writes nothing. The
  /// reason lands in `last_error`, so readers never mistake a cancellation for
  /// successful provider work.
  func markAutoActionDispatchCancelled(
    dispatchId: AutoActionDispatchID,
    leaseToken: String,
    reason: String
  ) throws {
    try driver.withDatabase { database in
      try database.execute(
        """
        UPDATE auto_action_dispatches
        SET status = ?,
          lease_token = NULL,
          leased_at = NULL,
          last_error = ?,
          updated_at = ?
        WHERE dispatch_id = ? AND status = ? AND lease_token = ?
        """,
        bindings: [
          .text(AutoActionDispatchStatus.cancelled.rawValue),
          .text(reason),
          .text(NoteStoreClock.system.now()),
          .id(dispatchId),
          .text(AutoActionDispatchStatus.inFlight.rawValue),
          .text(leaseToken)
        ]
      )
    }
  }
}

private func autoActionEventJSON(_ event: NoteAutoActionEvent) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let data = try encoder.encode(event)
  guard let json = String(data: data, encoding: .utf8) else {
    throw NoteServiceError.invalidInput("auto action event JSON must be UTF-8")
  }
  return json
}

func autoActionEvent(from json: String) throws -> NoteAutoActionEvent {
  guard let data = json.data(using: .utf8) else {
    throw NoteServiceError.invalidRow("auto action event JSON is not UTF-8")
  }
  return try JSONDecoder().decode(NoteAutoActionEvent.self, from: data)
}

private func queuedAutoActionDispatch(from row: SQLiteRow) throws -> QueuedAutoActionDispatch {
  let attempt = try autoActionDispatchAttempt(from: row)
  return QueuedAutoActionDispatch(
    dispatchId: attempt.dispatchId,
    record: attempt.record,
    isFinalReconciliation: attempt.lastError == finalAutoActionReconciliationMarker
  )
}

func autoActionDispatchAttempt(from row: SQLiteRow) throws -> AutoActionDispatchAttempt {
  guard let dispatchId = row.identifier("dispatch_id", as: AutoActionDispatchID.self),
        let actionId = row.identifier("action_id", as: AutoActionID.self),
        let triggerText = row["action_trigger"],
        let trigger = NoteAutoActionTrigger(rawValue: triggerText),
        let workflowId = row.identifier("workflow_id", as: WorkflowID.self),
        let enabledText = row["action_enabled"],
        let positionText = row["action_position"],
        let position = Int(positionText),
        let actionCreatedAt = row["action_created_at"],
        let eventJSON = row["event_json"],
        let statusText = row["status"],
        let status = AutoActionDispatchStatus(rawValue: statusText),
        let attemptCountText = row["attempt_count"],
        let attemptCount = Int(attemptCountText),
        let createdAt = row["created_at"],
        let updatedAt = row["updated_at"] else {
    throw NoteServiceError.invalidRow("auto action dispatch row is missing required fields")
  }
  let action = AutoAction(
    actionId: actionId,
    trigger: trigger,
    workflowId: workflowId,
    filterJSON: row["filter_json"] ?? nil,
    enabled: enabledText == "1",
    position: position,
    createdAt: actionCreatedAt
  )
  return AutoActionDispatchAttempt(
    dispatchId: dispatchId,
    record: AutoActionDispatchRecord(action: action, event: try autoActionEvent(from: eventJSON)),
    status: status,
    attemptCount: attemptCount,
    lastError: row["last_error"] ?? nil,
    createdAt: createdAt,
    updatedAt: updatedAt
  )
}

func requireAutoAction(actionId: AutoActionID, in database: SQLiteDatabase) throws -> AutoAction {
  let rows = try database.query(
    """
    SELECT action_id, trigger, workflow_id,
      CASE WHEN filter_json IS NULL THEN NULL ELSE json(filter_json) END AS filter_json,
      enabled, position, created_at
    FROM auto_actions
    WHERE action_id = ?
    LIMIT 1
    """,
    bindings: [.id(actionId)]
  )
  guard let row = rows.first else {
    throw NoteServiceError.notFound("auto action not found: \(actionId)")
  }
  return try autoAction(from: row)
}

func autoAction(from row: SQLiteRow) throws -> AutoAction {
  guard let actionId = row.identifier("action_id", as: AutoActionID.self),
        let triggerText = row["trigger"],
        let trigger = NoteAutoActionTrigger(rawValue: triggerText),
        let workflowId = row.identifier("workflow_id", as: WorkflowID.self),
        let positionText = row["position"],
        let position = Int(positionText),
        let createdAt = row["created_at"] else {
    throw NoteServiceError.invalidRow("auto action row is missing required fields")
  }
  return AutoAction(
    actionId: actionId,
    trigger: trigger,
    workflowId: workflowId,
    filterJSON: row["filter_json"] ?? nil,
    enabled: row["enabled"] == "1",
    position: position,
    createdAt: createdAt
  )
}
