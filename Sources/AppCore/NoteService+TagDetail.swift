import Foundation

/// Cross-notebook tag detail surface (`design-docs/specs/tag-detail-pane.md`,
/// T4/T5/T9). A tag's memos and agent chat bind to a lazily created
/// `tag-memo` notebook; the subject binding is recorded in notebook meta JSON
/// (`kaibaTagMemo.subjectTagId`), mirroring the `kaibaChat` pattern.

public struct TagDetail: Equatable, Sendable {
  public var tag: Tag
  public var tagClass: TagClass?
  /// Distinct notes carrying the tag or one of its descendants.
  public var noteCount: Int
  /// Distinct notebooks carrying the tag or one of its descendants.
  public var notebookCount: Int
  /// The tag's memo notebook, when one has been created.
  public var memoNotebookId: NotebookID?
  /// The note designated as this tag's canonical description
  /// (`design-docs/specs/note-capture-and-entity-pages.md`, E1/E2). Nil when
  /// nothing is bound, and also when the bound note lies outside this
  /// principal's reach — an entity header must not leak a note the caller
  /// could not open.
  public var canonicalNote: Note?
  /// Tags sharing notes with this tag, most shared notes first (E4).
  public var coOccurringTags: [TagCoOccurrence]

  public init(
    tag: Tag,
    tagClass: TagClass?,
    noteCount: Int,
    notebookCount: Int,
    memoNotebookId: NotebookID?,
    canonicalNote: Note? = nil,
    coOccurringTags: [TagCoOccurrence] = []
  ) {
    self.tag = tag
    self.tagClass = tagClass
    self.noteCount = noteCount
    self.notebookCount = notebookCount
    self.memoNotebookId = memoNotebookId
    self.canonicalNote = canonicalNote
    self.coOccurringTags = coOccurringTags
  }
}

/// One tag that appears alongside the subject tag, with the number of notes
/// the two share (`design-docs/specs/note-capture-and-entity-pages.md`, E4).
public struct TagCoOccurrence: Equatable, Sendable {
  public var tag: Tag
  public var noteCount: Int

  public init(tag: Tag, noteCount: Int) {
    self.tag = tag
    self.noteCount = noteCount
  }
}

/// A memo aggregated into a tag's history, attributed with the titles of its
/// anchoring note/notebook so clients can label and navigate without extra
/// round trips.
public struct TagAttributedComment: Equatable, Sendable {
  public var comment: NoteComment
  public var noteTitle: String?
  public var notebookTitle: String?

  public init(comment: NoteComment, noteTitle: String?, notebookTitle: String?) {
    self.comment = comment
    self.noteTitle = noteTitle
    self.notebookTitle = notebookTitle
  }
}

private struct TagMemoNotebookCreationResult {
  var notebook: Notebook
  var dispatches: [QueuedAutoActionDispatch]
  var created: Bool
}

public extension NoteService {
  /// How many co-occurring tags a `tagDetail` payload carries by default (E4).
  /// The entity header shows chips, not a catalog, so the default is small and
  /// callers that want more pass an explicit limit.
  static let defaultCoOccurringTagLimit = 10

  /// The largest co-occurrence limit any surface may ask for. It matches the
  /// transport's own bound, so an over-large document limit is refused there
  /// before it ever reaches the service rather than being bounded twice.
  static let maximumCoOccurringTagLimit = 200

