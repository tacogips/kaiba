import Foundation

/// Explain the same ancestor/path-tag match used by the engine, using current
/// store data rather than trusting an engine's stale tag labels.
func relatedTagEvidence(
  noteIds: [NoteID], nearTagIds: [TagID], ancestorTagIds: [TagID], in database: SQLiteDatabase
) throws -> [NoteID: [String]] {
  guard !noteIds.isEmpty, !nearTagIds.isEmpty || !ancestorTagIds.isEmpty else { return [:] }
  let near = nearTagIds.isEmpty ? "NULL" : placeholders(count: nearTagIds.count)
  let ancestors = ancestorTagIds.isEmpty ? "NULL" : placeholders(count: ancestorTagIds.count)
  let rows = try database.query(
    """
    WITH RECURSIVE paths(note_id, leaf_tag_id, tag_id, parent_tag_id, depth) AS (
      SELECT nt.note_id, t.tag_id, t.tag_id, t.parent_tag_id, 0
      FROM note_tags nt JOIN tags t ON t.tag_id = nt.tag_id
      WHERE nt.note_id IN (\(placeholders(count: noteIds.count))) AND t.is_system = 0
      UNION ALL
      SELECT path.note_id, path.leaf_tag_id, parent.tag_id, parent.parent_tag_id, path.depth + 1
      FROM paths path JOIN tags parent ON parent.tag_id = path.parent_tag_id
      WHERE path.depth < 64 AND parent.is_system = 0
    )
    SELECT DISTINCT path.note_id, leaf.name AS leaf_name, via.name AS via_name
    FROM paths path JOIN tags leaf ON leaf.tag_id = path.leaf_tag_id JOIN tags via ON via.tag_id = path.tag_id
    WHERE path.tag_id IN (\(near)) OR (path.depth = 0 AND path.tag_id IN (\(ancestors)))
    ORDER BY path.note_id, leaf.name, via.name
    """, bindings: noteIds.sqliteBindings + nearTagIds.sqliteBindings + ancestorTagIds.sqliteBindings
  )
  var result: [NoteID: [String]] = [:]
  for row in rows {
    guard let id = row.identifier("note_id", as: NoteID.self), let leaf = row["leaf_name"], let via = row["via_name"] else { continue }
    result[id, default: []].append(leaf == via ? leaf : "\(leaf) (via \(via))")
  }
  return result
}
