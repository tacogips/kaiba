import Foundation

public enum NoteStoreSchemaError: Error, Equatable, Sendable {
  case unsupportedFutureVersion(found: Int, supported: Int)
  case systemTagCollision(name: String)
  case migrationInvariant(String)
}

enum NoteStoreSchemaV7MigrationCheckpoint: Equatable, Sendable {
  case beforeRebuildCommit
  case afterRebuildCommit
  case beforeForeignKeyRestorationVerification
}

public enum NoteStoreSchema {
  public static let currentVersion = 9
  public static let longTermMemoryNotebookKindTag = "notebook-kind:long-term-memory"
  static let longTermMemoryNotebookKindTagId = stableTagId(for: longTermMemoryNotebookKindTag)
  public static let agentConversationNotebookKindTag = "notebook-kind:agent-conversation"
  static let agentConversationNotebookKindTagId = stableTagId(
    for: agentConversationNotebookKindTag
  )
  public static let importedMaterialNotebookKindTag = "notebook-kind:imported-material"
  public static let translationNotebookKindTag = "notebook-kind:translation"
  public static let autoTaggingWorkflowId = "note-auto-tagging"
  /// Chat-reply generation workflow routed by `KaibaAutoActionDispatcher`
  /// (`design-docs/specs/ai-agent-integration.md`, AI8).
  public static let agentChatReplyWorkflowId = "note-agent-reply"
  public static let agentChatReplyActionId = "agent-chat-reply"
  /// Notebook translation workflow routed by `KaibaAutoActionDispatcher`
  /// (`design-docs/specs/ai-agent-integration.md`, AI9).
  public static let notebookTranslationWorkflowId = "notebook-translation"
  public static let systemKanbanStatusSetId = "kanban-default"

  static func setV7MigrationFaultInjectorForTesting(
    _ injector: (@Sendable (NoteStoreSchemaV7MigrationCheckpoint) throws -> Void)?
  ) {
    NoteStoreSchemaV7MigrationFaultInjector.shared.set(injector)
  }

  public static func prepare(on driver: NoteDatabaseDriving) throws {
    try driver.withDatabase { database in
      try prepare(in: database)
    }
  }

  public static func prepare(in database: SQLiteDatabase) throws {
    try NoteSQLiteCapabilityCache.requireAvailable(in: database)
    try database.execute(noteSchemaVersionTableStatement)
    try rejectUnsupportedFutureVersion(in: database)
    let appliedVersions = try appliedSchemaVersions(in: database)
    let isFirstSchemaCreation = appliedVersions.isEmpty

    // v2-v6 stay in the ordinary foreign-key-enabled transaction. Existing
    // v6 stores require a connection-level phase for v7 because SQLite ignores
    // PRAGMA foreign_keys changes inside a transaction.
    try database.transaction { db in
      for statement in schemaStatements {
        try db.execute(statement)
      }
      try applySchemaMigrations(appliedVersions: appliedVersions, in: db)
      if isFirstSchemaCreation {
        try createV7TagIndexes(in: db)
        try recordSchemaVersion(7, in: db)
      }
    }
    if !isFirstSchemaCreation, !appliedVersions.contains(7) {
      try migrateToV7(in: database)
    }
    try database.transaction { db in
      try validateV7Schema(in: db)
      try requireForeignKeysEnabled(in: db)
      try requireForeignKeyIntegrity(in: db)
      try ensureNoteFTSUsesTrigram(in: db)
      try seedTagClasses(in: db)
      try seedNotebookKindTags(in: db)
      try seedKanbanDefaultStatusSet(in: db)
      if isFirstSchemaCreation {
        try seedAutoActions(in: db)
      }
    }
  }

  public static func seededTagClassIds(in database: SQLiteDatabase) throws -> [String] {
    try database.query("SELECT class_id FROM tag_classes ORDER BY class_id").compactMap { $0["class_id"] }
  }

  private static func seedTagClasses(in database: SQLiteDatabase) throws {
    for seed in systemTagClasses {
      try database.execute(
        """
        INSERT INTO tag_classes (class_id, label, description, is_system, created_at)
        VALUES (?, ?, ?, 1, ?)
        ON CONFLICT(class_id) DO NOTHING
        """,
        bindings: [
          .text(seed.classId),
          .text(seed.label),
          .optionalText(seed.description),
          .text(NoteStoreClock.system.now())
        ]
      )
    }
  }

  private static func seedNotebookKindTags(in database: SQLiteDatabase) throws {
    for tagName in systemNotebookKindTags {
      try database.execute(
        """
        INSERT INTO tags (tag_id, name, class_id, is_system, created_at)
        VALUES (?, ?, 'document-kind', 1, ?)
        ON CONFLICT DO NOTHING
        """,
        bindings: [
          .text(stableTagId(for: tagName)),
          .text(tagName),
          .text(NoteStoreClock.system.now())
        ]
      )
      try validateNotebookKindTagOwnership(tagName, in: database)
    }
  }

