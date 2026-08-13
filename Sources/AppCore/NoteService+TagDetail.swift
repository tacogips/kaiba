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
  public var memoNotebookId: String?

  public init(
    tag: Tag,
    tagClass: TagClass?,
    noteCount: Int,
    notebookCount: Int,
    memoNotebookId: String?
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

public extension NoteService {
  /// The tag plus its class and cross-notebook aggregate counts. Counts expand
  /// to descendant tags like every tag filter (D16/D17).
  func tagDetail(tagId: String) throws -> TagDetail {
    try driver.withDatabase { database in
      let tag = try requireTag(id: tagId, in: database)
      let tagClass = try tag.classId.map { try requireTagClass(classId: $0, in: database) }
      let expanded = try expandedTagFilterIds([tagId], in: database)
      let noteCount = try taggedEntityCount(
        table: "note_tags",
        idColumn: "note_id",
        tagIds: expanded,
        in: database
      )
      let notebookCount = try taggedEntityCount(
        table: "notebook_tags",
        idColumn: "notebook_id",
        tagIds: expanded,
        in: database
      )
      return TagDetail(
        tag: tag,
        tagClass: tagClass,
        noteCount: noteCount,
        notebookCount: notebookCount,
        memoNotebookId: try findTagMemoNotebookId(tagId: tagId, in: database)
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
    tagId: String,
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
      let tagBindings = expanded.map(SQLiteValue.text)
      let rows = try database.query(
        """
        SELECT c.comment_id, c.note_id, c.notebook_id, c.body_markdown, c.author, c.created_at,
          n.title AS note_title, nb.title AS notebook_title
        FROM note_comments c
        LEFT JOIN notes n ON n.note_id = c.note_id
        LEFT JOIN notebooks nb ON nb.notebook_id = c.notebook_id
        WHERE (c.note_id IN (SELECT note_id FROM note_tags WHERE tag_id IN (\(tagPlaceholders))))
          OR (c.note_id IS NULL
            AND c.notebook_id IN (SELECT notebook_id FROM notebook_tags WHERE tag_id IN (\(tagPlaceholders))))
        ORDER BY c.created_at DESC, c.comment_id DESC
        LIMIT ? OFFSET ?
        """,
        bindings: tagBindings + tagBindings + [.int(Int64(limit)), .int(Int64(offset))]
      )
      return try rows.map { row in
        guard let commentId = row["comment_id"],
          let bodyMarkdown = row["body_markdown"],
          let author = row["author"],
          let createdAt = row["created_at"]
        else {
          throw NoteServiceError.invalidRow("tag comment row is missing required fields")
        }
        return TagAttributedComment(
          comment: NoteComment(
            commentId: commentId,
            noteId: row["note_id"] ?? nil,
            notebookId: row["notebook_id"] ?? nil,
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
  /// via `kaibaTagMemo.subjectTagId` meta JSON). Concurrent creation races
  /// resolve deterministically to the earliest-created notebook.
  @discardableResult
  func ensureTagMemoNotebook(tagId: String) throws -> Notebook {
    let (tag, existingId) = try driver.withDatabase { database -> (Tag, String?) in
      let tag = try requireTag(id: tagId, in: database)
      return (tag, try findTagMemoNotebookId(tagId: tagId, in: database))
    }
    if let existingId {
      return try getNotebook(existingId)
    }
    let created = try createNotebook(
      title: "Tag: \(tag.name)",
      kindTagName: NoteStoreSchema.tagMemoNotebookKindTag,
      metaJSON: Self.tagMemoNotebookMetaJSON(subjectTagId: tagId)
    )
    let resolvedId = try driver.withDatabase { database in
      try findTagMemoNotebookId(tagId: tagId, in: database)
    }
    guard let resolvedId, resolvedId != created.notebookId else {
      return created
    }
    return try getNotebook(resolvedId)
  }

  /// Agent-chat subject context for a tag: the tag identity followed by the
  /// bodies of notes carrying the tag (or a descendant) across all notebooks,
  /// newest first, capped like the notebook subject context.
  func tagContextMarkdown(
    tagId: String,
    limitBytes: Int = 200 * 1024
  ) throws -> String {
    try driver.withDatabase { database in
      let tag = try requireTag(id: tagId, in: database)
      var heading = "# Tag: \(tag.name)"
      if let classId = tag.classId {
        heading += " (\(classId))"
      }
      let expanded = try expandedTagFilterIds([tagId], in: database)
      guard !expanded.isEmpty else { return heading }
      let rows = try database.query(
        """
        SELECT body_markdown
        FROM notes
        WHERE note_id IN (SELECT note_id FROM note_tags WHERE tag_id IN (\(placeholders(count: expanded.count))))
        ORDER BY created_at DESC, note_id
        LIMIT 50
        """,
        bindings: expanded.map(SQLiteValue.text)
      )
      var sections = [heading]
      var budget = limitBytes
      for row in rows {
        guard budget > 0 else { break }
        guard let markdown = row["body_markdown"] else { continue }
        let body = String(markdown.prefix(budget))
        budget -= body.utf8.count
        sections.append(body)
      }
      return sections.joined(separator: "\n\n---\n\n")
    }
  }

  /// The subject tag recorded in a tag-memo notebook's meta JSON; nil when the
  /// notebook is not a tag memo notebook.
  func tagMemoSubjectTagId(notebookId: String) throws -> String? {
    try driver.withDatabase { database in
      try database.query(
        """
        SELECT json_extract(meta_json, '$.kaibaTagMemo.subjectTagId') AS subject
        FROM notebooks
        WHERE notebook_id = ?
        LIMIT 1
        """,
        bindings: [.text(notebookId)]
      ).first?["subject"] ?? nil
    }
  }

  internal static func tagMemoNotebookMetaJSON(subjectTagId: String) throws -> String {
    let data = try JSONSerialization.data(
      withJSONObject: ["kaibaTagMemo": ["subjectTagId": subjectTagId]],
      options: [.sortedKeys]
    )
    guard let json = String(data: data, encoding: .utf8) else {
      throw NoteServiceError.invalidInput("tag memo notebook meta JSON must be UTF-8")
    }
    return json
  }
}

func findTagMemoNotebookId(tagId: String, in database: SQLiteDatabase) throws -> String? {
  try database.query(
    """
    SELECT notebook_id
    FROM notebooks
    WHERE json_extract(meta_json, '$.kaibaTagMemo.subjectTagId') = ?
    ORDER BY created_at, notebook_id
    LIMIT 1
    """,
    bindings: [.text(tagId)]
  ).first?["notebook_id"] ?? nil
}

private func taggedEntityCount(
  table: String,
  idColumn: String,
  tagIds: [String],
  in database: SQLiteDatabase
) throws -> Int {
  guard !tagIds.isEmpty else { return 0 }
  let rows = try database.query(
    """
    SELECT COUNT(DISTINCT \(idColumn)) AS entity_count
    FROM \(table)
    WHERE tag_id IN (\(placeholders(count: tagIds.count)))
    """,
    bindings: tagIds.map(SQLiteValue.text)
  )
  guard let rawCount = rows.first?["entity_count"], let count = Int(rawCount) else {
    throw NoteServiceError.invalidRow("tag entity count row is missing required fields")
  }
  return count
}