  /// The tag plus its class and cross-notebook aggregate counts. Counts expand
  /// to descendant tags like every tag filter (D16/D17).
  ///
  /// `coOccurringTagLimit` sizes the co-occurrence chips the payload carries
  /// (E4). It is a defaulted parameter rather than a second entry point so a
  /// caller wanting a different size gets it from the one aggregate this read
  /// already runs, instead of taking the default payload, discarding its chips
  /// and re-running the query at its own size.
  func tagDetail(
    tagId: TagID,
    coOccurringTagLimit: Int = NoteService.defaultCoOccurringTagLimit
  ) throws -> TagDetail {
    try requireValidCoOccurringTagLimit(coOccurringTagLimit)
    return try driver.withDatabase { database in
      let tag = try requireTag(id: tagId, in: database)
      let tagClass = try tag.classId.map { try requireTagClass(classId: $0, in: database) }
      let expanded = try expandedTagFilterIds([tagId], in: database)
      let reachableLibraryIds = try reachableLibraryIds(in: database)
      let noteCount = try taggedEntityCount(
        table: "note_tags",
        idColumn: "note_id",
        tagIds: expanded,
        actingUserId: actingUserId,
        reachableLibraryIds: reachableLibraryIds,
        excludesLongTermMemory: actingUserId != nil || isUnauthenticatedPrincipal,
        excludesPendingNotebookIngests: !allowsPendingNotebookIngestAccess,
        in: database
      )
      let notebookCount = try taggedEntityCount(
        table: "notebook_tags",
        idColumn: "notebook_id",
        tagIds: expanded,
        actingUserId: actingUserId,
        reachableLibraryIds: reachableLibraryIds,
        excludesLongTermMemory: actingUserId != nil || isUnauthenticatedPrincipal,
        excludesPendingNotebookIngests: !allowsPendingNotebookIngestAccess,
        in: database
      )
      return TagDetail(
        tag: tag,
        tagClass: tagClass,
        noteCount: noteCount,
        notebookCount: notebookCount,
        memoNotebookId: try findTagMemoNotebookId(
          tagId: tagId,
          actingUserId: actingUserId,
          libraryIds: reachableLibraryIds,
          excludesPendingNotebookIngests: !allowsPendingNotebookIngestAccess,
          in: database
        ),
        canonicalNote: try canonicalNote(tagId: tagId, in: database),
        coOccurringTags: try coOccurringTags(
          tagId: tagId,
          limit: coOccurringTagLimit,
          in: database
        )
      )
    }
  }

  /// Designates `noteId` as the tag's canonical description (E2). The binding
  /// is a column on the tag row, so promoting replaces any previous one —
  /// last promote wins — and no tag assignment is created: the canonical note
  /// is rendered in the entity header, not as an occurrence (E3).
  ///
  /// Organizational tags are refused: folder-class tags shape the notebook
  /// tree and document-kind tags mark notebook kinds, so neither is a subject
  /// that can have a description (the T1 exclusion rationale).
  @discardableResult
  func promoteTagCanonicalNote(tagId: TagID, noteId: NoteID) throws -> Note {
    let result = try driver.withDatabase { database in
      try database.transaction { db -> (tag: Tag, note: Note) in
        try requireEnabledActingUser(in: db)
        let tag = try requireTag(id: tagId, in: db)
        try requireCanonicalPromotable(tag)
        let note = try requireNote(noteId, in: db)
        try db.execute(
          "UPDATE tags SET canonical_note_id = ? WHERE tag_id = ?",
          bindings: [.id(noteId), .id(tagId)]
        )
        return (tag, note)
      }
    }
    // The entity header is part of every tag surface, so live clients need the
    // same wake-up a tag assignment gives them.
    publishChange(NoteChangeEvent(
      kind: NoteChangeEventKind.noteTags,
      notebookId: result.note.notebookId,
      tagNames: [result.tag.name]
    ))
    return result.note
  }

  /// Clears the tag's canonical binding (E2), returning the note that was
  /// bound. Unpromoting an unbound tag is a no-op success and publishes
  /// nothing. A binding whose note is out of this principal's reach reads as
  /// unbound here for the same reason `tagDetail` hides it: the caller is told
  /// nothing about a note it cannot see.
  @discardableResult
  func unpromoteTagCanonicalNote(tagId: TagID) throws -> Note? {
    let result = try driver.withDatabase { database in
      try database.transaction { db -> (tag: Tag, note: Note?) in
        try requireEnabledActingUser(in: db)
        let tag = try requireTag(id: tagId, in: db)
        guard let note = try canonicalNote(tagId: tagId, in: db) else {
          return (tag, nil)
        }
        try db.execute(
          "UPDATE tags SET canonical_note_id = NULL WHERE tag_id = ?",
          bindings: [.id(tagId)]
        )
        return (tag, note)
      }
    }
    guard let note = result.note else { return nil }
    publishChange(NoteChangeEvent(
      kind: NoteChangeEventKind.noteTags,
      notebookId: note.notebookId,
      tagNames: [result.tag.name]
    ))
    return note
  }

  /// Tags that share notes with `tagId`, most shared notes first (E4). Work is
  /// proportional to the tag's own assignment count times the average number of
  /// tags per note — `idx_note_tags_tag` drives both sides of the join — never
  /// the size of the store. Folder-class, document-kind and system tags are
  /// excluded: they are organizational, not subjects (T1).
  func coOccurringTags(
    tagId: TagID,
    limit: Int = NoteService.defaultCoOccurringTagLimit
  ) throws -> [TagCoOccurrence] {
    try requireValidCoOccurringTagLimit(limit)
    return try driver.withDatabase { database in
      _ = try requireTag(id: tagId, in: database)
      return try coOccurringTags(tagId: tagId, limit: limit, in: database)
    }
  }