  private static func validateNotebookKindTagOwnership(
    _ tagName: String,
    in database: SQLiteDatabase
  ) throws {
    let row = try database.query(
      """
      SELECT tag_id, class_id, is_system
      FROM tags
      WHERE name = ? AND (class_id IS NULL OR class_id <> 'folder')
      """,
      bindings: [.text(tagName)]
    ).first
    guard row?["tag_id"] == stableTagId(for: tagName),
          row?["class_id"] == "document-kind",
          row?["is_system"] == "1" else {
      throw NoteStoreSchemaError.systemTagCollision(name: tagName)
    }
  }

  private static func seedKanbanDefaultStatusSet(in database: SQLiteDatabase) throws {
    let now = NoteStoreClock.system.now()
    try database.execute(
      """
      INSERT INTO kanban_status_sets (set_id, name, is_system, created_at, updated_at)
      VALUES (?, 'default', 1, ?, ?)
      ON CONFLICT(set_id) DO NOTHING
      """,
      bindings: [.text(systemKanbanStatusSetId), .text(now), .text(now)]
    )
    let defaultStatuses: [(name: String, category: String, position: Int)] = [
      ("none", "none", 0),
      ("pending", "pending", 1),
      ("progress", "progress", 2),
      ("review", "review", 3),
      ("done", "done", 4)
    ]
    for status in defaultStatuses {
      try database.execute(
        """
        INSERT INTO kanban_statuses (status_id, set_id, name, category, position, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(status_id) DO NOTHING
        """,
        bindings: [
          .text("\(systemKanbanStatusSetId)-\(status.name)"),
          .text(systemKanbanStatusSetId),
          .text(status.name),
          .text(status.category),
          .int(Int64(status.position)),
          .text(now)
        ]
      )
    }
  }

  // Kaiba ships no workflow dispatcher, so the default AI-tagging actions are
  // seeded disabled; enabling one is an explicit opt-in by whichever external
  // automation drains the dispatch outbox.
  private static func seedAutoActions(in database: SQLiteDatabase) throws {
    for trigger in [NoteAutoActionTrigger.noteCreated, .noteUpdated, .notebookCreated] {
      try database.execute(
        """
        INSERT INTO auto_actions (
          action_id, trigger, workflow_id, filter_json, enabled, position, created_at
        ) VALUES (?, ?, ?, NULL, 0, 0, ?)
        ON CONFLICT(action_id) DO NOTHING
        """,
        bindings: [
          .text("default-ai-tagging-\(trigger.rawValue)"),
          .text(trigger.rawValue),
          .text(autoTaggingWorkflowId),
          .text(NoteStoreClock.system.now())
        ]
      )
    }
  }

