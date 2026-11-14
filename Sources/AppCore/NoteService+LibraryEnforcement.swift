import Foundation

// Library reachability, enforced below the catalog.
//
// `listNotebooks` filters by library, but a caller that already holds a note or
// notebook id used to reach it regardless. These wrappers close that: they
// shadow the unguarded `load*` row readers under the names the service already
// calls (`requireNotebook`, `requireNote`, ...), so every path that fetches a
// row by id goes through the check without each one being edited
// (`design-docs/specs/library.md`).
//
// Reach is decided per library and per account: an open library is reachable
// by anyone, and one that requires authentication is reachable by the accounts
// granted access in `library_members`. Reach *inside* a library — one member
// reading another member's notebook by id — is enforced by
// `requireNotebookOwnership`. Tag-detail queries apply the same reachable
// library scope before returning comments, aggregates, or memo notebooks.

extension NoteService {
  func requireNotebook(_ notebookId: NotebookID, in db: SQLiteDatabase) throws -> Notebook {
    let notebook = try loadNotebook(notebookId, in: db)
    try requireLibraryReach(
      libraryId: notebook.libraryId,
      subject: notebookId.rawValue,
      kind: .notebook,
      in: db
    )
    try requireNotebookOwnership(notebookId, subject: notebookId.rawValue, in: db)
    return notebook
  }

  func requireNote(_ noteId: NoteID, in db: SQLiteDatabase) throws -> Note {
    let note = try loadNote(noteId, in: db)
    try requireLibraryReach(
      notebookId: note.notebookId,
      subject: noteId.rawValue,
      kind: .note,
      in: db
    )
    try requireNotebookOwnership(note.notebookId, subject: noteId.rawValue, in: db)
    return note
  }

  @discardableResult
  func requireWritableNote(_ noteId: NoteID, in db: SQLiteDatabase) throws -> Note {
    // Establish reach and ownership before exposing mutable state.  In
    // particular, a foreign read-only note must be indistinguishable from a
    // missing row, not report its read-only state to the caller.
    let note = try loadNote(noteId, in: db)
    try requireLibraryReach(
      notebookId: note.notebookId,
      subject: noteId.rawValue,
      kind: .note,
      in: db
    )
    try requireNotebookOwnership(note.notebookId, subject: noteId.rawValue, in: db)
    return try loadWritableNote(noteId, in: db)
  }

  @discardableResult
  func requireWritableNotebook(_ notebookId: NotebookID, in db: SQLiteDatabase) throws -> Notebook {
    // As with notes, do not reveal whether a foreign notebook is read-only.
    let notebook = try loadNotebook(notebookId, in: db)
    try requireLibraryReach(
      libraryId: notebook.libraryId,
      subject: notebookId.rawValue,
      kind: .notebook,
      in: db
    )
    try requireNotebookOwnership(notebookId, subject: notebookId.rawValue, in: db)
    return try loadWritableNotebook(notebookId, in: db)
  }

  /// Refuses a file whose owning note or notebook sits in a library this
  /// caller cannot reach. A file row is shared content-addressed storage, so
  /// reachability is decided by what references it. Unreferenced blobs remain
  /// available only to the unscoped local operator; scoped callers receive a
  /// missing-file response.
  func requireReachableFile(_ fileId: FileID, in db: SQLiteDatabase) throws {
    let rows = try db.query(
      """
      SELECT DISTINCT notebooks.notebook_id AS notebook_id, notebooks.library_id AS library_id,
        notebooks.owner_user_id AS owner_user_id
      FROM notebooks
      WHERE notebooks.notebook_id IN (
        SELECT notes.notebook_id
        FROM note_files
        JOIN notes ON notes.note_id = note_files.note_id
        WHERE note_files.file_id = ?
        UNION
        SELECT notebook_files.notebook_id
        FROM notebook_files
        WHERE notebook_files.file_id = ?
      )
      """,
      bindings: [.id(fileId), .id(fileId)]
    )
    guard !rows.isEmpty else {
      if actingUserId != nil { throw NoteServiceError.notFound("file not found: \(fileId)") }
      return
    }
    // Reachable through any referencing notebook: an attachment shared by two
    // notebooks is readable when either one is.
    for row in rows {
      guard let libraryId = row.identifier("library_id", as: LibraryID.self),
            try isReachable(libraryId: libraryId, in: db) else { continue }
      if actingUserId != nil || isUnauthenticatedPrincipal,
         let notebookId = row.identifier("notebook_id", as: NotebookID.self),
         try isLongTermMemoryNotebook(notebookId, in: db) {
        continue
      }
      if let actingUserId, row.identifier("owner_user_id", as: UserID.self) != actingUserId { continue }
      return
    }
    throw NoteServiceError.notFound("file not found: \(fileId)")
  }

