func expandedTagFilterIds(
  _ tagIds: [String],
  in database: SQLiteDatabase
) throws -> [String] {
  let roots = orderedUnique(tagIds)
  guard !roots.isEmpty else { return [] }
  let existingRoots = try database.query(
    "SELECT tag_id FROM tags WHERE tag_id IN (\(placeholders(count: roots.count)))",
    bindings: roots.map(SQLiteValue.text)
  ).compactMap { $0["tag_id"] }
  guard existingRoots.count == roots.count else { return [] }
  return try database.query(
    """
    WITH RECURSIVE descendant_tags(tag_id) AS (
      SELECT tag_id
      FROM tags
      WHERE tag_id IN (\(placeholders(count: roots.count)))
      UNION
      SELECT child.tag_id
      FROM tags child
      INNER JOIN descendant_tags parent ON child.parent_tag_id = parent.tag_id
    )
    SELECT tag_id FROM descendant_tags ORDER BY tag_id
    """,
    bindings: roots.map(SQLiteValue.text)
  ).compactMap { $0["tag_id"] }
}

func expandedLegacyTagFilterIds(
  _ names: [String],
  in database: SQLiteDatabase
) throws -> [String] {
  var roots: [String] = []
  for name in orderedUnique(names) {
    guard let tag = try findTag(name: name, in: database) else { return [] }
    roots.append(tag.tagId)
  }
  return try expandedTagFilterIds(roots, in: database)
}

func canonicalTagFilterGroups(
  _ groups: [[String]],
  discardingEmpty: Bool
) -> [[String]] {
  var canonical: [[String]] = []
  for group in groups {
    let normalized = orderedUnique(group).sorted()
    if normalized.isEmpty, discardingEmpty { continue }
    if !canonical.contains(normalized) { canonical.append(normalized) }
  }
  return canonical
}

func validateTagParent(
  childTagId: String,
  parentTagId: String,
  in database: SQLiteDatabase
) throws {
  guard childTagId != parentTagId else {
    throw NoteServiceError.invalidInput("a tag cannot be its own parent")
  }
  let parentRows = try database.query(
    "SELECT tag_id FROM tags WHERE tag_id = ? LIMIT 1",
    bindings: [.text(parentTagId)]
  )
  guard !parentRows.isEmpty else {
    throw NoteServiceError.notFound("parent tag not found: \(parentTagId)")
  }
  let cycleRows = try database.query(
    """
    WITH RECURSIVE ancestors(tag_id, parent_tag_id) AS (
      SELECT tag_id, parent_tag_id
      FROM tags
      WHERE tag_id = ?
      UNION
      SELECT parent.tag_id, parent.parent_tag_id
      FROM tags parent
      INNER JOIN ancestors child
        ON parent.tag_id = child.parent_tag_id
    )
    SELECT tag_id
    FROM ancestors
    WHERE tag_id = ?
    LIMIT 1
    """,
    bindings: [.text(parentTagId), .text(childTagId)]
  )
  guard cycleRows.isEmpty else {
    throw NoteServiceError.invalidInput("tag parent would create a cycle")
  }
}