  private static func stableTagId(for name: String) -> String {
    name
      .replacingOccurrences(of: ":", with: "-")
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: " ", with: "-")
  }

  private static func rejectUnsupportedFutureVersion(in database: SQLiteDatabase) throws {
    let rows = try database.query("SELECT MAX(version) AS version FROM note_schema_version")
    guard let rawVersion = rows.first?["version"], let version = Int(rawVersion), version > currentVersion else {
      return
    }
    throw NoteStoreSchemaError.unsupportedFutureVersion(found: version, supported: currentVersion)
  }

  private static func appliedSchemaVersions(in database: SQLiteDatabase) throws -> Set<Int> {
    let rows = try database.query("SELECT version FROM note_schema_version")
    return Set(rows.compactMap { row in
      row["version"].flatMap(Int.init)
    })
  }

  private static func applySchemaMigrations(appliedVersions: Set<Int>, in database: SQLiteDatabase) throws {
    let migrationsToApply: [NoteSchemaMigration]
    if appliedVersions.isEmpty {
      migrationsToApply = schemaMigrations
    } else {
      migrationsToApply = schemaMigrations.filter { !appliedVersions.contains($0.version) }
    }
    for migration in migrationsToApply {
      try migration.apply(database)
      try recordSchemaVersion(migration.version, in: database)
    }
    if appliedVersions.isEmpty {
      try recordSchemaVersion(1, in: database)
    }
  }

  private static func recordSchemaVersion(_ version: Int, in database: SQLiteDatabase) throws {
    try database.execute(
      """
      INSERT INTO note_schema_version (version, applied_at)
      VALUES (?, ?)
      ON CONFLICT(version) DO NOTHING
      """,
      bindings: [
        .int(Int64(version)),
        .text(NoteStoreClock.system.now())
      ]
    )
  }

  private static func ensureNoteFTSUsesTrigram(in database: SQLiteDatabase) throws {
    let rows = try database.query(
      "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'note_fts' LIMIT 1"
    )
    let createSQL = rows.first?["sql"] ?? ""
    guard !createSQL.lowercased().contains("tokenize='trigram'") else {
      return
    }
    try database.execute("DROP TABLE IF EXISTS note_fts")
    try database.execute("""
      CREATE VIRTUAL TABLE note_fts USING fts5(
        title, body, tags,
        content='',
        tokenize='trigram'
      )
      """)
    try database.execute("DELETE FROM note_fts_map")
    let noteIds = try database.query("SELECT note_id FROM notes ORDER BY created_at, note_id").compactMap { $0["note_id"] }
    for noteId in noteIds {
      try refreshFTS(noteId: noteId, previous: nil, in: database)
    }
  }

  fileprivate static func migrateToV2(in database: SQLiteDatabase) throws {
    try ensureNoteFTSUsesTrigram(in: database)
  }

  fileprivate static func migrateToV3(in database: SQLiteDatabase) throws {
    let rows = try database.query(
      """
      SELECT sql
      FROM sqlite_master
      WHERE type = 'table' AND name = 'auto_action_dispatches'
      LIMIT 1
      """
    )
    guard let createSQL = rows.first?["sql"],
          !createSQL.contains("'in_flight'") else {
      return
    }
    try database.execute("ALTER TABLE auto_action_dispatches RENAME TO auto_action_dispatches_v2")
    try database.execute(autoActionDispatchesTableStatement)
    try database.execute(
      """
      INSERT INTO auto_action_dispatches (
        dispatch_id, action_id, action_trigger, workflow_id, filter_json,
        action_enabled, action_position, action_created_at, event_json,
        status, attempt_count, last_error, created_at, updated_at
      )
      SELECT dispatch_id, action_id, action_trigger, workflow_id, filter_json,
        action_enabled, action_position, action_created_at, event_json,
        CASE WHEN status = 'in_flight' THEN 'pending' ELSE status END,
        attempt_count, last_error, created_at, updated_at
      FROM auto_action_dispatches_v2
      """
    )
    try database.execute("DROP TABLE auto_action_dispatches_v2")
    try database.execute(autoActionDispatchesStatusIndexStatement)
  }

  fileprivate static func migrateToV4(in database: SQLiteDatabase) throws {
    if try !columnExists("parent_tag_id", in: "tags", database: database) {
      try database.execute(
        "ALTER TABLE tags ADD COLUMN parent_tag_id TEXT REFERENCES tags(tag_id)"
      )
    }
    // Fresh stores no longer carry the legacy CHECK-constrained progress
    // column, so v4's ALTER only applies to stores that predate v4 AND v5;
    // those gain the column here and copy it into `status` in migrateToV5.
    if try !columnExists("status", in: "notebooks", database: database),
       try !columnExists("progress", in: "notebooks", database: database) {
      try database.execute(
        """
        ALTER TABLE notebooks
        ADD COLUMN progress TEXT NOT NULL DEFAULT 'none'
          CHECK (progress IN ('none','progress','done','pending'))
        """
      )
    }
  }

  fileprivate static func migrateToV5(in database: SQLiteDatabase) throws {
    if try !columnExists("status_set_id", in: "tags", database: database) {
      try database.execute(
        "ALTER TABLE tags ADD COLUMN status_set_id TEXT REFERENCES kanban_status_sets(set_id)"
      )
    }
    // The legacy CHECK-constrained `progress` column cannot be dropped or
    // rebuilt away: `notebooks` has incoming FKs (notes, notebook_tags,
    // notebook_files) and the store runs with foreign_keys=ON, where a
    // rename-rebuild rewrites child FK targets and the final drop fails.
    // Instead the un-CHECKed `status` column supersedes it; `progress`
    // stays behind, unread, its DEFAULT satisfying the old CHECK forever.
    if try !columnExists("status", in: "notebooks", database: database) {
      try database.execute(
        "ALTER TABLE notebooks ADD COLUMN status TEXT NOT NULL DEFAULT 'none'"
      )
      try database.execute("UPDATE notebooks SET status = progress")
    }
  }

  fileprivate static func migrateToV6(in database: SQLiteDatabase) throws {
    if try !columnExists("read_only", in: "notebooks", database: database) {
      try database.execute(
        "ALTER TABLE notebooks ADD COLUMN read_only INTEGER NOT NULL DEFAULT 0"
      )
    }
  }

  /// Registers the canonical long-term-memory notebook kind tag on stores that
  /// predate it. Fresh stores reach this migration before `seedTagClasses` has
  /// run, where the `tags.class_id` foreign key would reject the row; they get
  /// the tag from `seedNotebookKindTags` later in `prepare` instead, which also
  /// re-runs for existing stores and makes this insert idempotent.
  fileprivate static func migrateToV8(in database: SQLiteDatabase) throws {
    guard try !database.query(
      "SELECT 1 FROM tag_classes WHERE class_id = 'document-kind' LIMIT 1"
    ).isEmpty else {
      return
    }
    try database.execute(
      """
      INSERT INTO tags (tag_id, name, class_id, is_system, created_at)
      VALUES (?, ?, 'document-kind', 1, ?)
      ON CONFLICT DO NOTHING
      """,
      bindings: [
        .text(longTermMemoryNotebookKindTagId),
        .text(longTermMemoryNotebookKindTag),
        .text(NoteStoreClock.system.now())
      ]
    )
  }

  /// Rebuilds `note_comments` so a memo can anchor to a notebook without a
  /// note (`note_id` becomes nullable, `notebook_id` is added). Existing note
  /// memos are backfilled with their note's notebook so notebook-wide memo
  /// listings cover them without a join. The table has no incoming foreign
  /// keys, so the rename-rebuild is safe with foreign_keys=ON.
  fileprivate static func migrateToV9(in database: SQLiteDatabase) throws {
    guard try !columnExists("notebook_id", in: "note_comments", database: database) else {
      return
    }
    try database.transaction { db in
      try db.execute("ALTER TABLE note_comments RENAME TO note_comments_v8")
      try db.execute(noteCommentsTableStatement)
      try db.execute(
        """
        INSERT INTO note_comments (
          comment_id, note_id, notebook_id, body_markdown, author, created_at
        )
        SELECT c.comment_id, c.note_id, n.notebook_id, c.body_markdown, c.author, c.created_at
        FROM note_comments_v8 c
        LEFT JOIN notes n ON n.note_id = c.note_id
        """
      )
      try db.execute("DROP TABLE note_comments_v8")
    }
  }

  private static func migrateToV7(in database: SQLiteDatabase) throws {
    try requireForeignKeysEnabled(in: database)
    try requireForeignKeyIntegrity(in: database)

    if try isV7TagSchema(in: database) {
      try finalizeV7Marker(in: database)
      return
    }

    let snapshot = try V7IdentitySnapshot.capture(in: database)
    do {
      try database.execute("PRAGMA foreign_keys = OFF")
      try requireForeignKeysDisabled(in: database)
      try database.transaction { db in
        try db.execute(v7ReplacementTagsTableStatement)
        try db.execute(
          """
          INSERT INTO tags_v7 (
            tag_id, name, class_id, parent_tag_id, status_set_id, is_system, created_at
          )
          SELECT tag_id, name, class_id, parent_tag_id, status_set_id, is_system, created_at
          FROM tags
          """
        )
        try db.execute("DROP TABLE tags")
        try db.execute("ALTER TABLE tags_v7 RENAME TO tags")
        try createV7TagIndexes(in: db)
        guard snapshot == (try V7IdentitySnapshot.capture(in: db)) else {
          throw NoteStoreSchemaError.migrationInvariant(
            "schema v7 migration changed tag or assignment identity"
          )
        }
        try requireTagReferenceIntegrity(in: db)
        try requireForeignKeyIntegrity(in: db)
        try NoteStoreSchemaV7MigrationFaultInjector.shared.invoke(.beforeRebuildCommit)
      }
      try NoteStoreSchemaV7MigrationFaultInjector.shared.invoke(.afterRebuildCommit)
      try database.execute("PRAGMA foreign_keys = ON")
      try NoteStoreSchemaV7MigrationFaultInjector.shared.invoke(
        .beforeForeignKeyRestorationVerification
      )
      try requireForeignKeysEnabled(in: database)
      try requireForeignKeyIntegrity(in: database)
      try finalizeV7Marker(in: database)
    } catch {
      do {
        try database.execute("PRAGMA foreign_keys = ON")
        try requireForeignKeysEnabled(in: database)
        try requireForeignKeyIntegrity(in: database)
      } catch let restorationError {
        throw NoteStoreSchemaError.migrationInvariant(
          "schema v7 migration failed and foreign-key restoration could not be verified: \(restorationError)"
        )
      }
      throw error
    }
  }

  private static func finalizeV7Marker(in database: SQLiteDatabase) throws {
    try requireForeignKeysEnabled(in: database)
    try requireForeignKeyIntegrity(in: database)
    try database.transaction { db in
      try validateV7Schema(in: db)
      try requireTagReferenceIntegrity(in: db)
      try recordSchemaVersion(7, in: db)
    }
  }

  private static func validateV7Schema(in database: SQLiteDatabase) throws {
    guard try isV7TagSchema(in: database) else {
      throw NoteStoreSchemaError.migrationInvariant("schema v7 tag table or indexes are incomplete")
    }
  }

  private static func isV7TagSchema(in database: SQLiteDatabase) throws -> Bool {
    let tableSQL = try database.query(
      "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'tags'"
    ).first?["sql"].map(normalizedSchemaSQL) ?? ""
    let requiredTableFragments = [
      "tag_idtextprimarykey",
      "nametextnotnull",
      "class_idtextreferencestag_classes(class_id)",
      "parent_tag_idtextreferencestags(tag_id)",
      "status_set_idtextreferenceskanban_status_sets(set_id)",
      "is_systemintegernotnulldefault0",
      "created_attextnotnull"
    ]
    guard requiredTableFragments.allSatisfy(tableSQL.contains),
          !tableSQL.contains("nametextnotnullunique"),
          !tableSQL.contains("unique(name)") else {
      return false
    }
    return try hasV7TagIndex(
      "idx_tags_non_folder_name_unique",
      columns: ["name"],
      predicate: "whereclass_idisnullorclass_id<>'folder'",
      in: database
    ) && hasV7TagIndex(
      "idx_tags_root_folder_name_unique",
      columns: ["name"],
      predicate: "whereclass_id='folder'andparent_tag_idisnull",
      in: database
    ) && hasV7TagIndex(
      "idx_tags_nested_folder_parent_name_unique",
      columns: ["parent_tag_id", "name"],
      predicate: "whereclass_id='folder'andparent_tag_idisnotnull",
      in: database
    )
  }

  private static func hasV7TagIndex(
    _ name: String,
    columns: [String],
    predicate: String,
    in database: SQLiteDatabase
  ) throws -> Bool {
    guard let index = try database.query("PRAGMA index_list(tags)")
      .first(where: { $0["name"] == name }),
      index["unique"] == "1",
      index["partial"] == "1" else {
      return false
    }
    let actualColumns = try database.query("PRAGMA index_info(\(name))")
      .compactMap { $0["name"] }
    guard actualColumns == columns else {
      return false
    }
    let sql = try database.query(
      "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?",
      bindings: [.text(name)]
    ).first?["sql"].map(normalizedSchemaSQL) ?? ""
    return sql.contains(predicate)
  }

  private static func normalizedSchemaSQL(_ sql: String) -> String {
    sql.lowercased().filter { !$0.isWhitespace }
  }

  private static func createV7TagIndexes(in database: SQLiteDatabase) throws {
    for statement in v7TagIndexStatements {
      try database.execute(statement)
    }
  }

  private static func requireForeignKeysEnabled(in database: SQLiteDatabase) throws {
    guard try database.query("PRAGMA foreign_keys").first?["foreign_keys"] == "1" else {
      throw NoteStoreSchemaError.migrationInvariant("foreign-key enforcement is disabled")
    }
  }

  private static func requireForeignKeysDisabled(in database: SQLiteDatabase) throws {
    guard try database.query("PRAGMA foreign_keys").first?["foreign_keys"] == "0" else {
      throw NoteStoreSchemaError.migrationInvariant("foreign-key enforcement could not be disabled")
    }
  }

  private static func requireForeignKeyIntegrity(in database: SQLiteDatabase) throws {
    guard try database.query("PRAGMA foreign_key_check").isEmpty else {
      throw NoteStoreSchemaError.migrationInvariant("foreign-key integrity check failed")
    }
  }

  private static func requireTagReferenceIntegrity(in database: SQLiteDatabase) throws {
    let orphanQueries = [
      "SELECT 1 FROM tags child LEFT JOIN tags parent ON parent.tag_id = child.parent_tag_id WHERE child.parent_tag_id IS NOT NULL AND parent.tag_id IS NULL LIMIT 1",
      "SELECT 1 FROM tags LEFT JOIN kanban_status_sets sets ON sets.set_id = tags.status_set_id WHERE tags.status_set_id IS NOT NULL AND sets.set_id IS NULL LIMIT 1",
      "SELECT 1 FROM note_tags assignments LEFT JOIN tags ON tags.tag_id = assignments.tag_id WHERE tags.tag_id IS NULL LIMIT 1",
      "SELECT 1 FROM notebook_tags assignments LEFT JOIN tags ON tags.tag_id = assignments.tag_id WHERE tags.tag_id IS NULL LIMIT 1"
    ]
    for query in orphanQueries where try !database.query(query).isEmpty {
      throw NoteStoreSchemaError.migrationInvariant("schema v7 migration produced an orphaned tag reference")
    }
  }

  private static func columnExists(
    _ columnName: String,
    in tableName: String,
    database: SQLiteDatabase
  ) throws -> Bool {
    try database.query("PRAGMA table_info(\(tableName))")
      .contains { $0["name"] == columnName }
  }
}