  /// Scoped callers may only reach notebooks owned by their account. Long-term
  /// memory remains a store-wide internal facility until it is redesigned with
  /// per-user attribution, so it is deliberately not an ownership exception.
  func requireNotebookOwnership(_ notebookId: NotebookID, subject: String, in db: SQLiteDatabase) throws {
    guard actingUserId != nil || isUnauthenticatedPrincipal else { return }
    guard try !isLongTermMemoryNotebook(notebookId, in: db) else {
      throw NoteServiceError.notFound("notebook not found: \(subject)")
    }
    guard let actingUserId else { return }
    let rows = try db.query(
      """
      SELECT owner_user_id
      FROM notebooks WHERE notebook_id = ? LIMIT 1
      """,
      bindings: [.id(notebookId)]
    )
    guard let row = rows.first,
          row.identifier("owner_user_id", as: UserID.self) == actingUserId else {
      throw NoteServiceError.notFound("notebook not found: \(subject)")
    }
  }

  /// Returns false only for the intentionally indistinguishable missing-row
  /// authorization result. Other failures remain visible to the caller rather
  /// than being silently converted into an empty collection.
  func canReachNote(_ noteId: NoteID, in db: SQLiteDatabase) throws -> Bool {
    do {
      _ = try requireNote(noteId, in: db)
      return true
    } catch let error as NoteServiceError {
      guard case .notFound = error else {
        throw error
      }
      return false
    }
  }

  enum LibraryReachSubject {
    case note
    case notebook
    case library

    var label: String {
      switch self {
      case .note: return "note"
      case .notebook: return "notebook"
      case .library: return "library"
      }
    }
  }

  func requireLibraryReach(
    notebookId: NotebookID,
    subject: String,
    kind: LibraryReachSubject,
    in db: SQLiteDatabase
  ) throws {
    let libraryId = try db.query(
      "SELECT library_id FROM notebooks WHERE notebook_id = ? LIMIT 1",
      bindings: [.id(notebookId)]
    ).first?.identifier("library_id", as: LibraryID.self)
    try requireLibraryReach(libraryId: libraryId, subject: subject, kind: kind, in: db)
  }

  /// Reports the row as missing rather than forbidden. A distinct "forbidden"
  /// answer would confirm that an id exists in a library the caller was told
  /// nothing about.
  func requireLibraryReach(
    libraryId: LibraryID?,
    subject: String,
    kind: LibraryReachSubject,
    in db: SQLiteDatabase
  ) throws {
    guard let libraryId else {
      return
    }
    guard try isReachable(libraryId: libraryId, in: db) else {
      throw NoteServiceError.notFound("\(kind.label) not found: \(subject)")
    }
  }

  /// Whether this caller may reach a library at all.
  ///
  /// - A selected library excludes every other one.
  /// - A caller with no credential gets only the open libraries.
  /// - An admin account reaches every library.
  /// - Any other authenticated account gets the open libraries plus the ones
  ///   it is a member of (`library_members`).
  /// - The unscoped local CLI is the operator view and reaches everything; it
  ///   holds the store file, so hiding rows from it would be theater.
  func isReachable(libraryId: LibraryID, in db: SQLiteDatabase) throws -> Bool {
    if let actingLibraryId, libraryId != actingLibraryId {
      return false
    }
    guard isUnauthenticatedPrincipal || actingUserId != nil else {
      return true
    }
    if try isActingAdmin(in: db) {
      return true
    }
    let rows = try db.query(
      "SELECT auth_required FROM libraries WHERE library_id = ? LIMIT 1",
      bindings: [.id(libraryId)]
    )
    guard let row = rows.first, let authRequired = row["auth_required"] else {
      return false
    }
    if authRequired == "0" {
      return true
    }
    // Membership grants an *account* access. A request that presented no
    // credential is not that account even though the note API resolves it to
    // the default user, so the marker wins over any grant that account holds.
    guard !isUnauthenticatedPrincipal, let actingUserId else {
      return false
    }
    return try isLibraryMember(libraryId: libraryId, userId: actingUserId, in: db)
  }

  /// Refuses a store-wide privileged operation to anyone but the unscoped
  /// local operator or an acting admin account. The cross-library file
  /// maintenance passes (`migrateAllLocalFiles`, `reclaimUnreferencedFiles`)
  /// carry no library predicate, so without this any authenticated client
  /// could migrate or sweep blobs belonging to libraries it cannot read.
  func requireStoreAdministrator() throws {
    try driver.withDatabase { db in
      // The unscoped local CLI is the operator view (see `isReachable`): no
      // acting user and no unauthenticated marker means the process opened the
      // store directly and already holds the file.
      if actingUserId == nil, !isUnauthenticatedPrincipal {
        return
      }
      guard try isActingAdmin(in: db) else {
        throw NoteServiceError.invalidInput("this operation requires an administrator account")
      }
    }
  }