  /// The single co-occurrence bound, shared by `tagDetail` and the standalone
  /// aggregate so the two entry points can never disagree about what they
  /// accept or about how they word the refusal.
  private func requireValidCoOccurringTagLimit(_ limit: Int) throws {
    guard (0...Self.maximumCoOccurringTagLimit).contains(limit) else {
      throw NoteServiceError.invalidInput(
        "limit must be between 0 and \(Self.maximumCoOccurringTagLimit)"
      )
    }
  }

  /// The note bound as this tag's canonical description, or nil when nothing
  /// is bound or the bound note is unreachable for this principal.
  func canonicalNote(tagId: TagID) throws -> Note? {
    try driver.withDatabase { database in
      _ = try requireTag(id: tagId, in: database)
      return try canonicalNote(tagId: tagId, in: database)
    }
  }

  /// The tag's memo history: every memo anchored to a note carrying the tag
  /// (or a descendant), plus every notebook-level memo of a notebook carrying
  /// it, across all notebooks, newest first. Memos are append-only, so this
  /// chronological aggregate is the history. The tag's own memo notebook is
  /// bound via meta JSON rather than a tag assignment, so its memos never
  /// appear here.
  func listTagComments(
    tagId: TagID,
    limit: Int = 50,
    offset: Int = 0
  ) throws -> [TagAttributedComment] {
    guard (0...200).contains(limit) else {
      throw NoteServiceError.invalidInput("limit must be between 0 and 200")
    }
    guard (0...1_000_000).contains(offset) else {
      throw NoteServiceError.invalidInput("offset must be between 0 and 1000000")
    }
    return try driver.withDatabase { database in
      _ = try requireTag(id: tagId, in: database)
      let expanded = try expandedTagFilterIds([tagId], in: database)
      guard !expanded.isEmpty else { return [] }
      let tagPlaceholders = placeholders(count: expanded.count)
      let tagBindings = expanded.sqliteBindings
      let excludesLongTermMemory = actingUserId != nil || isUnauthenticatedPrincipal
      let reachableLibraryIds = try reachableLibraryIds(in: database)
      if let reachableLibraryIds, reachableLibraryIds.isEmpty {
        return []
      }
      let libraryPredicate = reachableLibraryIds.map {
        " AND nb2.library_id IN (\(placeholders(count: $0.count)))"
      } ?? ""
      let libraryBindings = reachableLibraryIds?.sqliteBindings ?? []
      let longTermMemoryPredicate = excludesLongTermMemory
        ? " AND nb2.notebook_id NOT IN (SELECT notebook_id FROM notebook_tags WHERE tag_id = ?)"
        : ""
      let longTermMemoryBindings: [SQLiteValue] = excludesLongTermMemory
        ? [.id(NoteStoreSchema.longTermMemoryNotebookKindTagId)]
        : []
      let pendingIngestPredicate = allowsPendingNotebookIngestAccess
        ? ""
        : " AND json_extract(nb2.meta_json, '$._kaibaNotebookIngest.state') IS NOT 'pending'"
      var scopedBindings: [SQLiteValue] = tagBindings
      if let actingUserId { scopedBindings.append(.id(actingUserId)) }
      scopedBindings.append(contentsOf: libraryBindings)
      scopedBindings.append(contentsOf: longTermMemoryBindings)
      var bindings = scopedBindings
      bindings.append(contentsOf: scopedBindings)
      bindings.append(.int(Int64(limit)))
      bindings.append(.int(Int64(offset)))
      let rows = try database.query(
        """
        SELECT c.comment_id, c.note_id, c.notebook_id, c.body_markdown, c.author, c.created_at,
          n.title AS note_title, nb.title AS notebook_title
        FROM note_comments c
        LEFT JOIN notes n ON n.note_id = c.note_id
        LEFT JOIN notebooks nb ON nb.notebook_id = c.notebook_id
        WHERE (c.note_id IN (
          SELECT n2.note_id FROM note_tags nt JOIN notes n2 ON n2.note_id = nt.note_id
          JOIN notebooks nb2 ON nb2.notebook_id = n2.notebook_id
          WHERE nt.tag_id IN (\(tagPlaceholders))\(actingUserId.map { _ in " AND nb2.owner_user_id = ?" } ?? "")\(libraryPredicate)\(longTermMemoryPredicate)\(pendingIngestPredicate)
        ))
          OR (c.note_id IS NULL
            AND c.notebook_id IN (
              SELECT nb2.notebook_id FROM notebook_tags nt JOIN notebooks nb2 ON nb2.notebook_id = nt.notebook_id
              WHERE nt.tag_id IN (\(tagPlaceholders))\(actingUserId.map { _ in " AND nb2.owner_user_id = ?" } ?? "")\(libraryPredicate)\(longTermMemoryPredicate)\(pendingIngestPredicate)
            ))
        ORDER BY c.created_at DESC, c.comment_id DESC
        LIMIT ? OFFSET ?
        """,
        bindings: bindings
      )
      return try rows.map { row in
        guard let commentId = row.identifier("comment_id", as: CommentID.self),
          let bodyMarkdown = row["body_markdown"],
          let author = row["author"],
          let createdAt = row["created_at"]
        else {
          throw NoteServiceError.invalidRow("tag comment row is missing required fields")
        }
        return TagAttributedComment(
          comment: NoteComment(
            commentId: commentId,
            noteId: row.identifier("note_id", as: NoteID.self) ?? nil,
            notebookId: row.identifier("notebook_id", as: NotebookID.self) ?? nil,
            bodyMarkdown: bodyMarkdown,
            author: author,
            createdAt: createdAt
          ),
          noteTitle: row["note_title"] ?? nil,
          notebookTitle: row["notebook_title"] ?? nil
        )
      }
    }
  }

