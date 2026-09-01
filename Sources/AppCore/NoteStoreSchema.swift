import Foundation

public enum NoteStoreSchemaError: Error, Equatable, Sendable {
  case unsupportedFutureVersion(found: Int, supported: Int)
  case unsupportedLegacyVersion(found: Int, required: Int)
  case systemTagCollision(name: String)
  case migrationInvariant(String)
}

public enum NoteStoreSchema {
  public static let currentVersion = 17
  /// The account every unauthenticated request acts as. A stable literal, so
  /// each process agrees on it without a lookup by flag.
  public static let defaultUserId = UserID("user-default")
  public static let defaultUserDisplayName = "Default User"
  /// The library a notebook lands in when no other one is selected. A stable
  /// literal for the same reason the default user is one, and named by the
  /// `notebooks.library_id` column default (`design-docs/specs/library.md`).
  public static let defaultLibraryId = LibraryID("library-default")
  public static let defaultLibraryName = "default"
  public static let defaultLibraryTitle = "Default Library"
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
  public static let autoTaggingWorkflowId = WorkflowID("note-auto-tagging")
  /// Chat-reply generation workflow routed by `KaibaAutoActionDispatcher`
  /// (`design-docs/specs/ai-agent-integration.md`, AI8).
  public static let agentChatReplyWorkflowId = WorkflowID("note-agent-reply")
  public static let agentChatReplyActionId = AutoActionID("agent-chat-reply")
  /// Notebook translation workflow routed by `KaibaAutoActionDispatcher`
  /// (`design-docs/specs/ai-agent-integration.md`, AI9).
  public static let notebookTranslationWorkflowId = WorkflowID("notebook-translation")

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
      try seedDefaultUser(in: db)
      try seedDefaultLibrary(in: db)
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

  public static func seededTagClassIds(in database: SQLiteDatabase) throws -> [TagClassID] {
    try database.query("SELECT class_id FROM tag_classes ORDER BY class_id").compactMap { $0.identifier("class_id", as: TagClassID.self) }
  }

  /// Creates the default account the first time the store is prepared. Every
  /// notebook needs a real owner, and an unauthenticated host has no other
  /// principal to attribute writes to. Idempotent, so a store that already has
  /// it is left untouched.
  private static func seedDefaultUser(in database: SQLiteDatabase) throws {
    try database.execute(
      """
      INSERT INTO users (
        user_id, email, display_name, is_default, is_admin, created_at, disabled_at
      ) VALUES (?, NULL, ?, 1, 1, ?, NULL)
      ON CONFLICT(user_id) DO NOTHING
      """,
      bindings: [
        .id(defaultUserId),
        .text(defaultUserDisplayName),
        .text(NoteStoreClock.system.now())
      ]
    )
  }

  /// Creates the default library the first time the store is prepared. It is
  /// seeded unauthenticated so a store keeps answering an unscoped caller
  /// exactly as it did before libraries existed; requiring authentication is
  /// something an operator opts into per library
  /// (`design-docs/specs/library.md`). Runs after the default user, which it
  /// records as the creator. Idempotent.
  private static func seedDefaultLibrary(in database: SQLiteDatabase) throws {
    try database.execute(
      """
      INSERT INTO libraries (
        library_id, name, title, auth_required, is_default, created_at, created_by
      ) VALUES (?, ?, ?, 0, 1, ?, ?)
      ON CONFLICT(library_id) DO NOTHING
      """,
      bindings: [
        .id(defaultLibraryId),
        .text(defaultLibraryName),
        .text(defaultLibraryTitle),
        .text(NoteStoreClock.system.now()),
        .id(defaultUserId)
      ]
    )
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
          .id(seed.classId),
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
          .id(stableTagId(for: tagName)),
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
    guard row?.identifier("tag_id", as: TagID.self) == stableTagId(for: tagName),
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
          .id(AutoActionID("default-ai-tagging-\(trigger.rawValue)")),
          .text(trigger.rawValue),
          .id(autoTaggingWorkflowId),
          .text(NoteStoreClock.system.now())
        ]
      )
    }
  }

  private static func stableTagId(for name: String) -> TagID {
    TagID(
      name
        .replacingOccurrences(of: ":", with: "-")
        .replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: " ", with: "-")
    )
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
    try rebuildNoteFTS(in: database)
  }

  /// Drops and re-derives the whole search index from `notes`. The FTS table
  /// is contentless, so a drifted index cannot be patched row by row — the
  /// stale entries carry no recoverable payload for the 'delete' command —
  /// and a full rebuild is the one repair that is always correct. Shared by
  /// the tokenizer upgrade above and `NoteService.checkStore(repair:)`.
  static func rebuildNoteFTS(in database: SQLiteDatabase) throws {
    try database.execute("DROP TABLE IF EXISTS note_fts")
    try database.execute("""
      CREATE VIRTUAL TABLE note_fts USING fts5(
        title, body, tags,
        content='',
        tokenize='trigram'
      )
      """)
    try database.execute("DELETE FROM note_fts_map")
    let noteIds = try database.query("SELECT note_id FROM notes ORDER BY created_at, note_id").compactMap { $0.identifier("note_id", as: NoteID.self) }
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
  var classId: TagClassID
  var label: String
  var description: String?
}