private final class NoteStoreSchemaV7MigrationFaultInjector: @unchecked Sendable {
  static let shared = NoteStoreSchemaV7MigrationFaultInjector()

  private let lock = NSLock()
  private var injector: (@Sendable (NoteStoreSchemaV7MigrationCheckpoint) throws -> Void)?

  private init() {}

  func set(
    _ injector: (@Sendable (NoteStoreSchemaV7MigrationCheckpoint) throws -> Void)?
  ) {
    lock.lock()
    self.injector = injector
    lock.unlock()
  }

  func invoke(_ checkpoint: NoteStoreSchemaV7MigrationCheckpoint) throws {
    lock.lock()
    let current = injector
    lock.unlock()
    try current?(checkpoint)
  }
}

private struct NoteSchemaMigration: Sendable {
  var version: Int
  var apply: @Sendable (SQLiteDatabase) throws -> Void
}

private let schemaMigrations: [NoteSchemaMigration] = [
  NoteSchemaMigration(version: 2, apply: NoteStoreSchema.migrateToV2),
  NoteSchemaMigration(version: 3, apply: NoteStoreSchema.migrateToV3),
  NoteSchemaMigration(version: 4, apply: NoteStoreSchema.migrateToV4),
  NoteSchemaMigration(version: 5, apply: NoteStoreSchema.migrateToV5),
  NoteSchemaMigration(version: 6, apply: NoteStoreSchema.migrateToV6),
  NoteSchemaMigration(version: 8, apply: NoteStoreSchema.migrateToV8),
  NoteSchemaMigration(version: 9, apply: NoteStoreSchema.migrateToV9)
]