  /// Finds or creates the tag's memo notebook (kind `tag-memo`, subject bound
  /// via `kaibaTagMemo.subjectTagId` meta JSON). Lookup and creation share one
  /// database transaction, so concurrent callers observe one notebook and one
  /// set of notebook-created side effects.
  @discardableResult
  func ensureTagMemoNotebook(tagId: TagID) throws -> Notebook {
    let result = try driver.withDatabase { database in
      try database.transaction { db -> TagMemoNotebookCreationResult in
        let tag = try requireTag(id: tagId, in: db)
        let sourceLibraryId = try tagMemoSourceLibraryId(tagId: tagId, in: db)
        if let existingId = try findTagMemoNotebookId(
          tagId: tagId,
          actingUserId: actingUserId,
          excludesPendingNotebookIngests: !allowsPendingNotebookIngestAccess,
          in: db
        ) {
          let existing = try loadNotebook(existingId, in: db)
          // Identity is per owner/tag, not per source library. Rehoming that
          // identity must still require account-level reach to its current
          // library; otherwise a revoked caller could pull a hidden memo into
          // a reachable library merely by moving the tagged source.
          try scoped(toLibrary: nil).requireLibraryReach(
            libraryId: existing.libraryId,
            subject: existingId.rawValue,
            kind: .notebook,
            in: db
          )
          // A memo with no current tagged source retains its established
          // visibility. Only one reachable source library may rehome it;
          // mixed sources are rejected by tagMemoSourceLibraryId above.
          if let sourceLibraryId, existing.libraryId != sourceLibraryId {
            try db.execute(
              "UPDATE notebooks SET library_id = ?, updated_at = ? WHERE notebook_id = ?",
              bindings: [.id(sourceLibraryId), .text(NoteStoreClock.system.now()), .id(existingId)]
            )
            try stampNotebookUpdated(existingId, in: db)
          }
          return TagMemoNotebookCreationResult(
            notebook: try requireNotebook(existingId, in: db), dispatches: [], created: false
          )
        }
        let created = try insertNotebook(
          title: "Tag: \(tag.name)",
          kindTagName: NoteStoreSchema.tagMemoNotebookKindTag,
          metaJSON: try Self.tagMemoNotebookMetaJSON(subjectTagId: tagId),
          libraryId: sourceLibraryId ?? writeLibraryId(),
          originatingActionId: nil,
          in: db
        )
        return TagMemoNotebookCreationResult(
          notebook: created.notebook, dispatches: created.dispatches, created: true
        )
      }
    }
    if result.created {
      dispatchQueuedAutoActions(result.dispatches)
      publishChange(NoteChangeEvent(
        kind: NoteChangeEventKind.notebookCreated,
        notebookId: result.notebook.notebookId
      ))
    }
    return result.notebook
  }

