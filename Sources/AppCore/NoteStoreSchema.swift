import Foundation

public enum NoteStoreSchemaError: Error, Equatable, Sendable {
  case unsupportedFutureVersion(found: Int, supported: Int)
  case unsupportedLegacyVersion(found: Int, required: Int)
  case systemTagCollision(name: String)
  case storeInvariant(String)
}

extension NoteStoreSchemaError: CustomStringConvertible, LocalizedError {
  public var description: String {
    switch self {
    case let .unsupportedFutureVersion(found, supported):
      return "note store schema \(found) is newer than this kaiba supports (\(supported)); upgrade kaiba"
    case let .unsupportedLegacyVersion(found, required):
      return "note store schema \(found) predates \(required) and cannot be upgraded; "
        + "move note-store.sqlite out of the note root (or delete it) to start a new store"
    case let .systemTagCollision(name):
      return "a user tag collides with the system tag \(name)"
    case let .storeInvariant(message):
      return "note store invariant failed: \(message)"
    }
  }

  public var errorDescription: String? { description }
}

public enum NoteStoreSchema {
  public static let currentVersion = 25
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
  /// Per-tag memo/chat notebooks (`design-docs/specs/tag-detail-pane.md`, T4).
  public static let tagMemoNotebookKindTag = "notebook-kind:tag-memo"
  /// The single accumulating notebook every anywhere-capture write lands in
  /// (`design-docs/specs/note-capture-and-entity-pages.md`, C3). Identified by
  /// this kind tag rather than by title, because titles are user-mutable.
  public static let quickMemoNotebookKindTag = "notebook-kind:quick-memo"
  static let quickMemoNotebookKindTagId = stableTagId(for: quickMemoNotebookKindTag)
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

  /// Creates a fresh store from the ERD-generated DDL, or accepts a store that
  /// is already at `currentVersion` (`design-docs/specs/note-store-schema-v25.md`).
  /// There are no upgrade paths: an older store is rejected and must be
  /// recreated. `BEGIN IMMEDIATE` serializes concurrent first opens, so only
  /// one of them sees an empty database.
  public static func prepare(in database: SQLiteDatabase) throws {
    try NoteSQLiteCapabilityCache.requireAvailable(in: database)
    try database.transaction { db in
      let isFirstSchemaCreation = try requireSupportedStore(in: db)
      if isFirstSchemaCreation {
        for statement in generatedSchemaStatements {
          try db.execute(statement)
        }
        try db.execute(noteFTSTableStatement)
        try recordSchemaVersion(currentVersion, in: db)
      }
      try seedDefaultUser(in: db)
      try seedDefaultLibrary(in: db)
      try requireForeignKeysEnabled(in: db)
      try requireForeignKeyIntegrity(in: db)
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

  /// Returns true for an empty database that still needs its schema.
  private static func requireSupportedStore(in database: SQLiteDatabase) throws -> Bool {
    let hasVersionTable = try !database.query(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'note_schema_version'"
    ).isEmpty
    guard hasVersionTable else {
      let objectCount = try database.query(
        "SELECT count(*) AS count FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'"
      ).first?["count"].flatMap(Int.init) ?? 0
      guard objectCount == 0 else {
        throw NoteStoreSchemaError.storeInvariant("database is not a kaiba note store")
      }
      return true
    }
    let newest = try appliedSchemaVersions(in: database).max() ?? 0
    if newest > currentVersion {
      throw NoteStoreSchemaError.unsupportedFutureVersion(found: newest, supported: currentVersion)
    }
    if newest < currentVersion {
      throw NoteStoreSchemaError.unsupportedLegacyVersion(found: newest, required: currentVersion)
    }
    return false
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

  /// The generated DDL split into executable statements. nodetto ends every
  /// statement with `;` at the end of a line and never inside a comment line;
  /// leading comments and the connection-level `PRAGMA` are dropped (the
  /// driver enables foreign keys and `requireForeignKeysEnabled` verifies it).
  static let generatedSchemaStatements: [String] = splitSchemaStatements(noteStoreSchemaSQL)

  static func splitSchemaStatements(_ sql: String) -> [String] {
    var statements: [String] = []
    var current: [Substring] = []
    for line in sql.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      let isComment = trimmed.hasPrefix("--")
      if current.isEmpty, trimmed.isEmpty || isComment {
        continue
      }
      current.append(line)
      if !isComment, trimmed.hasSuffix(";") {
        statements.append(current.joined(separator: "\n"))
        current = []
      }
    }
    precondition(current.isEmpty, "generated note-store DDL ends inside a statement")
    return statements.filter { !$0.hasPrefix("PRAGMA ") }
  }

  /// The contentless FTS5 index is not expressible in the ERD.
  static let noteFTSTableStatement = """
    CREATE VIRTUAL TABLE note_fts USING fts5(
      title, body, tags, context,
      content='',
      tokenize='trigram'
    )
    """

  /// Drops and re-derives the whole search index from `notes`. The FTS table
  /// is contentless, so a drifted index cannot be patched row by row — the
  /// stale entries carry no recoverable payload for the 'delete' command —
  /// and a full rebuild is the one repair that is always correct. Used by
  /// `NoteService.checkStore(repair:)`.
  static func rebuildNoteFTS(in database: SQLiteDatabase) throws {
    try database.execute("DROP TABLE IF EXISTS note_fts")
    try database.execute(noteFTSTableStatement)
    try database.execute("DELETE FROM note_fts_map")
    let noteIds = try database.query("SELECT note_id FROM notes ORDER BY created_at, note_id").compactMap { $0.identifier("note_id", as: NoteID.self) }
    for noteId in noteIds {
      try refreshFTS(noteId: noteId, previous: nil, in: database)
    }
  }

  private static func requireForeignKeysEnabled(in database: SQLiteDatabase) throws {
    guard try database.query("PRAGMA foreign_keys").first?["foreign_keys"] == "1" else {
      throw NoteStoreSchemaError.storeInvariant("foreign-key enforcement is disabled")
    }
  }

  private static func requireForeignKeyIntegrity(in database: SQLiteDatabase) throws {
    guard try database.query("PRAGMA foreign_key_check").isEmpty else {
      throw NoteStoreSchemaError.storeInvariant("foreign-key integrity check failed")
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
  SystemTagClass(classId: .date, label: "Date", description: "Calendar dates"),
  SystemTagClass(classId: .name, label: "Name", description: "Names of entities and named things"),
  SystemTagClass(classId: .place, label: "Place", description: "Places and geographic locations"),
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
  NoteStoreSchema.quickMemoNotebookKindTag
]

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