private let systemTagClasses: [SystemTagClass] = [
  SystemTagClass(classId: .contentKind, label: "Content Kind", description: "Content-level note kinds"),
  SystemTagClass(classId: .person, label: "Person", description: "People and named actors"),
  SystemTagClass(classId: .year, label: "Year", description: "Years and historical periods"),
  SystemTagClass(classId: .event, label: "Event", description: "Events and milestones"),
  SystemTagClass(classId: .documentKind, label: "Document Kind", description: "Notebook or document kinds"),
  SystemTagClass(classId: .topic, label: "Topic", description: "Conceptual topics"),
  SystemTagClass(classId: .folder, label: "Folder", description: "Notebook organization folders"),
  SystemTagClass(classId: .source, label: "Source", description: "Original source types and references"),
  SystemTagClass(classId: .workflow, label: "Workflow", description: "Workflow-originated processing tags")
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
  ) STRICT
  """

private let schemaStatements = [
  // Users precede notebooks: the ownership foreign key needs the table to
  // exist, and every notebook has a real owner rather than a null "everyone".
  // SQLite treats NULLs as distinct in UNIQUE constraints, so a plain UNIQUE
  // on email already allows any number of email-less accounts.
  """
  CREATE TABLE IF NOT EXISTS users (
    user_id TEXT PRIMARY KEY,
    email TEXT UNIQUE,
    display_name TEXT NOT NULL,
    is_default INTEGER NOT NULL DEFAULT 0 CHECK (is_default IN (0,1)),
    is_admin INTEGER NOT NULL DEFAULT 0 CHECK (is_admin IN (0,1)),
    created_at TEXT NOT NULL,
    disabled_at TEXT
  ) STRICT
  """,
  """
  CREATE UNIQUE INDEX IF NOT EXISTS idx_users_single_default
  ON users (is_default) WHERE is_default = 1
  """,
  // One-time email login codes. Stored as a hash with an attempt counter, so a
  // leaked database yields no usable code and guessing is bounded.
  """
  CREATE TABLE IF NOT EXISTS auth_login_codes (
    code_id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(user_id),
    code_hash TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    consumed_at TEXT
  ) STRICT
  """,
  """
  CREATE INDEX IF NOT EXISTS idx_auth_login_codes_user
  ON auth_login_codes (user_id, consumed_at, expires_at)
  """,
  // Libraries precede notebooks for the same reason users do: the grouping
  // foreign key needs the table to exist, and every notebook belongs to a real
  // library rather than to a null "ungrouped" (`design-docs/specs/library.md`).
  """
  CREATE TABLE IF NOT EXISTS libraries (
    library_id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    title TEXT NOT NULL,
    auth_required INTEGER NOT NULL DEFAULT 1 CHECK (auth_required IN (0,1)),
    is_default INTEGER NOT NULL DEFAULT 0 CHECK (is_default IN (0,1)),
    created_at TEXT NOT NULL,
    created_by TEXT REFERENCES users(user_id)
  ) STRICT
  """,
  """
  CREATE UNIQUE INDEX IF NOT EXISTS idx_libraries_single_default
  ON libraries (is_default) WHERE is_default = 1
  """,
  // Who may reach a library that requires authentication. An open library
  // needs no rows here: `auth_required = 0` already means "anyone", and
  // membership answers the other half — which authenticated users get in
  // (`design-docs/specs/library.md`).
  """
  CREATE TABLE IF NOT EXISTS library_members (
    library_id TEXT NOT NULL REFERENCES libraries(library_id),
    user_id TEXT NOT NULL REFERENCES users(user_id),
    role TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('owner','member')),
    granted_at TEXT NOT NULL,
    granted_by TEXT REFERENCES users(user_id),
    PRIMARY KEY (library_id, user_id)
  ) STRICT, WITHOUT ROWID
  """,
  """
  CREATE INDEX IF NOT EXISTS idx_library_members_user
  ON library_members (user_id, library_id)
  """,
  """
  CREATE TABLE IF NOT EXISTS notebooks (
    notebook_id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    read_only INTEGER NOT NULL DEFAULT 0 CHECK (read_only IN (0,1)),
    owner_user_id TEXT NOT NULL REFERENCES users(user_id),
    library_id TEXT NOT NULL REFERENCES libraries(library_id) DEFAULT 'library-default',
    created_by TEXT REFERENCES users(user_id),
    updated_by TEXT REFERENCES users(user_id),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    meta_json BLOB CHECK (meta_json IS NULL OR json_valid(meta_json, 8))
  ) STRICT
  """,
  """
  CREATE INDEX IF NOT EXISTS idx_notebooks_owner
  ON notebooks (owner_user_id, updated_at DESC)
  """,
  """
  CREATE INDEX IF NOT EXISTS idx_notebooks_library
  ON notebooks (library_id, updated_at DESC)
  """,
  // A translation source token must survive action-history retention pruning.
  // It is internal state rather than user-visible notebook metadata.
  """
  CREATE TABLE IF NOT EXISTS notebook_translation_revisions (
    notebook_id TEXT PRIMARY KEY REFERENCES notebooks(notebook_id) ON DELETE CASCADE,
    revision INTEGER NOT NULL CHECK (revision >= 0)
  ) STRICT, WITHOUT ROWID
  """,
  """
  CREATE TABLE IF NOT EXISTS notes (
    note_id TEXT PRIMARY KEY,
    notebook_id TEXT NOT NULL REFERENCES notebooks(notebook_id),
    note_number INTEGER NOT NULL,
    title TEXT,
    title_source TEXT NOT NULL DEFAULT 'derived' CHECK (title_source IN ('derived','explicit')),
    body_markdown TEXT NOT NULL,
    read_only INTEGER NOT NULL DEFAULT 0 CHECK (read_only IN (0,1)),
    created_by TEXT REFERENCES users(user_id),
    updated_by TEXT REFERENCES users(user_id),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    meta_json BLOB CHECK (meta_json IS NULL OR json_valid(meta_json, 8)),
    UNIQUE (notebook_id, note_number)
  ) STRICT
  """,
  "CREATE INDEX IF NOT EXISTS idx_notes_created ON notes(created_at DESC)",
  """
  CREATE TABLE IF NOT EXISTS tag_classes (
    class_id TEXT PRIMARY KEY,
    label TEXT NOT NULL,
    description TEXT,
    is_system INTEGER NOT NULL DEFAULT 0 CHECK (is_system IN (0,1)),
    created_at TEXT NOT NULL
  ) STRICT
  """,
  """
  CREATE TABLE IF NOT EXISTS tags (
    tag_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    class_id TEXT REFERENCES tag_classes(class_id),
    parent_tag_id TEXT REFERENCES tags(tag_id),
    is_system INTEGER NOT NULL DEFAULT 0 CHECK (is_system IN (0,1)),
    created_at TEXT NOT NULL
  ) STRICT
  """,
  """
  CREATE INDEX IF NOT EXISTS idx_tags_parent
  ON tags (parent_tag_id) WHERE parent_tag_id IS NOT NULL
  """,
  """
  CREATE INDEX IF NOT EXISTS idx_tags_class
  ON tags (class_id) WHERE class_id IS NOT NULL
  """,
  """
  CREATE TABLE IF NOT EXISTS note_tags (
    note_id TEXT NOT NULL REFERENCES notes(note_id),
    tag_id TEXT NOT NULL REFERENCES tags(tag_id),
    provenance TEXT NOT NULL CHECK (provenance IN ('human','ai','system')),
    assigned_by TEXT,
    deletable INTEGER NOT NULL DEFAULT 1 CHECK (deletable IN (0,1)),
    created_at TEXT NOT NULL,
    PRIMARY KEY (note_id, tag_id)
  ) STRICT, WITHOUT ROWID
  """,
  "CREATE INDEX IF NOT EXISTS idx_note_tags_tag ON note_tags(tag_id, note_id)",
  """
  CREATE TABLE IF NOT EXISTS notebook_tags (
    notebook_id TEXT NOT NULL REFERENCES notebooks(notebook_id),
    tag_id TEXT NOT NULL REFERENCES tags(tag_id),
    provenance TEXT NOT NULL CHECK (provenance IN ('human','ai','system')),
    assigned_by TEXT,
    deletable INTEGER NOT NULL DEFAULT 1 CHECK (deletable IN (0,1)),
    created_at TEXT NOT NULL,
    PRIMARY KEY (notebook_id, tag_id)
  ) STRICT, WITHOUT ROWID
  """,
  "CREATE INDEX IF NOT EXISTS idx_notebook_tags_tag ON notebook_tags(tag_id, notebook_id)",
  // Exactly one locator per storage kind: a migrated row must drop its stale
  // local path, and a local row must not carry half-filled S3 coordinates.
  """
  CREATE TABLE IF NOT EXISTS files (
    file_id TEXT PRIMARY KEY,
    storage_kind TEXT NOT NULL CHECK (storage_kind IN ('local','s3')),
    local_path TEXT,
    s3_profile TEXT,
    s3_bucket TEXT,
    s3_key TEXT,
    media_type TEXT NOT NULL,
    byte_size INTEGER NOT NULL CHECK (byte_size >= 0),
    sha256 TEXT NOT NULL,
    original_filename TEXT,
    created_at TEXT NOT NULL,
    migrated_at TEXT,
    CHECK (
      (
        storage_kind = 'local'
        AND local_path IS NOT NULL
        AND s3_profile IS NULL
        AND s3_bucket IS NULL
        AND s3_key IS NULL
      )
      OR (
        storage_kind = 's3'
        AND local_path IS NULL
        AND s3_profile IS NOT NULL
        AND s3_bucket IS NOT NULL
        AND s3_key IS NOT NULL
      )
    )
  ) STRICT
  """,
  "CREATE INDEX IF NOT EXISTS idx_files_sha ON files(sha256)",
  """
  CREATE TABLE IF NOT EXISTS note_files (
    note_id TEXT NOT NULL REFERENCES notes(note_id),
    file_id TEXT NOT NULL REFERENCES files(file_id),
    role TEXT NOT NULL CHECK (role IN ('embedded','related','source-page-image')),
    position INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (note_id, file_id, role)
  ) STRICT, WITHOUT ROWID
  """,
  "CREATE INDEX IF NOT EXISTS idx_note_files_file ON note_files(file_id)",
  """
  CREATE TABLE IF NOT EXISTS notebook_files (
    notebook_id TEXT NOT NULL REFERENCES notebooks(notebook_id),
    file_id TEXT NOT NULL REFERENCES files(file_id),
    role TEXT NOT NULL CHECK (role IN ('source-document','related')),
    PRIMARY KEY (notebook_id, file_id, role)
  ) STRICT, WITHOUT ROWID
  """,
  "CREATE INDEX IF NOT EXISTS idx_notebook_files_file ON notebook_files(file_id)",
  """
  CREATE TABLE IF NOT EXISTS note_links (
    from_note_id TEXT NOT NULL REFERENCES notes(note_id),
    to_note_id TEXT NOT NULL REFERENCES notes(note_id),
    link_kind TEXT NOT NULL DEFAULT 'related',
    provenance TEXT NOT NULL CHECK (provenance IN ('human','ai','system')),
    created_at TEXT NOT NULL,
    PRIMARY KEY (from_note_id, to_note_id, link_kind)
  ) STRICT, WITHOUT ROWID
  """,
  "CREATE INDEX IF NOT EXISTS idx_note_links_to ON note_links(to_note_id)",
  noteCommentsTableStatement,
  "CREATE INDEX IF NOT EXISTS idx_note_comments_note ON note_comments(note_id) WHERE note_id IS NOT NULL",
  "CREATE INDEX IF NOT EXISTS idx_note_comments_notebook ON note_comments(notebook_id) WHERE notebook_id IS NOT NULL",
  """
  CREATE TABLE IF NOT EXISTS app_settings (
    setting_key TEXT PRIMARY KEY,
    value_json BLOB NOT NULL CHECK (json_valid(value_json, 8)),
    updated_at TEXT NOT NULL
  ) STRICT, WITHOUT ROWID
  """,
  """
  CREATE TABLE IF NOT EXISTS auto_actions (
    action_id TEXT PRIMARY KEY,
    trigger TEXT NOT NULL CHECK (trigger IN ('note-created','note-updated','notebook-created')),
    workflow_id TEXT NOT NULL,
    filter_json BLOB CHECK (filter_json IS NULL OR json_valid(filter_json, 8)),
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0,1)),
    position INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
  ) STRICT
  """,
  autoActionDispatchesTableStatement,
  autoActionDispatchesStatusIndexStatement,
  autoActionCancellationTableStatement,
  noteActionLogTableStatement,
  noteActionLogActorIndexStatement,
  noteActionLogEntityIndexStatement,
  """
  CREATE TABLE IF NOT EXISTS api_clients (
    client_id TEXT PRIMARY KEY,
    display_name TEXT NOT NULL,
    token_hash TEXT NOT NULL,
    user_id TEXT NOT NULL REFERENCES users(user_id),
    created_at TEXT NOT NULL,
    last_seen_at TEXT,
    revoked_at TEXT
  ) STRICT
  """,
  "CREATE INDEX IF NOT EXISTS idx_api_clients_user ON api_clients(user_id)",
  // One personal-agent provider credential per user
  // (`design-docs/specs/user-agent-tools.md`, UA1). The key is stored as
  // given and is never selected by any caller-facing read path.
  """
  CREATE TABLE IF NOT EXISTS user_agent_credentials (
    user_id TEXT PRIMARY KEY REFERENCES users(user_id),
    provider TEXT NOT NULL CHECK (provider IN ('anthropic','openai','openrouter','openai-compatible')),
    api_key TEXT NOT NULL,
    base_url TEXT,
    default_model TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0,1)),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  ) STRICT
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
    note_id TEXT NOT NULL UNIQUE REFERENCES notes(note_id)
  ) STRICT
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
  ) STRICT
  """

private let autoActionDispatchesTableStatement = """
  CREATE TABLE IF NOT EXISTS auto_action_dispatches (
    dispatch_id TEXT PRIMARY KEY,
    action_id TEXT NOT NULL,
    action_trigger TEXT NOT NULL CHECK (action_trigger IN ('note-created','note-updated','notebook-created')),
    workflow_id TEXT NOT NULL,
    filter_json BLOB CHECK (filter_json IS NULL OR json_valid(filter_json, 8)),
    action_enabled INTEGER NOT NULL CHECK (action_enabled IN (0,1)),
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
  ) STRICT
  """

private let autoActionDispatchesStatusIndexStatement =
  "CREATE INDEX IF NOT EXISTS idx_auto_action_dispatches_status ON auto_action_dispatches(status, created_at)"

/// An explicit terminal cancellation outcome for dispatch rows. The original
/// dispatch status remains compatible with existing stores; readers project a
/// joined cancellation as `.cancelled` rather than conflating it with a
/// successful provider dispatch.
private let autoActionCancellationTableStatement = """
  CREATE TABLE IF NOT EXISTS auto_action_dispatch_cancellations (
    dispatch_id TEXT PRIMARY KEY REFERENCES auto_action_dispatches(dispatch_id),
    reason TEXT NOT NULL,
    cancelled_at TEXT NOT NULL
  ) STRICT, WITHOUT ROWID
  """

/// Append-only per-actor action history behind undo/redo
/// (`design-docs/specs/action-history-undo.md`). Added through this idempotent
/// list on purpose (U1): existing stores gain it at `prepare` without a
/// version bump, the same way `app_settings` arrived. `AUTOINCREMENT` keeps
/// `seq` monotonic across retention pruning, and `action` carries no CHECK so
/// an older build can still read rows written by a newer one.
private let noteActionLogTableStatement = """
  CREATE TABLE IF NOT EXISTS note_action_log (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    occurred_at TEXT NOT NULL,
    actor_user_id TEXT NOT NULL REFERENCES users(user_id),
    provenance TEXT NOT NULL CHECK (provenance IN ('human','ai','system')),
    entity_type TEXT NOT NULL CHECK (entity_type IN ('note','notebook','comment')),
    entity_id TEXT NOT NULL,
    notebook_id TEXT,
    action TEXT NOT NULL,
    display_json BLOB NOT NULL CHECK (json_valid(display_json, 8)),
    delta_json BLOB CHECK (delta_json IS NULL OR json_valid(delta_json, 8)),
    undoable INTEGER NOT NULL CHECK (undoable IN (0,1)),
    undo_of_seq INTEGER,
    undone_by_seq INTEGER
  ) STRICT
  """

private let noteActionLogActorIndexStatement =
  "CREATE INDEX IF NOT EXISTS idx_note_action_log_actor ON note_action_log(actor_user_id, seq DESC)"

private let noteActionLogEntityIndexStatement =
  "CREATE INDEX IF NOT EXISTS idx_note_action_log_entity ON note_action_log(entity_type, entity_id, seq DESC)"

struct NoteStoreClock: Sendable {
  var now: @Sendable () -> String

  static let system = NoteStoreClock {
    noteStoreTimestampFormatter.string(from: Date())
  }
}

private let noteStoreTimestampFormatter = NoteStoreTimestampFormatter()

/// Store timestamps are ISO-8601 with fractional seconds, so they compare
/// lexicographically; expiry predicates in SQL rely on that.
func noteStoreTimestamp(from date: Date) -> String {
  noteStoreTimestampFormatter.string(from: date)
}

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
