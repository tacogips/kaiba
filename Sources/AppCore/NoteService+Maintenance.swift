import Foundation

/// Result of a store integrity audit (`kaiba db check`). `unreferencedFiles`
/// is informational — the storage GC owns reclaiming those and applies a
/// grace window — so it does not affect `isHealthy`.
public struct NoteStoreCheckReport: Equatable, Sendable {
  public var schemaVersion: Int
  /// `PRAGMA quick_check` output; `["ok"]` when the file is sound.
  public var integrityMessages: [String]
  /// One human-readable line per `PRAGMA foreign_key_check` violation.
  public var foreignKeyViolations: [String]
  /// FTS5 'integrity-check' verdict on the search index structure.
  public var searchIndexHealthy: Bool
  /// Notes with no `note_fts_map` row: they silently vanish from search.
  public var notesMissingFromSearchIndex: [NoteID]
  /// `note_fts_map` rows whose note no longer exists.
  public var orphanedSearchIndexRows: Int
  /// `files` rows referenced by no note or notebook (see `storage gc`).
  public var unreferencedFiles: Int
  /// True when this check rebuilt the search index (`repair: true`).
  public var searchIndexRepaired: Bool

  public var isHealthy: Bool {
    integrityMessages == ["ok"]
      && foreignKeyViolations.isEmpty
      && searchIndexHealthy
      && notesMissingFromSearchIndex.isEmpty
      && orphanedSearchIndexRows == 0
  }
}

/// Result of `kaiba db optimize`. Byte figures are `page_count * page_size`,
/// so they track the logical database size the way `VACUUM` changes it.
public struct NoteStoreOptimizationReport: Equatable, Sendable {
  public var vacuumed: Bool
  public var bytesBefore: Int64
  public var bytesAfter: Int64
  public var freelistPagesBefore: Int64
  public var freelistPagesAfter: Int64
}

public extension NoteService {
  /// Audits the store: sqlite `quick_check`, foreign-key integrity, and a
  /// search-index consistency scan (every note indexed, no orphaned index
  /// rows, FTS structure sound). With `repair: true`, any search-index
  /// problem is fixed by rebuilding the index from `notes` — the FTS table
  /// is contentless, so a drifted index cannot be patched row by row.
  /// Store-wide and library-blind, so it is gated like storage GC.
  func checkStore(repair: Bool = false) throws -> NoteStoreCheckReport {
    try requireStoreAdministrator()
    return try driver.withDatabase { database in
      var report = NoteStoreCheckReport(
        schemaVersion: NoteStoreSchema.currentVersion,
        integrityMessages: try quickCheckMessages(in: database),
        foreignKeyViolations: try foreignKeyViolationLines(in: database),
        searchIndexHealthy: searchIndexPassesIntegrityCheck(in: database),
        notesMissingFromSearchIndex: try notesMissingFromSearchIndex(in: database),
        orphanedSearchIndexRows: try orphanedSearchIndexRowCount(in: database),
        unreferencedFiles: try unreferencedFileCount(in: database),
        searchIndexRepaired: false
      )
      let searchIndexDamaged = !report.searchIndexHealthy
        || !report.notesMissingFromSearchIndex.isEmpty
        || report.orphanedSearchIndexRows > 0
      if repair, searchIndexDamaged {
        try database.transaction { db in
          try NoteStoreSchema.rebuildNoteFTS(in: db)
        }
        report.searchIndexRepaired = true
        report.searchIndexHealthy = searchIndexPassesIntegrityCheck(in: database)
        report.notesMissingFromSearchIndex = try notesMissingFromSearchIndex(in: database)
        report.orphanedSearchIndexRows = try orphanedSearchIndexRowCount(in: database)
        // A rebuild also clears foreign-key violations that pointed from
        // orphaned index rows at deleted notes; re-derive rather than guess.
        report.foreignKeyViolations = try foreignKeyViolationLines(in: database)
      }
      return report
    }
  }

  /// Refreshes the query planner's statistics (`ANALYZE` + `PRAGMA
  /// optimize`) and, with `vacuum: true`, compacts the database file.
  func optimizeStore(vacuum: Bool = false) throws -> NoteStoreOptimizationReport {
    try requireStoreAdministrator()
    return try driver.withDatabase { database in
      let bytesBefore = try databaseBytes(in: database)
      let freelistBefore = try pragmaValue("freelist_count", in: database)
      try database.execute("ANALYZE")
      _ = try database.query("PRAGMA optimize")
      if vacuum {
        try database.execute("VACUUM")
      }
      return NoteStoreOptimizationReport(
        vacuumed: vacuum,
        bytesBefore: bytesBefore,
        bytesAfter: try databaseBytes(in: database),
        freelistPagesBefore: freelistBefore,
        freelistPagesAfter: try pragmaValue("freelist_count", in: database)
      )
    }
  }
}

private func quickCheckMessages(in database: SQLiteDatabase) throws -> [String] {
  try database.query("PRAGMA quick_check").compactMap { $0["quick_check"] }
}

private func foreignKeyViolationLines(in database: SQLiteDatabase) throws -> [String] {
  try database.query("PRAGMA foreign_key_check").map { row in
    let table = row["table"] ?? "?"
    let parent = row["parent"] ?? "?"
    let rowid = row["rowid"] ?? "-"
    return "\(table) row \(rowid) references missing \(parent)"
  }
}

private func searchIndexPassesIntegrityCheck(in database: SQLiteDatabase) -> Bool {
  (try? database.execute("INSERT INTO note_fts(note_fts) VALUES('integrity-check')")) != nil
}

private func notesMissingFromSearchIndex(in database: SQLiteDatabase) throws -> [NoteID] {
  try database.query(
    """
    SELECT n.note_id
    FROM notes n
    WHERE NOT EXISTS (SELECT 1 FROM note_fts_map m WHERE m.note_id = n.note_id)
    ORDER BY n.created_at, n.note_id
    """
  ).compactMap { $0.identifier("note_id", as: NoteID.self) }
}

private func orphanedSearchIndexRowCount(in database: SQLiteDatabase) throws -> Int {
  try countQuery(
    """
    SELECT COUNT(*) AS total
    FROM note_fts_map m
    WHERE NOT EXISTS (SELECT 1 FROM notes n WHERE n.note_id = m.note_id)
    """,
    in: database
  )
}

private func unreferencedFileCount(in database: SQLiteDatabase) throws -> Int {
  try countQuery(
    """
    SELECT COUNT(*) AS total
    FROM files f
    WHERE NOT EXISTS (SELECT 1 FROM note_files nf WHERE nf.file_id = f.file_id)
      AND NOT EXISTS (SELECT 1 FROM notebook_files nbf WHERE nbf.file_id = f.file_id)
    """,
    in: database
  )
}

private func countQuery(_ sql: String, in database: SQLiteDatabase) throws -> Int {
  Int(try database.query(sql).first?["total"] ?? "") ?? 0
}

private func databaseBytes(in database: SQLiteDatabase) throws -> Int64 {
  try pragmaValue("page_count", in: database) * pragmaValue("page_size", in: database)
}

private func pragmaValue(_ name: String, in database: SQLiteDatabase) throws -> Int64 {
  Int64(try database.query("PRAGMA \(name)").first?[name] ?? "") ?? 0
}
