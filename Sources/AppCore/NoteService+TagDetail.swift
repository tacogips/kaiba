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

  public init(
    tag: Tag,
    tagClass: TagClass?,
    noteCount: Int,
    notebookCount: Int,
    memoNotebookId: NotebookID?
  ) {
    self.tag = tag
    self.tagClass = tagClass
    self.noteCount = noteCount
    self.notebookCount = notebookCount
    self.memoNotebookId = memoNotebookId
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
  /// The tag plus its class and cross-notebook aggregate counts. Counts expand
  /// to descendant tags like every tag filter (D16/D17).
  func tagDetail(tagId: TagID) throws -> TagDetail {
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
        in: database
      )
      let notebookCount = try taggedEntityCount(
        table: "notebook_tags",
        idColumn: "notebook_id",
        tagIds: expanded,
        actingUserId: actingUserId,
        reachableLibraryIds: reachableLibraryIds,
        excludesLongTermMemory: actingUserId != nil || isUnauthenticatedPrincipal,
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
          in: database
        )
      )
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
          WHERE nt.tag_id IN (\(tagPlaceholders))\(actingUserId.map { _ in " AND nb2.owner_user_id = ?" } ?? "")\(libraryPredicate)\(longTermMemoryPredicate)
        ))
          OR (c.note_id IS NULL
            AND c.notebook_id IN (
              SELECT nb2.notebook_id FROM notebook_tags nt JOIN notebooks nb2 ON nb2.notebook_id = nt.notebook_id
              WHERE nt.tag_id IN (\(tagPlaceholders))\(actingUserId.map { _ in " AND nb2.owner_user_id = ?" } ?? "")\(libraryPredicate)\(longTermMemoryPredicate)
            ))
        ORDER BY c.created_at DESC, c.comment_id DESC
        LIMIT ? OFFSET ?
        """,
        bindings: tagBindings + (actingUserId.map { [.id($0)] } ?? []) + libraryBindings + longTermMemoryBindings
          + tagBindings + (actingUserId.map { [.id($0)] } ?? []) + libraryBindings + longTermMemoryBindings
          + [.int(Int64(limit)), .int(Int64(offset))]
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
  /// to this service principal, newest first, capped like the notebook subject
  /// context.
  func tagContextMarkdown(
    tagId: TagID,
    libraryId: LibraryID? = nil,
    limitBytes: Int = 200 * 1024
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
    limitBytes: Int = 200 * 1024,
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
    let rows = try database.query(
      """
      SELECT body_markdown
      FROM notes
      WHERE \(predicates.joined(separator: " AND "))
      ORDER BY created_at DESC, note_id
      LIMIT 50
      """,
      bindings: bindings
    )
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
  in database: SQLiteDatabase
) throws -> NotebookID? {
  if let libraryIds, libraryIds.isEmpty {
    return nil
  }
  let ownershipPredicate = actingUserId.map { _ in " AND owner_user_id = ?" } ?? ""
  let libraryPredicate = libraryIds.map {
    " AND library_id IN (\(placeholders(count: $0.count)))"
  } ?? ""
  return try database.query(
    """
    SELECT notebook_id
    FROM notebooks
    WHERE json_extract(meta_json, '$.kaibaTagMemo.subjectTagId') = ?\(ownershipPredicate)\(libraryPredicate)
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
    """,
    bindings: tagIds.sqliteBindings + ownershipBindings + libraryBindings + longTermMemoryBindings
  )
  guard let rawCount = rows.first?["entity_count"], let count = Int(rawCount) else {
    throw NoteServiceError.invalidRow("tag entity count row is missing required fields")
  }
  return count
}
