import Foundation

let searchEngineSyncSchemaStatements = [
  """
  CREATE TABLE IF NOT EXISTS search_engine_sync_state (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    index_identity TEXT NOT NULL,
    activated_at TEXT NOT NULL
  )
  """,
  """
  CREATE TABLE IF NOT EXISTS search_index_outbox (
    note_id TEXT PRIMARY KEY,
    generation INTEGER NOT NULL DEFAULT 1,
    attempts INTEGER NOT NULL DEFAULT 0,
    next_attempt_at TEXT,
    last_error TEXT,
    claim_token TEXT,
    claimed_until TEXT
  )
  """
]

public struct SearchIndexOutboxRow: Equatable, Sendable {
  public let noteId: NoteID
  public let generation: Int64
  public let attempts: Int

  public init(noteId: NoteID, generation: Int64, attempts: Int) {
    self.noteId = noteId
    self.generation = generation
    self.attempts = attempts
  }
}

public struct SearchIndexOutboxFailure: Equatable, Sendable {
  public let row: SearchIndexOutboxRow
  public let message: String

  public init(row: SearchIndexOutboxRow, message: String) {
    self.row = row
    self.message = message
  }
}

public struct SearchIndexOutboxStatus: Equatable, Sendable {
  public let isActivated: Bool
  public let indexIdentity: String?
  public let pending: Int
  public let failing: Int
  public let due: Int
  public let nextDueAt: String?

  public init(
    isActivated: Bool,
    indexIdentity: String?,
    pending: Int,
    failing: Int,
    due: Int,
    nextDueAt: String?
  ) {
    self.isActivated = isActivated
    self.indexIdentity = indexIdentity
    self.pending = pending
    self.failing = failing
    self.due = due
    self.nextDueAt = nextDueAt
  }
}

/// Enqueues changed notes only after activation, as specified by search adapter design SE3.
func enqueueSearchEngineSync(noteIds: [NoteID], in database: SQLiteDatabase) throws {
  for noteId in noteIds {
    try database.execute(
      """
      INSERT INTO search_index_outbox (note_id)
      SELECT ? WHERE EXISTS (SELECT 1 FROM search_engine_sync_state)
      ON CONFLICT(note_id) DO UPDATE SET generation = generation + 1,
        attempts = 0, next_attempt_at = NULL, last_error = NULL
      """,
      bindings: [.id(noteId)]
    )
  }
}

/// Enqueues every note in a changed notebook only after activation, per search adapter design SE3.
func enqueueSearchEngineSync(notebookId: NotebookID, in database: SQLiteDatabase) throws {
  try database.execute(
    """
    INSERT INTO search_index_outbox (note_id)
    SELECT note_id FROM notes WHERE notebook_id = ?
      AND EXISTS (SELECT 1 FROM search_engine_sync_state)
    ON CONFLICT(note_id) DO UPDATE SET generation = generation + 1,
      attempts = 0, next_attempt_at = NULL, last_error = NULL
    """,
    bindings: [.id(notebookId)]
  )
}

public extension NoteService {
  /// Activates this store and backfills on first activation or identity change, per design SE3.
  @discardableResult
  func activateSearchEngineSync(indexIdentity: String) throws -> Bool {
    try driver.withDatabase { database in
      try database.transaction {
        let existing = try $0.query(
          "SELECT index_identity FROM search_engine_sync_state WHERE id = 1"
        ).first?["index_identity"]
        guard existing != indexIdentity else { return false }
        try $0.execute(
          """
          INSERT INTO search_engine_sync_state (id, index_identity, activated_at)
          VALUES (1, ?, ?)
          ON CONFLICT(id) DO UPDATE SET index_identity = excluded.index_identity,
            activated_at = excluded.activated_at
          """,
          bindings: [.text(indexIdentity), .text(noteStoreTimestamp(from: Date()))]
        )
        try $0.execute(
          """
          INSERT INTO search_index_outbox (note_id)
          SELECT note_id FROM notes WHERE true
          ON CONFLICT(note_id) DO UPDATE SET generation = generation + 1,
            attempts = 0, next_attempt_at = NULL, last_error = NULL
          """
        )
        return true
      }
    }
  }

  /// Requests a full activated-store backfill, per search adapter design SE3.
  @discardableResult
  func enqueueAllNotesForSearchEngineSync() throws -> Int {
    try driver.withDatabase { database in
      try database.transaction {
        let activated = try !$0.query("SELECT 1 FROM search_engine_sync_state WHERE id = 1").isEmpty
        guard activated else { return 0 }
        return try $0.executeAndReturnChangedRowCount(
          """
          INSERT INTO search_index_outbox (note_id)
          SELECT note_id FROM notes WHERE true
            AND EXISTS (SELECT 1 FROM search_engine_sync_state)
          ON CONFLICT(note_id) DO UPDATE SET generation = generation + 1,
            attempts = 0, next_attempt_at = NULL, last_error = NULL
          """
        )
      }
    }
  }