  /// Agent-chat subject context for a tag: the tag identity followed by the
  /// bodies of notes carrying the tag (or a descendant) in notebooks reachable
  /// to this service principal, newest first. Callers may request an explicit
  /// preview limit; agent prompts use the complete context by default.
  func tagContextMarkdown(
    tagId: TagID,
    libraryId: LibraryID? = nil,
    limitBytes: Int? = nil
  ) throws -> String {
    return try driver.withDatabase { database in
      try tagContextMarkdown(
        tagId: tagId,
        libraryId: libraryId,
        limitBytes: limitBytes,
        in: database
      )
    }
  }

  /// Database-scoped form used when an agent reply needs one consistent
  /// subject and library snapshot before handing context to an external
  /// provider.
  func tagContextMarkdown(
    tagId: TagID,
    libraryId: LibraryID? = nil,
    limitBytes: Int? = nil,
    in database: SQLiteDatabase
  ) throws -> String {
    if let libraryId {
      return try scoped(toLibrary: libraryId).tagContextMarkdown(
        tagId: tagId,
        limitBytes: limitBytes,
        in: database
      )
    }
    let tag = try requireTag(id: tagId, in: database)
    var heading = "# Tag: \(tag.name)"
    if let classId = tag.classId {
      heading += " (\(classId))"
    }
    let expanded = try expandedTagFilterIds([tagId], in: database)
    guard !expanded.isEmpty else { return heading }
    var predicates = [
      "notes.note_id IN (SELECT note_id FROM note_tags WHERE tag_id IN (\(placeholders(count: expanded.count))))"
    ]
    var bindings = expanded.sqliteBindings
    appendLibraryScopePredicate(
      alias: "notes",
      reachableLibraryIds: try reachableLibraryIds(in: database),
      predicates: &predicates,
      bindings: &bindings
    )
    appendOwnerScopePredicate(
      alias: "notes",
      actingUserId: actingUserId,
      predicates: &predicates,
      bindings: &bindings
    )
    appendLongTermMemoryExclusionPredicate(
      alias: "notes",
      excludesLongTermMemory: actingUserId != nil || isUnauthenticatedPrincipal,
      predicates: &predicates,
      bindings: &bindings
    )
    appendPendingNotebookIngestExclusionPredicate(
      alias: "notes",
      excludesPendingNotebookIngests: !allowsPendingNotebookIngestAccess,
      predicates: &predicates
    )
    let rows = try database.query(
      """
      SELECT body_markdown
      FROM notes
      WHERE \(predicates.joined(separator: " AND "))
      ORDER BY created_at DESC, note_id
      """,
      bindings: bindings
    )
    guard let limitBytes else {
      return ([heading] + rows.compactMap { $0["body_markdown"] }).joined(separator: "\n\n---\n\n")
    }
    return boundedMarkdownContext(
      heading: heading,
      sections: rows.compactMap { $0["body_markdown"] },
      limitBytes: limitBytes
    )
  }

  /// The subject tag recorded in a tag-memo notebook's meta JSON; nil when the
  /// notebook is not a tag memo notebook.
  func tagMemoSubjectTagId(notebookId: NotebookID) throws -> TagID? {
    try driver.withDatabase { database in
      try tagMemoSubjectTagId(notebookId: notebookId, in: database)
    }
  }

  func tagMemoSubjectTagId(notebookId: NotebookID, in database: SQLiteDatabase) throws -> TagID? {
    _ = try requireNotebook(notebookId, in: database)
    return try database.query(
      """
      SELECT json_extract(meta_json, '$.kaibaTagMemo.subjectTagId') AS subject
      FROM notebooks
      WHERE notebook_id = ?
      LIMIT 1
      """,
      bindings: [.id(notebookId)]
    ).first?.identifier("subject", as: TagID.self)
  }

  internal static func tagMemoNotebookMetaJSON(subjectTagId: TagID) throws -> String {
    let root: JSONValue = .object(["kaibaTagMemo": .object(["subjectTagId": .id(subjectTagId)])])
    do {
      return try root.encodedString()
    } catch {
      throw NoteServiceError.invalidInput("tag memo notebook meta JSON must be UTF-8")
    }
  }
}

