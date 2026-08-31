import Foundation

public extension NoteService {
  func listAutoActions() throws -> [AutoAction] {
    try driver.withDatabase { database in
      try database.transaction { db in
        try requireStoreAdministrator(in: db)
        try autoActionListAfterAuthorizationHook?(db)
        return try db.query(
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
  }

  func listAutoActionDispatchAttempts(
    status: AutoActionDispatchStatus? = nil
  ) throws -> [AutoActionDispatchAttempt] {
    try driver.withDatabase { database in
      try database.transaction { db in
        try requireStoreAdministrator(in: db)
        try autoActionListAfterAuthorizationHook?(db)
        let whereClause: String
        let bindings: [SQLiteValue]
        switch status {
        case nil:
          whereClause = ""
          bindings = []
        case .cancelled:
          whereClause = "WHERE cancellation.dispatch_id IS NOT NULL"
          bindings = []
        case let status?:
          whereClause = "WHERE dispatch.status = ? AND cancellation.dispatch_id IS NULL"
          bindings = [.text(status.rawValue)]
        }
        return try db.query(
          """
          SELECT dispatch.dispatch_id, dispatch.action_id, dispatch.action_trigger, dispatch.workflow_id,
            CASE WHEN dispatch.filter_json IS NULL THEN NULL ELSE json(dispatch.filter_json) END AS filter_json,
            dispatch.action_enabled, dispatch.action_position, dispatch.action_created_at,
            CASE WHEN dispatch.event_json IS NULL THEN NULL ELSE json(dispatch.event_json) END AS event_json,
            CASE WHEN cancellation.dispatch_id IS NULL THEN dispatch.status ELSE 'cancelled' END AS status,
            dispatch.attempt_count,
            CASE WHEN cancellation.dispatch_id IS NULL THEN dispatch.last_error ELSE cancellation.reason END AS last_error,
            dispatch.created_at, dispatch.updated_at
          FROM auto_action_dispatches AS dispatch
          LEFT JOIN auto_action_dispatch_cancellations AS cancellation
            ON cancellation.dispatch_id = dispatch.dispatch_id
          \(whereClause)
          ORDER BY dispatch.created_at, dispatch.dispatch_id
          """,
          bindings: bindings
        ).map(autoActionDispatchAttempt(from:))
      }
    }
  }
}
