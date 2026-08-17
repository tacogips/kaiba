func expandedTagFilterIds(
  _ tagIds: [TagID],
  in database: SQLiteDatabase
) throws -> [TagID] {
  let roots = orderedUnique(tagIds)
  guard !roots.isEmpty else { return [] }
  let existingRoots = try database.query(
    "SELECT tag_id FROM tags WHERE tag_id IN (\(placeholders(count: roots.count)))",
    bindings: roots.sqliteBindings
  ).compactMap { $0.identifier("tag_id", as: TagID.self) }
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
    bindings: roots.sqliteBindings
  ).compactMap { $0.identifier("tag_id", as: TagID.self) }
}

func expandedLegacyTagFilterIds(
  _ names: [String],
  in database: SQLiteDatabase
) throws -> [TagID] {
  var roots: [TagID] = []
  for name in orderedUnique(names) {
    guard let tag = try findTag(name: name, in: database) else { return [] }
    roots.append(tag.tagId)
  }
  return try expandedTagFilterIds(roots, in: database)
}

func canonicalTagFilterGroups<Element: Hashable & Comparable>(
  _ groups: [[Element]],
  discardingEmpty: Bool
) -> [[Element]] {
  var canonical: [[Element]] = []
  for group in groups {
    let normalized = orderedUnique(group).sorted()
    if normalized.isEmpty, discardingEmpty { continue }
    if !canonical.contains(normalized) { canonical.append(normalized) }
  }
  return canonical
}

func validateTagParent(
  childTagId: TagID,
  parentTagId: TagID,
  in database: SQLiteDatabase
) throws {
  guard childTagId != parentTagId else {
    throw NoteServiceError.invalidInput("a tag cannot be its own parent")
  }
  let parentRows = try database.query(
    "SELECT tag_id FROM tags WHERE tag_id = ? LIMIT 1",
    bindings: [.id(parentTagId)]
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
    bindings: [.id(parentTagId), .id(childTagId)]
  )
  guard cycleRows.isEmpty else {
    throw NoteServiceError.invalidInput("tag parent would create a cycle")
  }
}