extension NoteService {
  /// Refuses the organizational tag classes a canonical description makes no
  /// sense for (E2). Folder tags shape the notebook tree and document-kind
  /// tags mark notebook kinds; neither is a subject.
  func requireCanonicalPromotable(_ tag: Tag) throws {
    guard tag.classId != .folder else {
      throw NoteServiceError.invalidInput(
        "folder tags cannot carry a canonical note: \(tag.name)"
      )
    }
    guard tag.classId != .documentKind else {
      throw NoteServiceError.invalidInput(
        "notebook kind tags cannot carry a canonical note: \(tag.name)"
      )
    }
  }

  /// The raw binding on the tag row, without any reachability check.
  func canonicalNoteId(tagId: TagID, in database: SQLiteDatabase) throws -> NoteID? {
    try database.query(
      "SELECT canonical_note_id FROM tags WHERE tag_id = ? LIMIT 1",
      bindings: [.id(tagId)]
    ).first?.identifier("canonical_note_id", as: NoteID.self)
  }

  func canonicalNote(tagId: TagID, in database: SQLiteDatabase) throws -> Note? {
    guard let noteId = try canonicalNoteId(tagId: tagId, in: database) else {
      return nil
    }
    do {
      return try requireNote(noteId, in: database)
    } catch NoteServiceError.notFound {
      // Tags are store-global while notes are library-scoped, so a binding can
      // outlive this principal's reach to its note. Reporting it as unbound
      // matches how every other read hides an unreachable row.
      return nil
    }
  }

  func coOccurringTags(
    tagId: TagID,
    limit: Int,
    in database: SQLiteDatabase
  ) throws -> [TagCoOccurrence] {
    guard let statement = try coOccurringTagsStatement(
      tagId: tagId,
      limit: limit,
      in: database
    ) else {
      return []
    }
    let rows = try database.query(statement.sql, bindings: statement.bindings)
    return try rows.map { row in
      guard let rawCount = row["note_count"], let noteCount = Int(rawCount) else {
        throw NoteServiceError.invalidRow("co-occurring tag row is missing required fields")
      }
      return TagCoOccurrence(tag: try tag(from: row), noteCount: noteCount)
    }
  }

  /// The co-occurrence query itself, so the query-plan test measures the
  /// statement production runs rather than a copy of it. Nil means the
  /// principal reaches nothing and the query is skipped entirely.
  func coOccurringTagsStatement(
    tagId: TagID,
    limit: Int,
    in database: SQLiteDatabase
  ) throws -> (sql: String, bindings: [SQLiteValue])? {
    guard limit > 0 else { return nil }
    var predicates = ["subject.tag_id = ?", "peer.is_system = 0"]
    // Folder tags and notebook-kind tags are organizational, not subjects, so
    // they never become a co-occurrence chip (T1).
    predicates.append("(peer.class_id IS NULL OR peer.class_id NOT IN (?, ?))")
    var bindings: [SQLiteValue] = [
      .id(tagId),
      .id(TagClassID.folder),
      .id(TagClassID.documentKind)
    ]
    let reachableLibraryIds = try reachableLibraryIds(in: database)
    if let reachableLibraryIds, reachableLibraryIds.isEmpty { return nil }
    appendLibraryScopePredicate(
      alias: "n",
      reachableLibraryIds: reachableLibraryIds,
      predicates: &predicates,
      bindings: &bindings
    )
    appendOwnerScopePredicate(
      alias: "n",
      actingUserId: actingUserId,
      predicates: &predicates,
      bindings: &bindings
    )
    appendLongTermMemoryExclusionPredicate(
      alias: "n",
      excludesLongTermMemory: actingUserId != nil || isUnauthenticatedPrincipal,
      predicates: &predicates,
      bindings: &bindings
    )
    appendPendingNotebookIngestExclusionPredicate(
      alias: "n",
      excludesPendingNotebookIngests: !allowsPendingNotebookIngestAccess,
      predicates: &predicates
    )
    bindings.append(.int(Int64(limit)))
    return (
      """
      SELECT peer.tag_id AS tag_id, peer.name AS name, peer.class_id AS class_id,
        peer.parent_tag_id AS parent_tag_id, peer.is_system AS is_system,
        peer.created_at AS created_at,
        COUNT(DISTINCT shared.note_id) AS note_count
      FROM note_tags subject
      JOIN note_tags shared
        ON shared.note_id = subject.note_id AND shared.tag_id <> subject.tag_id
      JOIN notes n ON n.note_id = subject.note_id
      JOIN tags peer ON peer.tag_id = shared.tag_id
      WHERE \(predicates.joined(separator: " AND "))
      GROUP BY peer.tag_id
      ORDER BY note_count DESC, peer.name, peer.tag_id
      LIMIT ?
      """,
      bindings
    )
  }
}

