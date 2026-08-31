import Foundation

let finalAutoActionReconciliationMarker = "reconciling durable terminal workflow state"

/// Handles the final, provider-free replay of work that was durably completed
/// before its last outbox acknowledgement was lost.
protocol FinalAutoActionReconciliationDispatching: LeasedAutoActionDispatching {
  func reconcile(
    _ record: AutoActionDispatchRecord,
    dispatchId: AutoActionDispatchID,
    leaseToken: String
  ) async throws -> AutoActionDispatchOutcome
}

extension NoteService {
  /// Reclaims interrupted leases below the provider retry budget. A stale final
  /// attempt is reconciled from durable workflow state without a fourth
  /// provider invocation, or terminally cancelled when no such state exists.
  @discardableResult
  func recoverInterruptedAutoActionDispatches(
    olderThan staleness: TimeInterval = defaultAutoActionDispatchLeaseStaleness
  ) throws -> Int {
    let cutoff = autoActionDispatchLeaseCutoff(olderThan: staleness)
    return try driver.withDatabase { database in
      try database.transaction { db in
        try requireStoreAdministrator(in: db)
        try autoActionMaintenanceAuthHook?(db)
        let reclaimed = try db.executeAndReturnChangedRowCount(
          """
          UPDATE auto_action_dispatches
          SET status = ?, lease_token = NULL, leased_at = NULL, last_error = ?, updated_at = ?
          WHERE status = ? AND attempt_count < ? AND (leased_at IS NULL OR leased_at < ?)
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
        let exhausted = try db.query(
          """
          SELECT dispatch_id, workflow_id,
            CASE WHEN event_json IS NULL THEN NULL ELSE json(event_json) END AS event_json
          FROM auto_action_dispatches
          WHERE status = ? AND attempt_count >= ? AND (leased_at IS NULL OR leased_at < ?)
          """,
          bindings: [
            .text(AutoActionDispatchStatus.inFlight.rawValue),
            .int(Int64(maximumAutoActionDispatchAttempts)),
            .text(cutoff)
          ]
        )
        let now = NoteStoreClock.system.now()
        let reason = "auto-action dispatch exhausted after stale final lease; provider invocation was not retried"
        for row in exhausted {
          guard let dispatchId = row.identifier("dispatch_id", as: AutoActionDispatchID.self) else {
            throw NoteServiceError.invalidRow("stale auto-action dispatch is missing dispatch_id")
          }
          let eventJSON = row.string("event_json")
          let hasDurableTerminalState: Bool
          if let workflowId = row.identifier("workflow_id", as: WorkflowID.self), !eventJSON.isEmpty {
            do {
              let event = try autoActionEvent(from: eventJSON)
              hasDurableTerminalState = try hasDurableTerminalWorkflowState(
                workflowId: workflowId,
                event: event,
                in: db
              )
            } catch {
              hasDurableTerminalState = false
            }
          } else {
            hasDurableTerminalState = false
          }
          if hasDurableTerminalState {
            // Claim a final non-provider reconciliation attempt. It retains
            // the exhausted attempt count, so a reconciliation failure can be
            // made terminal rather than re-entering the provider retry queue.
            try db.execute(
              """
              UPDATE auto_action_dispatches
              SET status = ?, lease_token = NULL, leased_at = NULL,
                last_error = ?, updated_at = ?
              WHERE dispatch_id = ? AND status = ? AND attempt_count >= ?
              """,
              bindings: [
                .text(AutoActionDispatchStatus.pending.rawValue),
                .text(finalAutoActionReconciliationMarker),
                .text(now), .id(dispatchId), .text(AutoActionDispatchStatus.inFlight.rawValue),
                .int(Int64(maximumAutoActionDispatchAttempts))
              ]
            )
            continue
          }
          try db.execute(
            """
            UPDATE auto_action_dispatches
            SET status = ?, lease_token = NULL, leased_at = NULL, last_error = NULL, updated_at = ?
            WHERE dispatch_id = ? AND status = ? AND attempt_count >= ?
            """,
            bindings: [
              .text(AutoActionDispatchStatus.dispatched.rawValue), .text(now), .id(dispatchId),
              .text(AutoActionDispatchStatus.inFlight.rawValue), .int(Int64(maximumAutoActionDispatchAttempts))
            ]
          )
          try db.execute(
            """
            INSERT INTO auto_action_dispatch_cancellations (dispatch_id, reason, cancelled_at)
            VALUES (?, ?, ?) ON CONFLICT(dispatch_id) DO NOTHING
            """,
            bindings: [.id(dispatchId), .text(reason), .text(now)]
          )
        }
        return reclaimed + exhausted.count
      }
    }
  }

  private func hasDurableTerminalWorkflowState(
    workflowId: WorkflowID,
    event: NoteAutoActionEvent,
    in database: SQLiteDatabase
  ) throws -> Bool {
    switch workflowId {
    case NoteStoreSchema.agentChatReplyWorkflowId:
      guard let turnNoteId = event.noteId else { return false }
      do {
        let turn = try loadNote(turnNoteId, in: database)
        return Self.chatTurnState(of: turn)?.status == .answered
      } catch NoteServiceError.notFound {
        return false
      }
    case NoteStoreSchema.notebookTranslationWorkflowId:
      guard let notebookId = event.notebookId else { return false }
      do {
        let notebook = try loadNotebook(notebookId, in: database)
        return Self.translationState(of: notebook)?.status == .completed
      } catch NoteServiceError.notFound {
        return false
      }
    default:
      return false
    }
  }
}