private struct V7IdentitySnapshot: Equatable {
  var tagIds: [String]
  var noteAssignments: [String]
  var notebookAssignments: [String]

  static func capture(in database: SQLiteDatabase) throws -> V7IdentitySnapshot {
    V7IdentitySnapshot(
      tagIds: try database.query("SELECT tag_id FROM tags ORDER BY tag_id").compactMap { $0["tag_id"] },
      noteAssignments: try database.query(
        "SELECT note_id || char(0) || tag_id AS identity FROM note_tags ORDER BY note_id, tag_id"
      ).compactMap { $0["identity"] },
      notebookAssignments: try database.query(
        "SELECT notebook_id || char(0) || tag_id AS identity FROM notebook_tags ORDER BY notebook_id, tag_id"
      ).compactMap { $0["identity"] }
    )
  }
}

final class NoteSQLiteCapabilityCache: @unchecked Sendable {
  private static let shared = NoteSQLiteCapabilityCache()

  private let lock = NSLock()
  private var didVerify = false
  private var probeRunCount = 0

  private init() {}

  static func requireAvailable(in database: SQLiteDatabase) throws {
    try shared.requireAvailable(in: database)
  }

  private func requireAvailable(in database: SQLiteDatabase) throws {
    lock.lock()
    defer {
      lock.unlock()
    }
    guard !didVerify else {
      return
    }

    try database.requireJSONBAvailable()
    try database.requireFTS5Available()
    try database.requireFTS5TrigramAvailable()

    didVerify = true
    probeRunCount += 1
  }

