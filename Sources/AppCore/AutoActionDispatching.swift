import Foundation

private let maximumAutoActionDispatchAttempts = 3

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

private func autoActionDispatchLeaseCutoff(olderThan staleness: TimeInterval) -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter.string(from: Date().addingTimeInterval(-staleness))
}

public struct NoteAutoActionEvent: Codable, Equatable, Sendable {
  public var trigger: NoteAutoActionTrigger
  public var notebookId: String?
  public var noteId: String?
  public var noteBodyMarkdown: String?
  public var originatingActionId: String?

  public init(
    trigger: NoteAutoActionTrigger,
    notebookId: String? = nil,
    noteId: String? = nil,
    noteBodyMarkdown: String? = nil,
    originatingActionId: String? = nil
  ) {
    self.trigger = trigger
    self.notebookId = notebookId
    self.noteId = noteId
    self.noteBodyMarkdown = noteBodyMarkdown
    self.originatingActionId = originatingActionId
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

public enum AutoActionDispatchOutcome: Equatable, Sendable {
  case succeeded
  case failed(String)
}

public enum NoteAutoActionDiagnosticCode: String, Codable, Equatable, Sendable {
  case filterEvaluationFailed = "filter-evaluation-failed"
}

public struct NoteAutoActionDiagnostic: Codable, Equatable, Sendable {
  public var code: NoteAutoActionDiagnosticCode
  public var actionId: String
  public var trigger: NoteAutoActionTrigger
  public var message: String

  public init(
    code: NoteAutoActionDiagnosticCode,
    actionId: String,
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
  var dispatchId: String
  var record: AutoActionDispatchRecord
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
  func listAutoActions() throws -> [AutoAction] {
    try driver.withDatabase { database in
      try database.query(
        """
        SELECT action_id, trigger, workflow_id,
          CASE WHEN filter_json IS NULL THEN NULL ELSE json(filter_json) END AS filter_json,
          enabled, position, created_at
        FROM auto_actions
        ORDER BY trigger, position, action_id
        """
      ).map(autoAction(from:))
    }
  }

  @discardableResult
  func configureAutoAction(
    actionId: String,
    trigger: NoteAutoActionTrigger,
    workflowId: String,
    filterJSON: String? = nil,
    enabled: Bool = true,
    position: Int = 0
  ) throws -> AutoAction {
    try validateAutoActionFilterJSON(filterJSON)
    return try driver.withDatabase { database in
      try database.transaction { db in
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
            .text(actionId),
            .text(trigger.rawValue),
            .text(workflowId),
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

  func deleteAutoAction(actionId: String) throws {
    try driver.withDatabase { database in
      try database.transaction { db in
        _ = try requireAutoAction(actionId: actionId, in: db)
        try db.execute("DELETE FROM auto_actions WHERE action_id = ?", bindings: [.text(actionId)])
      }
    }
  }

  func listAutoActionDispatchAttempts(
    status: AutoActionDispatchStatus? = nil
  ) throws -> [AutoActionDispatchAttempt] {
    try driver.withDatabase { database in
      let whereClause = status == nil ? "" : "WHERE status = ?"
      let bindings = status.map { [SQLiteValue.text($0.rawValue)] } ?? []
      return try database.query(
        """
        SELECT dispatch_id, action_id, action_trigger, workflow_id,
          CASE WHEN filter_json IS NULL THEN NULL ELSE json(filter_json) END AS filter_json,
          action_enabled, action_position, action_created_at,
          CASE WHEN event_json IS NULL THEN NULL ELSE json(event_json) END AS event_json,
          status, attempt_count, last_error, created_at, updated_at
        FROM auto_action_dispatches
        \(whereClause)
        ORDER BY created_at, dispatch_id
        """,
        bindings: bindings
      ).map(autoActionDispatchAttempt(from:))
    }
  }

  @discardableResult
  func retryPendingAutoActionDispatches(limit: Int = 50) throws -> Int {
    guard autoActionDispatcher != nil else {
      return 0
    }
    let queued = try driver.withDatabase { database in
      try database.query(
        """
        SELECT dispatch_id, action_id, action_trigger, workflow_id,
          CASE WHEN filter_json IS NULL THEN NULL ELSE json(filter_json) END AS filter_json,
          action_enabled, action_position, action_created_at,
          CASE WHEN event_json IS NULL THEN NULL ELSE json(event_json) END AS event_json,
          status, attempt_count, last_error, created_at, updated_at
        FROM auto_action_dispatches
        WHERE status = ? AND attempt_count < ?
        ORDER BY created_at, dispatch_id
        LIMIT ?
        """,
        bindings: [
          .text(AutoActionDispatchStatus.pending.rawValue),
          .int(Int64(maximumAutoActionDispatchAttempts)),
          .int(Int64(limit))
        ]
      ).map { try queuedAutoActionDispatch(from: $0) }
    }
    dispatchQueuedAutoActions(queued)
    return queued.count
  }

  /// Reclaims interrupted dispatches whose lease is older than `staleness`,
  /// returning them to `pending` so the retry path can pick them up. Fresh
  /// in-flight rows (a live attempt in another process) are left untouched.
  @discardableResult
  func recoverInterruptedAutoActionDispatches(
    olderThan staleness: TimeInterval = defaultAutoActionDispatchLeaseStaleness
  ) throws -> Int {
    let cutoff = autoActionDispatchLeaseCutoff(olderThan: staleness)
    return try driver.withDatabase { database in
      try database.executeAndReturnChangedRowCount(
        """
        UPDATE auto_action_dispatches
        SET status = ?,
          lease_token = NULL,
          leased_at = NULL,
          last_error = ?,
          updated_at = ?
        WHERE status = ? AND attempt_count < ?
          AND (leased_at IS NULL OR leased_at < ?)
        """,
        bindings: [
          .text(AutoActionDispatchStatus.pending.rawValue),
          .text("auto-action dispatch was interrupted before completion"),
          .text(NoteStoreClock.system.now()),
          .text(AutoActionDispatchStatus.inFlight.rawValue),
          .int(Int64(maximumAutoActionDispatchAttempts)),
          .text(cutoff)
        ]
      )
    }
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
  func enqueueAutoActions(
    for event: NoteAutoActionEvent,
    in database: SQLiteDatabase
  ) throws -> [QueuedAutoActionDispatch] {
    // Pending rows are recorded regardless of whether a dispatcher is wired,
    // so a later `riela note auto-action retry` (or app tick) can run them.
    // Workflow-originated writes are still suppressed to avoid dispatch loops.
    guard event.originatingActionId == nil else {
      return []
    }
    let actions = try matchingAutoActions(for: event, in: database)
    var queued: [QueuedAutoActionDispatch] = []
    for action in actions {
      let dispatchId = makeNoteId(prefix: "auto-action-dispatch")
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
          .text(dispatchId),
          .text(action.actionId),
          .text(action.trigger.rawValue),
          .text(action.workflowId),
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
      let leaseToken: String
      do {
        guard let claimed = try beginAutoActionDispatchAttempt(dispatchId: dispatch.dispatchId) else {
          continue
        }
        leaseToken = claimed
      } catch {
        continue
      }
      let service = self
      let staleness = autoActionDispatchLeaseStaleness
      let task = Task<Void, Never> { [autoActionDispatcher] in
        // Heartbeat the lease for the duration of the attempt so a workflow that
        // runs longer than the staleness window is not reclaimed and re-dispatched
        // concurrently. A heartbeat failure (or a superseded lease) never crashes
        // the attempt; the heartbeat task simply stops updating.
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
              return
            }
          }
        }
        do {
          let outcome = try await autoActionDispatcher.dispatch(dispatch.record)
          switch outcome {
          case .succeeded:
            try? service.markAutoActionDispatchDispatched(
              dispatchId: dispatch.dispatchId,
              leaseToken: leaseToken
            )
          case .failed(let message):
            try? service.recordAutoActionDispatchFailure(
              dispatchId: dispatch.dispatchId,
              leaseToken: leaseToken,
              error: message
            )
          }
        } catch {
          try? service.recordAutoActionDispatchFailure(
            dispatchId: dispatch.dispatchId,
            leaseToken: leaseToken,
            error: "\(error)"
          )
        }
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
  func renewAutoActionDispatchLease(dispatchId: String, leaseToken: String) throws -> Bool {
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
          .text(dispatchId),
          .text(AutoActionDispatchStatus.inFlight.rawValue),
          .text(leaseToken)
        ]
      )
      return changedRows == 1
    }
  }
}

private extension NoteService {
  func matchingAutoActions(for event: NoteAutoActionEvent) throws -> [AutoAction] {
    try driver.withDatabase { database in
      try matchingAutoActions(for: event, in: database)
    }
  }

  func matchingAutoActions(for event: NoteAutoActionEvent, in database: SQLiteDatabase) throws -> [AutoAction] {
    let actions = try database.query(
      """
      SELECT action_id, trigger, workflow_id,
        CASE WHEN filter_json IS NULL THEN NULL ELSE json(filter_json) END AS filter_json,
        enabled, position, created_at
      FROM auto_actions
      WHERE enabled = 1 AND trigger = ?
      ORDER BY position, action_id
      """,
      bindings: [.text(event.trigger.rawValue)]
    ).map(autoAction(from:))
    var matching: [AutoAction] = []
    for action in actions {
      do {
        if try autoAction(action, matches: event, in: database) {
          matching.append(action)
        }
      } catch {
        autoActionDiagnosticRecorder?.record(NoteAutoActionDiagnostic(
          code: .filterEvaluationFailed,
          actionId: action.actionId,
          trigger: action.trigger,
          message: "skipped auto action because filter_json could not be evaluated: \(error)"
        ))
      }
    }
    return matching
  }

  /// Atomically claims a pending row: bumps the attempt count, marks it
  /// in-flight, and stamps a fresh lease token + timestamp. Returns the lease
  /// token when the claim wins (exactly one caller can), or nil otherwise.
  func beginAutoActionDispatchAttempt(dispatchId: String) throws -> String? {
    let leaseToken = makeNoteId(prefix: "auto-action-lease")
    return try driver.withDatabase { database in
      let changedRows = try database.executeAndReturnChangedRowCount(
        """
        UPDATE auto_action_dispatches
        SET attempt_count = attempt_count + 1,
          status = ?,
          lease_token = ?,
          leased_at = ?,
          last_error = NULL,
          updated_at = ?
        WHERE dispatch_id = ? AND status = ? AND attempt_count < ?
        """,
        bindings: [
          .text(AutoActionDispatchStatus.inFlight.rawValue),
          .text(leaseToken),
          .text(NoteStoreClock.system.now()),
          .text(NoteStoreClock.system.now()),
          .text(dispatchId),
          .text(AutoActionDispatchStatus.pending.rawValue),
          .int(Int64(maximumAutoActionDispatchAttempts))
        ]
      )
      return changedRows == 1 ? leaseToken : nil
    }
  }

  func recordAutoActionDispatchFailure(dispatchId: String, leaseToken: String, error: String) throws {
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
          .text(dispatchId),
          .text(AutoActionDispatchStatus.inFlight.rawValue),
          .text(leaseToken)
        ]
      )
    }
  }

  func markAutoActionDispatchDispatched(dispatchId: String, leaseToken: String) throws {
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
          .text(dispatchId),
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

private func autoActionEvent(from json: String) throws -> NoteAutoActionEvent {
  guard let data = json.data(using: .utf8) else {
    throw NoteServiceError.invalidRow("auto action event JSON is not UTF-8")
  }
  return try JSONDecoder().decode(NoteAutoActionEvent.self, from: data)
}

private func queuedAutoActionDispatch(from row: SQLiteRow) throws -> QueuedAutoActionDispatch {
  let attempt = try autoActionDispatchAttempt(from: row)
  return QueuedAutoActionDispatch(dispatchId: attempt.dispatchId, record: attempt.record)
}

private func autoActionDispatchAttempt(from row: SQLiteRow) throws -> AutoActionDispatchAttempt {
  guard let dispatchId = row["dispatch_id"],
        let actionId = row["action_id"],
        let triggerText = row["action_trigger"],
        let trigger = NoteAutoActionTrigger(rawValue: triggerText),
        let workflowId = row["workflow_id"],
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

private struct AutoActionFilter: Decodable {
  var noteTags: [String]?
  var notebookKindTag: String?
}

private func validateAutoActionFilterJSON(_ filterJSON: String?) throws {
  guard let filterJSON else {
    return
  }
  guard let filterData = filterJSON.data(using: .utf8) else {
    throw NoteServiceError.invalidInput("auto action filter JSON must be UTF-8")
  }
  do {
    _ = try JSONDecoder().decode(AutoActionFilter.self, from: filterData)
  } catch {
    throw NoteServiceError.invalidInput("invalid auto action filter JSON: \(error)")
  }
}

private func autoAction(_ action: AutoAction, matches event: NoteAutoActionEvent, in database: SQLiteDatabase) throws -> Bool {
  guard let filterJSON = action.filterJSON else {
    return true
  }
  guard let filterData = filterJSON.data(using: .utf8) else {
    return false
  }
  let filter = try JSONDecoder().decode(AutoActionFilter.self, from: filterData)
  if let requiredNoteTags = filter.noteTags, !requiredNoteTags.isEmpty {
    guard let noteId = event.noteId else {
      return false
    }
    let noteTags = try noteTagNames(noteId: noteId, in: database)
    guard Set(requiredNoteTags).isSubset(of: Set(noteTags)) else {
      return false
    }
  }
  if let notebookKindTag = filter.notebookKindTag {
    guard let notebookId = try eventNotebookId(event, in: database) else {
      return false
    }
    guard let kindTag = try findNonFolderTag(name: notebookKindTag, in: database),
          kindTag.classId == "document-kind",
          try notebookTagAssignment(
            notebookId: notebookId,
            tagId: kindTag.tagId,
            in: database
          ) != nil else {
      return false
    }
  }
  return true
}

private func eventNotebookId(_ event: NoteAutoActionEvent, in database: SQLiteDatabase) throws -> String? {
  if let notebookId = event.notebookId {
    return notebookId
  }
  guard let noteId = event.noteId else {
    return nil
  }
  let rows = try database.query(
    "SELECT notebook_id FROM notes WHERE note_id = ? LIMIT 1",
    bindings: [.text(noteId)]
  )
  return rows.first?["notebook_id"] ?? nil
}

private func noteTagNames(noteId: String, in database: SQLiteDatabase) throws -> [String] {
  try database.query(
    """
    SELECT t.name
    FROM note_tags nt
    INNER JOIN tags t ON t.tag_id = nt.tag_id
    WHERE nt.note_id = ?
    ORDER BY t.name
    """,
    bindings: [.text(noteId)]
  ).compactMap { $0["name"] }
}

func requireAutoAction(actionId: String, in database: SQLiteDatabase) throws -> AutoAction {
  let rows = try database.query(
    """
    SELECT action_id, trigger, workflow_id,
      CASE WHEN filter_json IS NULL THEN NULL ELSE json(filter_json) END AS filter_json,
      enabled, position, created_at
    FROM auto_actions
    WHERE action_id = ?
    LIMIT 1
    """,
    bindings: [.text(actionId)]
  )
  guard let row = rows.first else {
    throw NoteServiceError.notFound("auto action not found: \(actionId)")
  }
  return try autoAction(from: row)
}

private func autoAction(from row: SQLiteRow) throws -> AutoAction {
  guard let actionId = row["action_id"],
        let triggerText = row["trigger"],
        let trigger = NoteAutoActionTrigger(rawValue: triggerText),
        let workflowId = row["workflow_id"],
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
