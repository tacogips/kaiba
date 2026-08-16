import Foundation

public enum NoteStoreSchemaError: Error, Equatable, Sendable {
  case unsupportedFutureVersion(found: Int, supported: Int)
  case unsupportedLegacyVersion(found: Int, required: Int)
  case systemTagCollision(name: String)
  case migrationInvariant(String)
}

public enum NoteStoreSchema {
  public static let currentVersion = 10
  public static let longTermMemoryNotebookKindTag = "notebook-kind:long-term-memory"
  static let longTermMemoryNotebookKindTagId = stableTagId(for: longTermMemoryNotebookKindTag)
  public static let agentConversationNotebookKindTag = "notebook-kind:agent-conversation"
  static let agentConversationNotebookKindTagId = stableTagId(
    for: agentConversationNotebookKindTag
  )
  public static let importedMaterialNotebookKindTag = "notebook-kind:imported-material"
  public static let translationNotebookKindTag = "notebook-kind:translation"
  /// Per-tag memo/chat notebooks (`design-docs/specs/tag-detail-pane.md`, T4).
  public static let tagMemoNotebookKindTag = "notebook-kind:tag-memo"
  public static let autoTaggingWorkflowId = "note-auto-tagging"
  /// Chat-reply generation workflow routed by `KaibaAutoActionDispatcher`
  /// (`design-docs/specs/ai-agent-integration.md`, AI8).
  public static let agentChatReplyWorkflowId = "note-agent-reply"
  public static let agentChatReplyActionId = "agent-chat-reply"
  /// Notebook translation workflow routed by `KaibaAutoActionDispatcher`
  /// (`design-docs/specs/ai-agent-integration.md`, AI9).
  public static let notebookTranslationWorkflowId = "notebook-translation"

  public static func prepare(on driver: NoteDatabaseDriving) throws {
    try driver.withDatabase { database in
      try prepare(in: database)
    }
  }

  public static func prepare(in database: SQLiteDatabase) throws {
    try NoteSQLiteCapabilityCache.requireAvailable(in: database)
    try database.execute(noteSchemaVersionTableStatement)
    try requireSupportedVersion(in: database)
    let isFirstSchemaCreation = try appliedSchemaVersions(in: database).isEmpty

    try database.transaction { db in
      for statement in schemaStatements {
        try db.execute(statement)
      }
      try createTagIndexes(in: db)
      if isFirstSchemaCreation {
        try recordSchemaVersion(currentVersion, in: db)
      }
      try validateCurrentSchema(in: db)
      try requireForeignKeysEnabled(in: db)
      try requireForeignKeyIntegrity(in: db)
      try ensureNoteFTSUsesTrigram(in: db)
      try seedTagClasses(in: db)
      try seedNotebookKindTags(in: db)
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

  /// Stores are either fresh (created directly at `currentVersion`) or already
  /// at `currentVersion`. Kaiba carries no migrations, so older stores and
  /// stores written by a newer kaiba are both rejected up front.
  private static func requireSupportedVersion(in database: SQLiteDatabase) throws {
    guard let newest = try appliedSchemaVersions(in: database).max() else {
      return
    }
    if newest > currentVersion {
      throw NoteStoreSchemaError.unsupportedFutureVersion(found: newest, supported: currentVersion)
    }
    if newest < currentVersion {
      throw NoteStoreSchemaError.unsupportedLegacyVersion(found: newest, required: currentVersion)
    }
  }

  private static func appliedSchemaVersions(in database: SQLiteDatabase) throws -> Set<Int> {
    let rows = try database.query("SELECT version FROM note_schema_version")
    return Set(rows.compactMap { row in
      row["version"].flatMap(Int.init)
    })
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

  private static func validateCurrentSchema(in database: SQLiteDatabase) throws {
    guard try hasCurrentTagSchema(in: database) else {
      throw NoteStoreSchemaError.migrationInvariant("tag table or indexes are incomplete")
    }
  }

  private static func hasCurrentTagSchema(in database: SQLiteDatabase) throws -> Bool {
    let tableSQL = try database.query(
      "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'tags'"
    ).first?["sql"].map(normalizedSchemaSQL) ?? ""
    let requiredTableFragments = [
      "tag_idtextprimarykey",
      "nametextnotnull",
      "class_idtextreferencestag_classes(class_id)",
      "parent_tag_idtextreferencestags(tag_id)",
      "is_systemintegernotnulldefault0",
      "created_attextnotnull"
    ]
    guard requiredTableFragments.allSatisfy(tableSQL.contains),
          !tableSQL.contains("nametextnotnullunique"),
          !tableSQL.contains("unique(name)") else {
      return false
    }
    return try hasTagIndex(
      "idx_tags_non_folder_name_unique",
      columns: ["name"],
      predicate: "whereclass_idisnullorclass_id<>'folder'",
      in: database
    ) && hasTagIndex(
      "idx_tags_root_folder_name_unique",
      columns: ["name"],
      predicate: "whereclass_id='folder'andparent_tag_idisnull",
      in: database
    ) && hasTagIndex(
      "idx_tags_nested_folder_parent_name_unique",
      columns: ["parent_tag_id", "name"],
      predicate: "whereclass_id='folder'andparent_tag_idisnotnull",
      in: database
    )
  }

  private static func hasTagIndex(
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

  private static func createTagIndexes(in database: SQLiteDatabase) throws {
    for statement in tagIndexStatements {
      try database.execute(statement)
    }
  }

  private static func requireForeignKeysEnabled(in database: SQLiteDatabase) throws {
    guard try database.query("PRAGMA foreign_keys").first?["foreign_keys"] == "1" else {
      throw NoteStoreSchemaError.migrationInvariant("foreign-key enforcement is disabled")
    }
  }

  private static func requireForeignKeyIntegrity(in database: SQLiteDatabase) throws {
    guard try database.query("PRAGMA foreign_key_check").isEmpty else {
      throw NoteStoreSchemaError.migrationInvariant("foreign-key integrity check failed")
    }
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
  CREATE TABLE IF NOT EXISTS tags (
    tag_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    class_id TEXT REFERENCES tag_classes(class_id),
    parent_tag_id TEXT REFERENCES tags(tag_id),
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

private let tagIndexStatements = [
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