  static func resetForTesting() {
    shared.resetForTesting()
  }

  private func resetForTesting() {
    lock.lock()
    defer {
      lock.unlock()
    }
    didVerify = false
    probeRunCount = 0
  }

  static func probeRunCountForTesting() -> Int {
    shared.probeRunCountForTesting()
  }

  private func probeRunCountForTesting() -> Int {
    lock.lock()
    defer {
      lock.unlock()
    }
    return probeRunCount
  }
}

private struct SystemTagClass {
  var classId: String
  var label: String
  var description: String?
}

private let systemTagClasses: [SystemTagClass] = [
  SystemTagClass(classId: "content-kind", label: "Content Kind", description: "Content-level note kinds"),
  SystemTagClass(classId: "person", label: "Person", description: "People and named actors"),
  SystemTagClass(classId: "year", label: "Year", description: "Years and historical periods"),
  SystemTagClass(classId: "event", label: "Event", description: "Events and milestones"),
  SystemTagClass(classId: "document-kind", label: "Document Kind", description: "Notebook or document kinds"),
  SystemTagClass(classId: "topic", label: "Topic", description: "Conceptual topics"),
  SystemTagClass(classId: "folder", label: "Folder", description: "Notebook organization folders"),
  SystemTagClass(classId: "source", label: "Source", description: "Original source types and references"),
  SystemTagClass(classId: "workflow", label: "Workflow", description: "Workflow-originated processing tags")
]

private let systemNotebookKindTags = [
  "notebook-kind:imported-material",
  NoteStoreSchema.agentConversationNotebookKindTag,
  "notebook-kind:user-memo",
  NoteStoreSchema.longTermMemoryNotebookKindTag,
  NoteStoreSchema.translationNotebookKindTag
]

private let noteSchemaVersionTableStatement = """
  CREATE TABLE IF NOT EXISTS note_schema_version (
    version INTEGER PRIMARY KEY,
    applied_at TEXT NOT NULL
  )
  """

