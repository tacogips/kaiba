import Foundation

func ontologyExpansionTagIds(query: String, in database: SQLiteDatabase) throws -> [TagID] {
  let normalizedQuery = normalizedOntologyText(query)
  guard !normalizedQuery.isEmpty else { return [] }
  let rows = try database.query("SELECT tag_id, name FROM tags WHERE is_system = 0")
  let matches = rows.compactMap { row -> (TagID, String)? in
    guard let tagId = row.identifier("tag_id", as: TagID.self),
          let name = row["name"] else { return nil }
    let normalizedName = normalizedOntologyText(name)
    guard normalizedName.count >= 2,
          containsOntologyName(normalizedName, in: normalizedQuery) else { return nil }
    return (tagId, normalizedName)
  }
  return matches
    .sorted { lhs, rhs in
      lhs.1.count == rhs.1.count ? lhs.0 < rhs.0 : lhs.1.count > rhs.1.count
    }
    .prefix(10)
    .map(\.0)
}

func resolveTagClassFilters(
  _ entries: [String],
  in database: SQLiteDatabase
) throws -> [SearchEngineTagClassFilter]? {
  guard entries.count <= 10 else {
    throw NoteServiceError.invalidInput("tagClassFilter allows at most 10 entries")
  }
  var filters: [SearchEngineTagClassFilter] = []
  for entry in orderedUnique(entries) {
    let parts = entry.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    let classId = String(parts[0])
    guard !classId.isEmpty,
          try database.query("SELECT 1 FROM tag_classes WHERE class_id = ? LIMIT 1", bindings: [.text(classId)]).isEmpty == false else {
      return nil
    }
    if parts.count == 1 {
      filters.append(SearchEngineTagClassFilter(tagClass: classId))
      continue
    }
    let name = String(parts[1])
    guard !name.isEmpty,
          let resolved = try resolveTagIds(named: [name], in: database),
          let tagId = resolved.first else { return nil }
    let rows = try database.query(
      "SELECT class_id FROM tags WHERE tag_id = ? LIMIT 1",
      bindings: [.id(tagId)]
    )
    guard rows.first?.string("class_id") == classId else { return nil }
    filters.append(SearchEngineTagClassFilter(tagClass: classId, tagId: tagId))
  }
  return filters
}

func relatedSignals(forSourceNoteId noteId: NoteID, in database: SQLiteDatabase) throws -> SearchEngineRelatedSignals {
  let directRows = try database.query(
    """
    SELECT t.tag_id, parent.tag_id AS parent_tag_id, t.class_id
    FROM note_tags nt
    INNER JOIN tags t ON t.tag_id = nt.tag_id
    LEFT JOIN tags parent ON parent.tag_id = t.parent_tag_id AND parent.is_system = 0
    WHERE nt.note_id = ? AND t.is_system = 0
    ORDER BY t.tag_id
    """,
    bindings: [.id(noteId)]
  )
  let directIds = directRows.compactMap { $0.identifier("tag_id", as: TagID.self) }
  let sharedTagIds = Array(directIds.prefix(50))
  let sharedTagSet = Set(sharedTagIds)
  let sharedRows = directRows.filter { row in
    guard let tagId = row.identifier("tag_id", as: TagID.self) else { return false }
    return sharedTagSet.contains(tagId)
  }
  let nearTagIds = Array(orderedUnique(
    sharedTagIds + sharedRows.compactMap { $0.identifier("parent_tag_id", as: TagID.self) }
  ).sorted().prefix(50))
  let ancestors = try database.query(
    """
    WITH RECURSIVE ancestors(tag_id, parent_tag_id, depth) AS (
      SELECT t.tag_id, t.parent_tag_id, 1
      FROM note_tags nt
      INNER JOIN tags t ON t.tag_id = nt.tag_id
      WHERE nt.note_id = ? AND t.is_system = 0
      UNION ALL
      SELECT parent.tag_id, parent.parent_tag_id, child.depth + 1
      FROM ancestors child
      INNER JOIN tags parent ON parent.tag_id = child.parent_tag_id
      WHERE child.depth < 64 AND parent.is_system = 0
    )
    SELECT DISTINCT tag_id FROM ancestors
    WHERE tag_id NOT IN (SELECT tag_id FROM note_tags WHERE note_id = ?)
    ORDER BY tag_id
    LIMIT 50
    """,
    bindings: [.id(noteId), .id(noteId)]
  ).compactMap { $0.identifier("tag_id", as: TagID.self) }
  let entityTags = Array(sharedRows.compactMap { row -> SearchEngineClassTag? in
    guard let classId = row["class_id"], classId == "person" || classId == "event",
          let tagId = row.identifier("tag_id", as: TagID.self) else { return nil }
    return SearchEngineClassTag(tagClass: classId, tagId: tagId)
  }.sorted { $0.tagId < $1.tagId }.prefix(50))
  return SearchEngineRelatedSignals(
    sourceNoteId: noteId,
    sharedTagIds: sharedTagIds,
    nearTagIds: nearTagIds,
    ancestorTagIds: ancestors,
    entityTags: entityTags
  )
}

