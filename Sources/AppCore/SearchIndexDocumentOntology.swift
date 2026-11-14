import Foundation

func searchIndexTagApplications(noteId: NoteID, in database: SQLiteDatabase) throws -> [SearchIndexTagApplication] {
  try database.query(
    "SELECT tag_id, provenance FROM note_tags WHERE note_id = ? ORDER BY tag_id",
    bindings: [.id(noteId)]
  ).compactMap { row in
    guard let tagId = row.identifier("tag_id", as: TagID.self),
          let provenance = row["provenance"] else { return nil }
    return SearchIndexTagApplication(tagId: tagId, provenance: provenance)
  }
}

func searchIndexPathTags(directTagIds: [TagID], in database: SQLiteDatabase) throws -> [SearchIndexPathTag] {
  guard !directTagIds.isEmpty else { return [] }
  let placeholders = Array(repeating: "?", count: directTagIds.count).joined(separator: ", ")
  let rows = try database.query(
    """
    WITH RECURSIVE tag_path(tag_id, depth) AS (
      SELECT tag_id, 0 FROM tags WHERE tag_id IN (\(placeholders))
      UNION
      SELECT tags.parent_tag_id, tag_path.depth + 1
      FROM tags
      JOIN tag_path ON tags.tag_id = tag_path.tag_id
      WHERE tags.parent_tag_id IS NOT NULL AND tag_path.depth < 64
    )
    SELECT DISTINCT tags.tag_id, tags.name, tags.class_id
    FROM tag_path
    JOIN tags ON tags.tag_id = tag_path.tag_id
    ORDER BY tags.tag_id
    """,
    bindings: directTagIds.map(SQLiteValue.id)
  )
  let directIds = Set(directTagIds)
  return rows.compactMap { row in
    guard let tagId = row.identifier("tag_id", as: TagID.self),
          let name = row["name"] else { return nil }
    return SearchIndexPathTag(
      tagId: tagId,
      name: name,
      tagClass: row["class_id"],
      isDirect: directIds.contains(tagId)
    )
  }
}

func searchIndexLinkedNoteIds(
  noteId: NoteID,
  in database: SQLiteDatabase
) throws -> (outgoing: [NoteID], incoming: [NoteID]) {
  let outgoing = try database.query(
    """
    SELECT DISTINCT to_note_id FROM note_links
    WHERE from_note_id = ? AND to_note_id <> ?
    ORDER BY to_note_id LIMIT 500
    """,
    bindings: [.id(noteId), .id(noteId)]
  ).compactMap { $0.identifier("to_note_id", as: NoteID.self) }
  let incoming = try database.query(
    """
    SELECT DISTINCT from_note_id FROM note_links
    WHERE to_note_id = ? AND from_note_id <> ?
    ORDER BY from_note_id LIMIT 500
    """,
    bindings: [.id(noteId), .id(noteId)]
  ).compactMap { $0.identifier("from_note_id", as: NoteID.self) }
  return (outgoing, incoming)
}
