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
        let whereClause = status == nil ? "" : "WHERE status = ?"
        let bindings: [SQLiteValue] = status.map { [.text($0.rawValue)] } ?? []
        return try db.query(
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
  }
}