  /// Whether the acting account is an enabled admin. Read per call rather
  /// than cached on the service value, so revoking admin takes effect on the
  /// next request instead of at the next process start. A request that
  /// presented no credential is never treated as one even though it resolves
  /// to the admin account (`design-docs/specs/library.md`).
  func isActingAdmin(in db: SQLiteDatabase) throws -> Bool {
    guard !isUnauthenticatedPrincipal, let actingUserId else {
      return false
    }
    let rows = try db.query(
      "SELECT is_admin FROM users WHERE user_id = ? AND disabled_at IS NULL LIMIT 1",
      bindings: [.id(actingUserId)]
    )
    return rows.first?["is_admin"] == "1"
  }

  /// The libraries a bulk read may draw from, or nil when unrestricted. Used
  /// by search and graph traversal, where a per-row check would mean one query
  /// per hit, and where dropping rows after the fact would silently shrink a
  /// page.
  func reachableLibraryIds(in db: SQLiteDatabase) throws -> [LibraryID]? {
    if let actingLibraryId {
      // Still subject to the same rule: a selection narrows what a caller may
      // see, it never widens it.
      return try isReachable(libraryId: actingLibraryId, in: db) ? [actingLibraryId] : []
    }
    if isUnauthenticatedPrincipal {
      return try db.query(
        "SELECT library_id FROM libraries WHERE auth_required = 0"
      ).compactMap { $0.identifier("library_id", as: LibraryID.self) }
    }
    guard let actingUserId else {
      return nil
    }
    if try isActingAdmin(in: db) {
      return nil
    }
    return try db.query(
      """
      SELECT library_id FROM libraries
      WHERE auth_required = 0
        OR library_id IN (SELECT library_id FROM library_members WHERE user_id = ?)
      """,
      bindings: [.id(actingUserId)]
    ).compactMap { $0.identifier("library_id", as: LibraryID.self) }
  }

  /// Drops note ids whose notebook sits in an unreachable library. Graph
  /// traversal walks links, and a link may cross into a library the caller
  /// cannot see, so the crossing has to be cut on the way out.
  func reachableNoteIds(_ noteIds: [NoteID], in db: SQLiteDatabase) throws -> Set<NoteID> {
    let reachableLibraryIds = try reachableLibraryIds(in: db)
    guard !noteIds.isEmpty, reachableLibraryIds != [] else {
      return []
    }
    var predicates = ["notes.note_id IN (\(placeholders(count: noteIds.count)))"]
    var bindings = noteIds.sqliteBindings
    if let reachableLibraryIds {
      predicates.append("notebooks.library_id IN (\(placeholders(count: reachableLibraryIds.count)))")
      bindings.append(contentsOf: reachableLibraryIds.sqliteBindings)
    }
    appendOwnerScopePredicate(
      alias: "notes",
      actingUserId: actingUserId,
      predicates: &predicates,
      bindings: &bindings
    )
    if isUnauthenticatedPrincipal, actingUserId == nil {
      appendLongTermMemoryExclusionPredicate(
        alias: "notes",
        excludesLongTermMemory: true,
        predicates: &predicates,
        bindings: &bindings
      )
    }
    let rows = try db.query(
      """
      SELECT notes.note_id AS note_id
      FROM notes
      JOIN notebooks ON notebooks.notebook_id = notes.notebook_id
      WHERE \(predicates.joined(separator: " AND "))
      """,
      bindings: bindings
    )
    return Set(rows.compactMap { $0.identifier("note_id", as: NoteID.self) })
  }

  func isLongTermMemoryNotebook(_ notebookId: NotebookID, in db: SQLiteDatabase) throws -> Bool {
    try !db.query(
      """
      SELECT 1
      FROM notebook_tags
      WHERE notebook_id = ? AND tag_id = ?
      LIMIT 1
      """,
      bindings: [.id(notebookId), .id(NoteStoreSchema.longTermMemoryNotebookKindTagId)]
    ).isEmpty
  }

  func filterReachable(
    _ neighbors: [NoteGraphNeighbor],
    in db: SQLiteDatabase
  ) throws -> [NoteGraphNeighbor] {
    let reachable = try reachableNoteIds(neighbors.map(\.note.noteId), in: db)
    return neighbors.filter { reachable.contains($0.note.noteId) }
  }
}