private let schemaStatements = [
  """
  CREATE TABLE IF NOT EXISTS notebooks (
    notebook_id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'none',
    read_only INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    meta_json BLOB CHECK (meta_json IS NULL OR json_valid(meta_json, 8))
  )
  """,
  """
  CREATE TABLE IF NOT EXISTS notes (
    note_id TEXT PRIMARY KEY,
    notebook_id TEXT NOT NULL REFERENCES notebooks(notebook_id),
    note_number INTEGER NOT NULL,
    title TEXT,
    title_source TEXT NOT NULL DEFAULT 'derived' CHECK (title_source IN ('derived','explicit')),
    body_markdown TEXT NOT NULL,
    read_only INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    meta_json BLOB CHECK (meta_json IS NULL OR json_valid(meta_json, 8)),
    UNIQUE (notebook_id, note_number)
  )
  """,
  "CREATE INDEX IF NOT EXISTS idx_notes_notebook ON notes(notebook_id, note_number)",
  "CREATE INDEX IF NOT EXISTS idx_notes_created ON notes(created_at DESC)",
  """
  CREATE TABLE IF NOT EXISTS tag_classes (
    class_id TEXT PRIMARY KEY,
    label TEXT NOT NULL,
    description TEXT,
    is_system INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
  )
  """,
  """
  CREATE TABLE IF NOT EXISTS kanban_status_sets (
    set_id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    is_system INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  )
  """,
  """
  CREATE TABLE IF NOT EXISTS kanban_statuses (
    status_id TEXT PRIMARY KEY,
    set_id TEXT NOT NULL REFERENCES kanban_status_sets(set_id),
    name TEXT NOT NULL,
    category TEXT NOT NULL CHECK (category IN ('none','pending','progress','review','done')),
    position INTEGER NOT NULL,
    created_at TEXT NOT NULL,
    UNIQUE (set_id, name),
    UNIQUE (set_id, position)
  )
  """,
  """
  CREATE TABLE IF NOT EXISTS tags (
    tag_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    class_id TEXT REFERENCES tag_classes(class_id),
    parent_tag_id TEXT REFERENCES tags(tag_id),
    status_set_id TEXT REFERENCES kanban_status_sets(set_id),
    is_system INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
  )
  """,
  """
  CREATE TABLE IF NOT EXISTS note_tags (
    note_id TEXT NOT NULL REFERENCES notes(note_id),
    tag_id TEXT NOT NULL REFERENCES tags(tag_id),
    provenance TEXT NOT NULL CHECK (provenance IN ('human','ai','system')),
    assigned_by TEXT,
    deletable INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL,
    PRIMARY KEY (note_id, tag_id)
  )
  """,
  """
  CREATE TABLE IF NOT EXISTS notebook_tags (
    notebook_id TEXT NOT NULL REFERENCES notebooks(notebook_id),
    tag_id TEXT NOT NULL REFERENCES tags(tag_id),
    provenance TEXT NOT NULL CHECK (provenance IN ('human','ai','system')),
    assigned_by TEXT,
    deletable INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL,
    PRIMARY KEY (notebook_id, tag_id)
  )
  """,
  """
  CREATE TABLE IF NOT EXISTS files (
    file_id TEXT PRIMARY KEY,
    storage_kind TEXT NOT NULL CHECK (storage_kind IN ('local','s3')),
    local_path TEXT,
    s3_profile TEXT,
    s3_bucket TEXT,
    s3_key TEXT,
    media_type TEXT NOT NULL,
    byte_size INTEGER NOT NULL,
    sha256 TEXT NOT NULL,
    original_filename TEXT,
    created_at TEXT NOT NULL,
    migrated_at TEXT,
    CHECK (
      (storage_kind = 'local' AND local_path IS NOT NULL)
      OR (
        storage_kind = 's3'
        AND s3_profile IS NOT NULL
        AND s3_bucket IS NOT NULL
        AND s3_key IS NOT NULL
      )
    )
  )
  """,
  "CREATE INDEX IF NOT EXISTS idx_files_sha ON files(sha256)",
  """
  CREATE TABLE IF NOT EXISTS note_files (
    note_id TEXT NOT NULL REFERENCES notes(note_id),
    file_id TEXT NOT NULL REFERENCES files(file_id),
    role TEXT NOT NULL CHECK (role IN ('embedded','related','source-page-image')),
    position INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (note_id, file_id, role)
  )
  """,
  """
  CREATE TABLE IF NOT EXISTS notebook_files (
    notebook_id TEXT NOT NULL REFERENCES notebooks(notebook_id),
    file_id TEXT NOT NULL REFERENCES files(file_id),
    role TEXT NOT NULL CHECK (role IN ('source-document','related')),
    PRIMARY KEY (notebook_id, file_id, role)
  )
  """,
  """
  CREATE TABLE IF NOT EXISTS note_links (
    from_note_id TEXT NOT NULL REFERENCES notes(note_id),
    to_note_id TEXT NOT NULL REFERENCES notes(note_id),
    link_kind TEXT NOT NULL DEFAULT 'related',
    provenance TEXT NOT NULL CHECK (provenance IN ('human','ai','system')),
    created_at TEXT NOT NULL,
    PRIMARY KEY (from_note_id, to_note_id, link_kind)
  )
  """,
  noteCommentsTableStatement,
  """
  CREATE TABLE IF NOT EXISTS app_settings (
    setting_key TEXT PRIMARY KEY,
    value_json BLOB NOT NULL CHECK (json_valid(value_json, 8)),
    updated_at TEXT NOT NULL
  )
  """,
  """
  CREATE TABLE IF NOT EXISTS auto_actions (
    action_id TEXT PRIMARY KEY,
    trigger TEXT NOT NULL CHECK (trigger IN ('note-created','note-updated','notebook-created')),
    workflow_id TEXT NOT NULL,
    filter_json BLOB CHECK (filter_json IS NULL OR json_valid(filter_json, 8)),
    enabled INTEGER NOT NULL DEFAULT 1,
    position INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
  )
  """,
  autoActionDispatchesTableStatement,
  autoActionDispatchesStatusIndexStatement,
  """
  CREATE TABLE IF NOT EXISTS api_clients (
    client_id TEXT PRIMARY KEY,
    display_name TEXT NOT NULL,
    token_hash TEXT NOT NULL,
    created_at TEXT NOT NULL,
    last_seen_at TEXT,
    revoked_at TEXT
  )
  """,
  """
  CREATE VIRTUAL TABLE IF NOT EXISTS note_fts USING fts5(
    title, body, tags,
    content='',
    tokenize='trigram'
  )
  """,
  """
  CREATE TABLE IF NOT EXISTS note_fts_map (
    fts_rowid INTEGER PRIMARY KEY,
    note_id TEXT NOT NULL UNIQUE
  )
  """
]