func hydrateEngineFacets(
  _ facets: SearchEngineFacets,
  in database: SQLiteDatabase
) throws -> NoteEngineSearchFacets {
  let tagIds = orderedUnique(facets.tags.compactMap { TagID($0.value) })
  let knownTags: [TagID: (String, String?)]
  if tagIds.isEmpty {
    knownTags = [:]
  } else {
    let rows = try database.query(
      "SELECT tag_id, name, class_id FROM tags WHERE is_system = 0 AND tag_id IN (\(placeholders(count: tagIds.count)))",
      bindings: tagIds.sqliteBindings
    )
    knownTags = Dictionary(uniqueKeysWithValues: rows.compactMap { row in
      guard let tagId = row.identifier("tag_id", as: TagID.self), let name = row["name"] else { return nil }
      return (tagId, (name, row["class_id"]))
    })
  }
  let hydratedTags = facets.tags.compactMap { bucket -> NoteEngineTagFacet? in
    let tagId = TagID(bucket.value)
    guard let (name, tagClass) = knownTags[tagId] else { return nil }
    return NoteEngineTagFacet(tagId: tagId, name: name, tagClass: tagClass, count: bucket.count)
  }
  return NoteEngineSearchFacets(tagClasses: facets.tagClasses, tags: hydratedTags)
}

func enrichRelatedReasons(
  _ hits: [SearchEngineHit],
  sourceSharedTagIds: [TagID],
  in database: SQLiteDatabase
) throws -> [SearchEngineHit] {
  guard !hits.isEmpty, !sourceSharedTagIds.isEmpty else {
    return hits.map { hit in
      var copy = hit
      copy.reasons.removeAll { $0.kind == .sharedTag || $0.kind == .sharedEntity }
      return copy
    }
  }
  let noteIds = orderedUnique(hits.map(\.noteId))
  let tagIds = orderedUnique(sourceSharedTagIds)
  let rows = try database.query(
    """
    SELECT nt.note_id, t.name
    FROM note_tags nt
    INNER JOIN tags t ON t.tag_id = nt.tag_id
    WHERE nt.note_id IN (\(placeholders(count: noteIds.count)))
      AND t.tag_id IN (\(placeholders(count: tagIds.count)))
      AND t.is_system = 0
    ORDER BY nt.note_id, t.name
    """,
    bindings: noteIds.sqliteBindings + tagIds.sqliteBindings
  )
  var namesByNote: [NoteID: [String]] = [:]
  for row in rows {
    guard let noteId = row.identifier("note_id", as: NoteID.self), let name = row["name"] else { continue }
    namesByNote[noteId, default: []].append(name)
  }
  return hits.map { hit in
    var copy = hit
    let names = Array(orderedUnique(namesByNote[hit.noteId] ?? []).sorted().prefix(5))
    copy.reasons = hit.reasons.compactMap { reason in
      guard reason.kind == .sharedTag || reason.kind == .sharedEntity else { return reason }
      guard !names.isEmpty else { return nil }
      return SearchEngineHitReason(kind: reason.kind, tagNames: names)
    }
    return copy
  }
}

private func normalizedOntologyText(_ value: String) -> String {
  value.lowercased()
    .split(whereSeparator: \.isWhitespace)
    .map(String.init)
    .joined(separator: " ")
}

private func containsOntologyName(_ name: String, in query: String) -> Bool {
  var searchStart = query.startIndex
  while let range = query.range(of: name, range: searchStart..<query.endIndex) {
    let startsWithASCIIWord = name.first.map(isASCIIAlphanumeric) ?? false
    let endsWithASCIIWord = name.last.map(isASCIIAlphanumeric) ?? false
    let hasLeadingBoundary = !startsWithASCIIWord || range.lowerBound == query.startIndex
      || !isASCIIAlphanumeric(query[query.index(before: range.lowerBound)])
    let hasTrailingBoundary = !endsWithASCIIWord || range.upperBound == query.endIndex
      || !isASCIIAlphanumeric(query[range.upperBound])
    if hasLeadingBoundary && hasTrailingBoundary { return true }
    searchStart = range.upperBound
  }
  return false
}

private func isASCIIAlphanumeric(_ character: Character) -> Bool {
  guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return false }
  return (65...90).contains(scalar.value) || (97...122).contains(scalar.value) || (48...57).contains(scalar.value)
}