private extension NoteService {
  /// Returns the sole reachable tagged-source library. `nil` means the tag
  /// currently has no reachable sources, which must not rehome an existing
  /// memo into the caller's write library.
  func tagMemoSourceLibraryId(tagId: TagID, in database: SQLiteDatabase) throws -> LibraryID? {
    let expandedTagIds = try expandedTagFilterIds([tagId], in: database)
    guard !expandedTagIds.isEmpty else {
      return nil
    }
    var notePredicates = ["nt.tag_id IN (\(placeholders(count: expandedTagIds.count)))"]
    var noteBindings = expandedTagIds.sqliteBindings
    appendLibraryScopePredicate(
      alias: "n",
      reachableLibraryIds: try reachableLibraryIds(in: database),
      predicates: &notePredicates,
      bindings: &noteBindings
    )
    appendOwnerScopePredicate(
      alias: "n",
      actingUserId: actingUserId,
      predicates: &notePredicates,
      bindings: &noteBindings
    )
    appendLongTermMemoryExclusionPredicate(
      alias: "n",
      excludesLongTermMemory: actingUserId != nil || isUnauthenticatedPrincipal,
      predicates: &notePredicates,
      bindings: &noteBindings
    )
    appendPendingNotebookIngestExclusionPredicate(
      alias: "n",
      excludesPendingNotebookIngests: !allowsPendingNotebookIngestAccess,
      predicates: &notePredicates
    )
    let noteLibraryIds = try database.query(
      """
      SELECT DISTINCT nb.library_id AS library_id
      FROM note_tags nt
      JOIN notes n ON n.note_id = nt.note_id
      JOIN notebooks nb ON nb.notebook_id = n.notebook_id
      WHERE \(notePredicates.joined(separator: " AND "))
      ORDER BY nb.library_id
      """,
      bindings: noteBindings
    ).compactMap { $0.identifier("library_id", as: LibraryID.self) }
    var notebookPredicates = ["nt.tag_id IN (\(placeholders(count: expandedTagIds.count)))"]
    var notebookBindings = expandedTagIds.sqliteBindings
    appendLibraryScopePredicate(
      alias: "nb",
      reachableLibraryIds: try reachableLibraryIds(in: database),
      predicates: &notebookPredicates,
      bindings: &notebookBindings
    )
    appendOwnerScopePredicate(
      alias: "nb",
      actingUserId: actingUserId,
      predicates: &notebookPredicates,
      bindings: &notebookBindings
    )
    appendLongTermMemoryExclusionPredicate(
      alias: "nb",
      excludesLongTermMemory: actingUserId != nil || isUnauthenticatedPrincipal,
      predicates: &notebookPredicates,
      bindings: &notebookBindings
    )
    appendPendingNotebookIngestExclusionPredicate(
      alias: "nb",
      excludesPendingNotebookIngests: !allowsPendingNotebookIngestAccess,
      predicates: &notebookPredicates
    )
    let notebookLibraryIds = try database.query(
      """
      SELECT DISTINCT nb.library_id AS library_id
      FROM notebook_tags nt
      JOIN notebooks nb ON nb.notebook_id = nt.notebook_id
      WHERE \(notebookPredicates.joined(separator: " AND "))
      ORDER BY nb.library_id
      """,
      bindings: notebookBindings
    ).compactMap { $0.identifier("library_id", as: LibraryID.self) }
    let libraryIds = Set(noteLibraryIds).union(notebookLibraryIds)
    guard libraryIds.count == 1 else {
      if libraryIds.isEmpty {
        return nil
      }
      throw NoteServiceError.invalidInput(
        "tag memo requires a single source library; select one library first"
      )
    }
    return libraryIds.first
  }
}

func findTagMemoNotebookId(
  tagId: TagID,
  actingUserId: UserID? = nil,
  libraryIds: [LibraryID]? = nil,
  excludesPendingNotebookIngests: Bool = false,
  in database: SQLiteDatabase
) throws -> NotebookID? {
  if let libraryIds, libraryIds.isEmpty {
    return nil
  }
  let ownershipPredicate = actingUserId.map { _ in " AND owner_user_id = ?" } ?? ""
  let libraryPredicate = libraryIds.map {
    " AND library_id IN (\(placeholders(count: $0.count)))"
  } ?? ""
  let pendingIngestPredicate = excludesPendingNotebookIngests
    ? " AND json_extract(meta_json, '$._kaibaNotebookIngest.state') IS NOT 'pending'"
    : ""
  return try database.query(
    """
    SELECT notebook_id
    FROM notebooks
    WHERE json_extract(meta_json, '$.kaibaTagMemo.subjectTagId') = ?\(ownershipPredicate)\(libraryPredicate)\(pendingIngestPredicate)
    ORDER BY created_at, notebook_id
    LIMIT 1
    """,
    bindings: [.id(tagId)] + (actingUserId.map { [.id($0)] } ?? [])
      + (libraryIds?.sqliteBindings ?? [])
  ).first?.identifier("notebook_id", as: NotebookID.self)
}

