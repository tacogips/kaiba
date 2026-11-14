import Foundation

/// Bookkeeping for the contentless `note_fts` index. Every note write re-derives
/// its row from `notes`, `notebooks`, and the tag tree so the index always
/// mirrors the store; the `context` column carries the contextual breadcrumb
/// from `design-docs/specs/note-retrieval-fusion.md` (RF1).
func refreshFTS(noteId: NoteID, previous: FTSPayload?, in database: SQLiteDatabase) throws {
  if let previous {
    try deleteFTSEntry(previous, in: database)
    try database.execute("DELETE FROM note_fts_map WHERE note_id = ?", bindings: [.id(noteId)])
  }

  let payload = try currentFTSPayload(noteId: noteId, rowId: previous?.rowId, in: database)
  try database.execute(
    "INSERT INTO note_fts(rowid, title, body, tags, context) VALUES (?, ?, ?, ?, ?)",
    bindings: [
      .int(payload.rowId),
      .text(payload.title),
      .text(payload.body),
      .text(payload.tags),
      .text(payload.context)
    ]
  )
  try database.execute(
    """
    INSERT INTO note_fts_map (fts_rowid, note_id, context)
    VALUES (?, ?, ?)
    ON CONFLICT(note_id) DO UPDATE SET fts_rowid = excluded.fts_rowid, context = excluded.context
    """,
    bindings: [.int(payload.rowId), .id(noteId), .text(payload.context)]
  )
}

/// Removes one indexed row. A contentless FTS5 table only accepts a 'delete'
/// that repeats the exact column values that were inserted, so the caller
/// must pass the payload read through `ftsPayload` before the note changed.
func deleteFTSEntry(_ previous: FTSPayload, in database: SQLiteDatabase) throws {
  try database.execute(
    """
    INSERT INTO note_fts(note_fts, rowid, title, body, tags, context)
    VALUES('delete', ?, ?, ?, ?, ?)
    """,
    bindings: [
      .int(previous.rowId),
      .text(previous.title),
      .text(previous.body),
      .text(previous.tags),
      .text(previous.context)
    ]
  )
}

/// The payload currently held in the index for a note, or nil when the note
/// is not indexed. Title, body, and direct tag names are re-read from the
/// store (they cannot change without a refresh); the context column is read
/// back from `note_fts_map` because tag ancestry can change under a note.
func ftsPayload(noteId: NoteID, in database: SQLiteDatabase) throws -> FTSPayload? {
  let rows = try database.query(
    """
    SELECT m.fts_rowid, m.context, n.title, n.body_markdown, ifnull((
        SELECT group_concat(ordered_tags.name, ' ')
        FROM (
          SELECT t.name
          FROM note_tags nt
          INNER JOIN tags t ON t.tag_id = nt.tag_id
          WHERE nt.note_id = n.note_id
          ORDER BY t.name
        ) ordered_tags
      ), '') AS tags
    FROM note_fts_map m
    INNER JOIN notes n ON n.note_id = m.note_id
    WHERE m.note_id = ?
    LIMIT 1
    """,
    bindings: [.id(noteId)]
  )
  guard let row = rows.first, let rowIdText = row["fts_rowid"], let rowId = Int64(rowIdText) else {
    return nil
  }
  return FTSPayload(
    rowId: rowId,
    title: row["title"] ?? "",
    body: row["body_markdown"] ?? "",
    tags: row["tags"] ?? "",
    context: row["context"] ?? ""
  )
}

/// Re-indexes every note carrying `tagId` or one of its descendants. Used when
/// a tag is reparented, which changes the ancestry those notes index.
func refreshFTSForNotesUnderTag(_ tagId: TagID, in database: SQLiteDatabase) throws {
  let descendantTagIds = try expandedTagFilterIds([tagId], in: database)
  guard !descendantTagIds.isEmpty else {
    return
  }
  let noteIds = try database.query(
    """
    SELECT DISTINCT note_id
    FROM note_tags
    WHERE tag_id IN (\(placeholders(count: descendantTagIds.count)))
    ORDER BY note_id
    """,
    bindings: descendantTagIds.sqliteBindings
  ).compactMap { $0.identifier("note_id", as: NoteID.self) }
  for noteId in noteIds {
    let previous = try ftsPayload(noteId: noteId, in: database)
    try refreshFTS(noteId: noteId, previous: previous, in: database)
  }
}

/// The contextual breadcrumb for a note: its notebook title followed by the
/// names of every ancestor of every tag it carries, deduplicated and sorted so
/// the payload is stable. Structural `notebook-kind:*` and system tags are
/// skipped, matching the graph traversal's notion of a content tag.
func ftsContextPayload(noteId: NoteID, in database: SQLiteDatabase) throws -> String {
  let notebookTitle = try database.query(
    """
    SELECT nb.title
    FROM notes n
    INNER JOIN notebooks nb ON nb.notebook_id = n.notebook_id
    WHERE n.note_id = ?
    LIMIT 1
    """,
    bindings: [.id(noteId)]
  ).first?["title"] ?? ""
  let ancestorNames = try database.query(
    """
    WITH RECURSIVE note_tag_ancestors(tag_id) AS (
      SELECT t.parent_tag_id
      FROM note_tags nt
      INNER JOIN tags t ON t.tag_id = nt.tag_id
      WHERE nt.note_id = ? AND t.parent_tag_id IS NOT NULL
      UNION
      SELECT parent.parent_tag_id
      FROM tags parent
      INNER JOIN note_tag_ancestors child ON parent.tag_id = child.tag_id
      WHERE parent.parent_tag_id IS NOT NULL
    )
    SELECT DISTINCT t.name
    FROM tags t
    INNER JOIN note_tag_ancestors a ON a.tag_id = t.tag_id
    WHERE t.is_system = 0 AND t.name NOT LIKE 'notebook-kind:%'
    ORDER BY t.name
    """,
    bindings: [.id(noteId)]
  ).compactMap { $0["name"] }
  var parts: [String] = []
  let trimmedTitle = notebookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
  if !trimmedTitle.isEmpty {
    parts.append(trimmedTitle)
  }
  parts.append(contentsOf: ancestorNames)
  return parts.joined(separator: " ")
}

private func currentFTSPayload(noteId: NoteID, rowId: Int64?, in database: SQLiteDatabase) throws -> FTSPayload {
  // Internal FTS bookkeeping for a note the caller just wrote.
  let note = try loadNote(noteId, in: database)
  let ftsRowId: Int64
  if let rowId {
    ftsRowId = rowId
  } else {
    ftsRowId = try nextFTSRowId(in: database)
  }
  return FTSPayload(
    rowId: ftsRowId,
    title: note.title ?? "",
    body: note.bodyMarkdown,
    tags: note.tags.map(\.tag.name).joined(separator: " "),
    context: try ftsContextPayload(noteId: noteId, in: database)
  )
}

private func nextFTSRowId(in database: SQLiteDatabase) throws -> Int64 {
  let rows = try database.query("SELECT ifnull(max(fts_rowid), 0) + 1 AS next_rowid FROM note_fts_map")
  return Int64(rows.first?["next_rowid"] ?? "") ?? 1
}