  /// Atomically leases due outbox rows for a worker, per search adapter design SE3.
  func claimSearchIndexOutbox(
    limit: Int,
    claimToken: String,
    now: Date,
    leaseSeconds: TimeInterval = 60
  ) throws -> [SearchIndexOutboxRow] {
    guard limit > 0 else { return [] }
    return try driver.withDatabase { database in
      try database.transaction {
        let nowText = noteStoreTimestamp(from: now)
        let leaseText = noteStoreTimestamp(from: now.addingTimeInterval(leaseSeconds))
        try $0.execute(
          """
          UPDATE search_index_outbox
          SET claim_token = ?, claimed_until = ?
          WHERE note_id IN (
            SELECT note_id FROM search_index_outbox
            WHERE (next_attempt_at IS NULL OR next_attempt_at <= ?)
              AND (claim_token IS NULL OR claimed_until <= ?)
            ORDER BY attempts, note_id LIMIT ?
          )
          """,
          bindings: [.text(claimToken), .text(leaseText), .text(nowText), .text(nowText), .int(Int64(limit))]
        )
        return try $0.query(
          "SELECT note_id, generation, attempts FROM search_index_outbox WHERE claim_token = ? ORDER BY attempts, note_id",
          bindings: [.text(claimToken)]
        ).compactMap { row in
          guard let noteId = row.identifier("note_id", as: NoteID.self),
                let generation = row["generation"].flatMap(Int64.init),
                let attempts = row["attempts"].flatMap(Int.init) else { return nil }
          return SearchIndexOutboxRow(noteId: noteId, generation: generation, attempts: attempts)
        }
      }
    }
  }

  /// Settles leased rows using generation checks and bounded retry backoff, per design SE3.
  func settleSearchIndexOutbox(
    succeeded: [SearchIndexOutboxRow],
    failed: [SearchIndexOutboxFailure],
    claimToken: String,
    now: Date
  ) throws {
    try driver.withDatabase { database in
      try database.transaction { db in
        for row in succeeded {
          let deleted = try db.executeAndReturnChangedRowCount(
            "DELETE FROM search_index_outbox WHERE note_id = ? AND claim_token = ? AND generation = ?",
            bindings: [.id(row.noteId), .text(claimToken), .int(row.generation)]
          )
          if deleted == 0 {
            try db.execute(
              "UPDATE search_index_outbox SET claim_token = NULL, claimed_until = NULL WHERE note_id = ? AND claim_token = ?",
              bindings: [.id(row.noteId), .text(claimToken)]
            )
          }
        }
        for failure in failed {
          let attempts = min(max(failure.row.attempts, 0), 10)
          let seconds = min(5 * (1 << attempts), 3600)
          let nextAttempt = noteStoreTimestamp(from: now.addingTimeInterval(TimeInterval(seconds)))
          try db.execute(
            """
            UPDATE search_index_outbox
            SET claim_token = NULL, claimed_until = NULL, attempts = attempts + 1,
              next_attempt_at = ?, last_error = ?
            WHERE note_id = ? AND claim_token = ?
            """,
            bindings: [
              .text(nextAttempt), .text(String(failure.message.prefix(500))),
              .id(failure.row.noteId), .text(claimToken)
            ]
          )
        }
      }
    }
  }

  /// Reports activation and due work counts, per search adapter design SE3.
  func searchIndexOutboxStatus(now: Date = Date()) throws -> SearchIndexOutboxStatus {
    try driver.withDatabase { database in
      let state = try database.query("SELECT index_identity FROM search_engine_sync_state WHERE id = 1").first
      let counts = try database.query(
        """
        SELECT COUNT(*) AS pending,
          SUM(CASE WHEN attempts > 0 THEN 1 ELSE 0 END) AS failing,
          SUM(CASE WHEN (next_attempt_at IS NULL OR next_attempt_at <= ?)
            AND (claim_token IS NULL OR claimed_until <= ?) THEN 1 ELSE 0 END) AS due,
          MIN(next_attempt_at) AS next_due_at
        FROM search_index_outbox
        """,
        bindings: [.text(noteStoreTimestamp(from: now)), .text(noteStoreTimestamp(from: now))]
      ).first
      return SearchIndexOutboxStatus(
        isActivated: state != nil,
        indexIdentity: state?["index_identity"],
        pending: counts?["pending"].flatMap(Int.init) ?? 0,
        failing: counts?["failing"].flatMap(Int.init) ?? 0,
        due: counts?["due"].flatMap(Int.init) ?? 0,
        nextDueAt: counts?["next_due_at"]
      )
    }
  }
}