private let v7ReplacementTagsTableStatement = """
  CREATE TABLE tags_v7 (
    tag_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    class_id TEXT REFERENCES tag_classes(class_id),
    parent_tag_id TEXT REFERENCES tags(tag_id),
    status_set_id TEXT REFERENCES kanban_status_sets(set_id),
    is_system INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
  )
  """

private let v7TagIndexNames = [
  "idx_tags_non_folder_name_unique",
  "idx_tags_root_folder_name_unique",
  "idx_tags_nested_folder_parent_name_unique"
]

private let v7TagIndexStatements = [
  "CREATE UNIQUE INDEX IF NOT EXISTS idx_tags_non_folder_name_unique ON tags(name) WHERE class_id IS NULL OR class_id <> 'folder'",
  "CREATE UNIQUE INDEX IF NOT EXISTS idx_tags_root_folder_name_unique ON tags(name) WHERE class_id = 'folder' AND parent_tag_id IS NULL",
  "CREATE UNIQUE INDEX IF NOT EXISTS idx_tags_nested_folder_parent_name_unique ON tags(parent_tag_id, name) WHERE class_id = 'folder' AND parent_tag_id IS NOT NULL"
]

/// Memos attach to a note, to a whole notebook, or both (a note memo also
/// records its notebook so notebook-wide memo listings need no join). At least
/// one anchor must be present.
let noteCommentsTableStatement = """
  CREATE TABLE IF NOT EXISTS note_comments (
    comment_id TEXT PRIMARY KEY,
    note_id TEXT REFERENCES notes(note_id),
    notebook_id TEXT REFERENCES notebooks(notebook_id),
    body_markdown TEXT NOT NULL,
    author TEXT NOT NULL,
    created_at TEXT NOT NULL,
    CHECK (note_id IS NOT NULL OR notebook_id IS NOT NULL)
  )
  """

private let autoActionDispatchesTableStatement = """
  CREATE TABLE IF NOT EXISTS auto_action_dispatches (
    dispatch_id TEXT PRIMARY KEY,
    action_id TEXT NOT NULL,
    action_trigger TEXT NOT NULL CHECK (action_trigger IN ('note-created','note-updated','notebook-created')),
    workflow_id TEXT NOT NULL,
    filter_json BLOB CHECK (filter_json IS NULL OR json_valid(filter_json, 8)),
    action_enabled INTEGER NOT NULL,
    action_position INTEGER NOT NULL,
    action_created_at TEXT NOT NULL,
    event_json BLOB NOT NULL CHECK (json_valid(event_json, 8)),
    status TEXT NOT NULL CHECK (status IN ('pending','in_flight','dispatched')),
    attempt_count INTEGER NOT NULL DEFAULT 0,
    lease_token TEXT,
    leased_at TEXT,
    last_error TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  )
  """

private let autoActionDispatchesStatusIndexStatement =
  "CREATE INDEX IF NOT EXISTS idx_auto_action_dispatches_status ON auto_action_dispatches(status, created_at)"

struct NoteStoreClock: Sendable {
  var now: @Sendable () -> String

  static let system = NoteStoreClock {
    noteStoreTimestampFormatter.string(from: Date())
  }
}

private let noteStoreTimestampFormatter = NoteStoreTimestampFormatter()

private final class NoteStoreTimestampFormatter: @unchecked Sendable {
  private let formatter: ISO8601DateFormatter
  private let lock = NSLock()

  init() {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    self.formatter = formatter
  }

  func string(from date: Date) -> String {
    lock.lock()
    defer {
      lock.unlock()
    }
    return formatter.string(from: date)
  }
}