private func taggedEntityCount(
  table: String,
  idColumn: String,
  tagIds: [TagID],
  actingUserId: UserID?,
  reachableLibraryIds: [LibraryID]?,
  excludesLongTermMemory: Bool,
  excludesPendingNotebookIngests: Bool,
  in database: SQLiteDatabase
) throws -> Int {
  guard !tagIds.isEmpty else { return 0 }
  if let reachableLibraryIds, reachableLibraryIds.isEmpty {
    return 0
  }
  let ownershipPredicate: String
  let ownershipBindings: [SQLiteValue]
  if let actingUserId {
    ownershipBindings = [.id(actingUserId)]
    ownershipPredicate = table == "note_tags"
      ? "AND note_id IN (SELECT notes.note_id FROM notes JOIN notebooks ON notebooks.notebook_id = notes.notebook_id WHERE notebooks.owner_user_id = ?)"
      : "AND notebook_id IN (SELECT notebook_id FROM notebooks WHERE owner_user_id = ?)"
  } else {
    ownershipBindings = []
    ownershipPredicate = ""
  }
  let pendingIngestPredicate: String
  if excludesPendingNotebookIngests {
    pendingIngestPredicate = table == "note_tags"
      ? "AND note_id NOT IN (SELECT notes.note_id FROM notes JOIN notebooks ON notebooks.notebook_id = notes.notebook_id WHERE json_extract(notebooks.meta_json, '$._kaibaNotebookIngest.state') = 'pending')"
      : "AND notebook_id NOT IN (SELECT notebook_id FROM notebooks WHERE json_extract(meta_json, '$._kaibaNotebookIngest.state') = 'pending')"
  } else {
    pendingIngestPredicate = ""
  }
  let libraryPredicate: String
  let libraryBindings: [SQLiteValue]
  if let reachableLibraryIds {
    libraryBindings = reachableLibraryIds.sqliteBindings
    libraryPredicate = table == "note_tags"
      ? "AND note_id IN (SELECT notes.note_id FROM notes JOIN notebooks ON notebooks.notebook_id = notes.notebook_id WHERE notebooks.library_id IN (\(placeholders(count: reachableLibraryIds.count))))"
      : "AND notebook_id IN (SELECT notebook_id FROM notebooks WHERE library_id IN (\(placeholders(count: reachableLibraryIds.count))))"
  } else {
    libraryBindings = []
    libraryPredicate = ""
  }
  let longTermMemoryPredicate: String
  let longTermMemoryBindings: [SQLiteValue]
  if excludesLongTermMemory {
    longTermMemoryBindings = [.id(NoteStoreSchema.longTermMemoryNotebookKindTagId)]
    longTermMemoryPredicate = table == "note_tags"
      ? "AND note_id NOT IN (SELECT note_id FROM notes WHERE notebook_id IN (SELECT notebook_id FROM notebook_tags WHERE tag_id = ?))"
      : "AND notebook_id NOT IN (SELECT notebook_id FROM notebook_tags WHERE tag_id = ?)"
  } else {
    longTermMemoryBindings = []
    longTermMemoryPredicate = ""
  }
  let rows = try database.query(
    """
    SELECT COUNT(DISTINCT \(idColumn)) AS entity_count
    FROM \(table)
    WHERE tag_id IN (\(placeholders(count: tagIds.count)))
      \(ownershipPredicate)
      \(libraryPredicate)
      \(longTermMemoryPredicate)
      \(pendingIngestPredicate)
    """,
    bindings: tagIds.sqliteBindings + ownershipBindings + libraryBindings + longTermMemoryBindings
  )
  guard let rawCount = rows.first?["entity_count"], let count = Int(rawCount) else {
    throw NoteServiceError.invalidRow("tag entity count row is missing required fields")
  }
  return count
}
