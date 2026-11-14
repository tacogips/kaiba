public struct KanbanStatusUpsert: Equatable, Sendable {
  public var statusId: String?
  public var name: String
  public var category: KanbanStatusCategory

  public init(statusId: String? = nil, name: String, category: KanbanStatusCategory) {
    self.statusId = statusId
    self.name = name
    self.category = category
  }
}

public struct KanbanBoardColumn: Equatable, Sendable {
  public var status: KanbanStatus
  public var notebooks: [Notebook]

  public init(status: KanbanStatus, notebooks: [Notebook]) {
    self.status = status
    self.notebooks = notebooks
  }
}

extension NoteService {
  public func listKanbanStatusSets() throws -> [KanbanStatusSet] {
    try driver.withDatabase { database in
      try kanbanStatusSets(in: database)
    }
  }

  @discardableResult
  public func createKanbanStatusSet(
    name: String,
    statuses: [KanbanStatusUpsert]
  ) throws -> KanbanStatusSet {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      throw NoteServiceError.invalidInput("kanban status set name must not be empty")
    }
    try validateStatusList(statuses)
    let created = try driver.withDatabase { database in
      try database.transaction { db in
        let setId = "kanban-set-" + stableKanbanIdentifier(trimmedName)
        let existing = try db.query(
          "SELECT set_id FROM kanban_status_sets WHERE set_id = ? OR name = ? LIMIT 1",
          bindings: [.text(setId), .text(trimmedName)]
        )
        guard existing.isEmpty else {
          throw NoteServiceError.invalidInput("kanban status set already exists: \(trimmedName)")
        }
        let now = NoteStoreClock.system.now()
        try db.execute(
          """
          INSERT INTO kanban_status_sets (set_id, name, is_system, created_at, updated_at)
          VALUES (?, ?, 0, ?, ?)
          """,
          bindings: [.text(setId), .text(trimmedName), .text(now), .text(now)]
        )
        try insertStatuses(statuses, setId: setId, now: now, in: db)
        guard let created = try kanbanStatusSet(setId: setId, in: db) else {
          throw NoteServiceError.invalidRow("kanban status set vanished after insert: \(setId)")
        }
        return created
      }
    }
    publishChange(NoteChangeEvent(kind: NoteChangeEventKind.statusSets))
    return created
  }

  @discardableResult
  public func updateKanbanStatusSet(
    setId: String,
    statuses: [KanbanStatusUpsert],
    removedReassignTo: [String: String] = [:]
  ) throws -> KanbanStatusSet {
    try validateStatusList(statuses)
    let updated = try driver.withDatabase { database in
      try database.transaction { db in
        guard let current = try kanbanStatusSet(setId: setId, in: db) else {
          throw NoteServiceError.notFound("kanban status set not found: \(setId)")
        }
        guard !current.isSystem else {
          throw NoteServiceError.invalidInput("the system kanban status set is immutable")
        }
        let submittedById = Dictionary(
          uniqueKeysWithValues: statuses.compactMap { status in
            status.statusId.map { ($0, status) }
          }
        )
        let newNames = Set(statuses.map(\.name))

        for existing in current.statuses {
          if let submitted = submittedById[existing.statusId] {
            if submitted.name != existing.name {
              try migrateInScopeCards(
                from: existing.name,
                to: submitted.name,
                setId: setId,
                in: db
              )
            }
          } else if !newNames.contains(existing.name) {
            let holders = try inScopeCardCount(holding: existing.name, setId: setId, in: db)
            if holders > 0 {
              guard let reassignTo = removedReassignTo[existing.name] else {
                throw NoteServiceError.invalidInput(
                  "kanban status '\(existing.name)' is held by \(holders) notebook(s); provide a reassignment target"
                )
              }
              guard newNames.contains(reassignTo) else {
                throw NoteServiceError.invalidInput(
                  "reassignment target '\(reassignTo)' is not part of the updated status list"
                )
              }
              try migrateInScopeCards(from: existing.name, to: reassignTo, setId: setId, in: db)
            }
          }
        }

        let now = NoteStoreClock.system.now()
        try db.execute("DELETE FROM kanban_statuses WHERE set_id = ?", bindings: [.text(setId)])
        try insertStatuses(statuses, setId: setId, now: now, in: db)
        try db.execute(
          "UPDATE kanban_status_sets SET updated_at = ? WHERE set_id = ?",
          bindings: [.text(now), .text(setId)]
        )
        guard let updated = try kanbanStatusSet(setId: setId, in: db) else {
          throw NoteServiceError.invalidRow("kanban status set vanished after update: \(setId)")
        }
        return updated
      }
    }
    publishChange(NoteChangeEvent(kind: NoteChangeEventKind.statusSets))
    return updated
  }

  public func deleteKanbanStatusSet(setId: String) throws {
    try driver.withDatabase { database in
      try database.transaction { db in
        guard let current = try kanbanStatusSet(setId: setId, in: db) else {
          throw NoteServiceError.notFound("kanban status set not found: \(setId)")
        }
        guard !current.isSystem else {
          throw NoteServiceError.invalidInput("the system kanban status set cannot be deleted")
        }
        let boundTags = try db.query(
          "SELECT name FROM tags WHERE status_set_id = ? ORDER BY name LIMIT 5",
          bindings: [.text(setId)]
        ).compactMap { $0["name"] }
        guard boundTags.isEmpty else {
          throw NoteServiceError.invalidInput(
            "kanban status set is still bound to tag(s): \(boundTags.joined(separator: ", "))"
          )
        }
        try db.execute("DELETE FROM kanban_statuses WHERE set_id = ?", bindings: [.text(setId)])
        try db.execute("DELETE FROM kanban_status_sets WHERE set_id = ?", bindings: [.text(setId)])
      }
    }
    publishChange(NoteChangeEvent(kind: NoteChangeEventKind.statusSets))
  }

  @discardableResult
  public func assignKanbanStatusSet(tagName: String, setId: String?) throws -> Tag {
    let tagId = try driver.withDatabase { database in
      try requireTag(name: tagName, in: database).tagId
    }
    return try assignKanbanStatusSetByTagId(tagId: tagId, setId: setId)
  }

  @discardableResult
  public func assignKanbanStatusSetByTagId(tagId: String, setId: String?) throws -> Tag {
    let tag = try driver.withDatabase { database in
      try database.transaction { db in
        let tag = try requireTag(id: tagId, in: db)
        guard tag.classId == "folder" else {
          throw NoteServiceError.invalidInput(
            "kanban status sets can only be bound to folder-class tags; '\(tag.name)' has class \(tag.classId ?? "none")"
          )
        }
        if let setId {
          guard let target = try kanbanStatusSet(setId: setId, in: db) else {
            throw NoteServiceError.notFound("kanban status set not found: \(setId)")
          }
          _ = target
        }
        try db.execute(
          "UPDATE tags SET status_set_id = ? WHERE tag_id = ?",
          bindings: [.optionalText(setId), .text(tag.tagId)]
        )
        return try requireTag(id: tagId, in: db)
      }
    }
    publishChange(NoteChangeEvent(
      kind: NoteChangeEventKind.statusSets,
      tagNames: [tag.name]
    ))
    return tag
  }

  public func effectiveKanbanStatuses(tagName: String?) throws -> KanbanStatusSet {
    try driver.withDatabase { database in
      guard let tagName else { return try systemKanbanStatusSet(in: database) }
      let tag = try requireTag(name: tagName, in: database)
      return try effectiveKanbanStatusSet(tagId: tag.tagId, in: database)
    }
  }

  public func effectiveKanbanStatusesByTagId(tagId: String) throws -> KanbanStatusSet {
    try driver.withDatabase { database in
      _ = try requireTag(id: tagId, in: database)
      return try effectiveKanbanStatusSet(tagId: tagId, in: database)
    }
  }

  public func kanbanBoard(tagName: String, limit: Int = 200, offset: Int = 0) throws -> [KanbanBoardColumn] {
    let tagId = try driver.withDatabase { database in
      try requireTag(name: tagName, in: database).tagId
    }
    return try kanbanBoard(tagId: tagId, limit: limit, offset: offset)
  }

  public func kanbanBoard(tagId: String, limit: Int = 200, offset: Int = 0) throws -> [KanbanBoardColumn] {
    let notebooks = try listNotebooks(
      limit: limit,
      offset: offset,
      tagFilterIdGroups: [[tagId]]
    )
    return try driver.withDatabase { database in
      let tag = try requireTag(id: tagId, in: database)
      guard tag.classId == "folder" else {
        throw NoteServiceError.invalidInput(
          "kanban boards require a folder-class tag; '\(tag.name)' has class \(tag.classId ?? "none")"
        )
      }
      let scopeSet = try effectiveKanbanStatusSet(tagId: tagId, in: database)
      return try groupIntoKanbanColumns(notebooks: notebooks, scopeSet: scopeSet, in: database)
    }
  }
}

// MARK: - Internal helpers (shared with hydration and add-ons)

func kanbanStatusSets(in database: SQLiteDatabase) throws -> [KanbanStatusSet] {
  let setRows = try database.query(
    "SELECT set_id, name, is_system FROM kanban_status_sets ORDER BY is_system DESC, name"
  )
  return try setRows.map { row in
    guard let setId = row["set_id"] else {
      throw NoteServiceError.invalidRow("kanban status set row is missing set_id")
    }
    guard let set = try kanbanStatusSet(setId: setId, in: database) else {
      throw NoteServiceError.invalidRow("kanban status set vanished during listing: \(setId)")
    }
    return set
  }
}

func kanbanStatusSet(setId: String, in database: SQLiteDatabase) throws -> KanbanStatusSet? {
  let rows = try database.query(
    "SELECT set_id, name, is_system FROM kanban_status_sets WHERE set_id = ? LIMIT 1",
    bindings: [.text(setId)]
  )
  guard let row = rows.first, let name = row["name"] else {
    return nil
  }
  let statusRows = try database.query(
    """
    SELECT status_id, set_id, name, category, position
    FROM kanban_statuses
    WHERE set_id = ?
    ORDER BY position
    """,
    bindings: [.text(setId)]
  )
  let statuses = try statusRows.map { statusRow -> KanbanStatus in
    guard let statusId = statusRow["status_id"],
          let statusName = statusRow["name"],
          let categoryText = statusRow["category"],
          let category = KanbanStatusCategory(rawValue: categoryText),
          let positionText = statusRow["position"],
          let position = Int(positionText) else {
      throw NoteServiceError.invalidRow("kanban status row is missing required fields")
    }
    return KanbanStatus(statusId: statusId, setId: setId, name: statusName, category: category, position: position)
  }
  return KanbanStatusSet(
    setId: setId,
    name: name,
    isSystem: row["is_system"] == "1",
    statuses: statuses
  )
}

func systemKanbanStatusSet(in database: SQLiteDatabase) throws -> KanbanStatusSet {
  guard let set = try kanbanStatusSet(setId: NoteStoreSchema.systemKanbanStatusSetId, in: database) else {
    throw NoteServiceError.invalidRow("system kanban status set is missing; store not prepared")
  }
  return set
}

func effectiveKanbanStatusSet(tagName: String?, in database: SQLiteDatabase) throws -> KanbanStatusSet {
  guard let tagName else {
    return try systemKanbanStatusSet(in: database)
  }
  let tag = try requireTag(name: tagName, in: database)
  return try effectiveKanbanStatusSet(tagId: tag.tagId, in: database)
}

func effectiveKanbanStatusSet(tagId: String, in database: SQLiteDatabase) throws -> KanbanStatusSet {
  let rows = try database.query(
    """
    WITH RECURSIVE chain(tag_id, parent_tag_id, status_set_id, depth) AS (
      SELECT tag_id, parent_tag_id, status_set_id, 0
      FROM tags
      WHERE tag_id = ?
      UNION ALL
      SELECT parent.tag_id, parent.parent_tag_id, parent.status_set_id, chain.depth + 1
      FROM tags parent
      INNER JOIN chain ON parent.tag_id = chain.parent_tag_id
      WHERE chain.depth < 64
    )
    SELECT status_set_id
    FROM chain
    WHERE status_set_id IS NOT NULL
    ORDER BY depth
    LIMIT 1
    """,
    bindings: [.text(tagId)]
  )
  if let setId = rows.first?["status_set_id"] ?? nil,
     let set = try kanbanStatusSet(setId: setId, in: database) {
    return set
  }
  return try systemKanbanStatusSet(in: database)
}

/// Union of the system default set and the effective set of every
/// folder-class tag assigned to the notebook. Every notebook therefore always
/// accepts the default lifecycle names; custom sets extend, never restrict.
func allowedKanbanStatusNames(notebookId: String, in database: SQLiteDatabase) throws -> Set<String> {
  var allowed = Set(try systemKanbanStatusSet(in: database).statuses.map(\.name))
  let notebook = try requireNotebook(notebookId, in: database)
  for assignment in notebook.tags where assignment.tag.classId == "folder" {
    let set = try effectiveKanbanStatusSet(tagId: assignment.tag.tagId, in: database)
    allowed.formUnion(set.statuses.map(\.name))
  }
  return allowed
}

/// Deterministic board grouping per the design's A3 rule: direct name match
/// into the scope set; otherwise category resolution (system set first, then
/// smallest set_id across all sets defining the name), then the scope set's
/// first column of that category, else its first none-category column, else
/// its first column.
func groupIntoKanbanColumns(
  notebooks: [Notebook],
  scopeSet: KanbanStatusSet,
  in database: SQLiteDatabase
) throws -> [KanbanBoardColumn] {
  guard !scopeSet.statuses.isEmpty else {
    throw NoteServiceError.invalidRow("kanban status set has no statuses: \(scopeSet.setId)")
  }
  var columns = scopeSet.statuses.map { KanbanBoardColumn(status: $0, notebooks: []) }
  let indexByName = Dictionary(
    uniqueKeysWithValues: scopeSet.statuses.enumerated().map { ($0.element.name, $0.offset) }
  )
  // Category resolution precedence: system default set first, then the
  // defining set with the lexicographically smallest set_id (deterministic
  // tiebreak for cross-set name collisions).
  var categoryByName: [String: KanbanStatusCategory] = [:]
  for row in try database.query(
    """
    SELECT name, category
    FROM kanban_statuses
    ORDER BY (set_id = ?) DESC, set_id
    """,
    bindings: [.text(NoteStoreSchema.systemKanbanStatusSetId)]
  ) {
    guard let name = row["name"], let categoryText = row["category"],
          let category = KanbanStatusCategory(rawValue: categoryText) else {
      continue
    }
    if categoryByName[name] == nil {
      categoryByName[name] = category
    }
  }
  for notebook in notebooks {
    if let index = indexByName[notebook.progress] {
      columns[index].notebooks.append(notebook)
      continue
    }
    let category = categoryByName[notebook.progress] ?? .none
    let fallbackIndex = scopeSet.statuses.firstIndex { $0.category == category }
      ?? scopeSet.statuses.firstIndex { $0.category == .none }
      ?? 0
    columns[fallbackIndex].notebooks.append(notebook)
  }
  return columns
}

// MARK: - Private

private func validateStatusList(_ statuses: [KanbanStatusUpsert]) throws {
  guard !statuses.isEmpty else {
    throw NoteServiceError.invalidInput("a kanban status set must contain at least one status")
  }
  var seen = Set<String>()
  for status in statuses {
    let trimmed = status.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw NoteServiceError.invalidInput("kanban status names must not be empty")
    }
    guard trimmed == status.name else {
      throw NoteServiceError.invalidInput("kanban status names must not have surrounding whitespace: '\(status.name)'")
    }
    guard seen.insert(status.name).inserted else {
      throw NoteServiceError.invalidInput("duplicate kanban status name: \(status.name)")
    }
  }
}

private func insertStatuses(
  _ statuses: [KanbanStatusUpsert],
  setId: String,
  now: String,
  in database: SQLiteDatabase
) throws {
  for (position, status) in statuses.enumerated() {
    let statusId = status.statusId ?? "\(setId)-" + stableKanbanIdentifier(status.name)
    try database.execute(
      """
      INSERT INTO kanban_statuses (status_id, set_id, name, category, position, created_at)
      VALUES (?, ?, ?, ?, ?, ?)
      """,
      bindings: [
        .text(statusId),
        .text(setId),
        .text(status.name),
        .text(status.category.rawValue),
        .int(Int64(position)),
        .text(now)
      ]
    )
  }
}

/// Tags whose effective set resolves to `setId`: the directly bound tags plus
/// descendants without their own binding.
private let inScopeTagsCTE = """
  WITH RECURSIVE scoped_tags(tag_id) AS (
    SELECT tag_id FROM tags WHERE status_set_id = ?
    UNION
    SELECT child.tag_id
    FROM tags child
    INNER JOIN scoped_tags parent ON child.parent_tag_id = parent.tag_id
    WHERE child.status_set_id IS NULL
  )
  """

private func inScopeCardCount(
  holding statusName: String,
  setId: String,
  in database: SQLiteDatabase
) throws -> Int {
  let rows = try database.query(
    inScopeTagsCTE + """
    SELECT COUNT(DISTINCT nt.notebook_id) AS holder_count
    FROM notebook_tags nt
    INNER JOIN scoped_tags st ON nt.tag_id = st.tag_id
    INNER JOIN notebooks n ON n.notebook_id = nt.notebook_id
    WHERE n.status = ?
    """,
    bindings: [.text(setId), .text(statusName)]
  )
  guard let countText = rows.first?["holder_count"], let count = Int(countText) else {
    return 0
  }
  return count
}

private func migrateInScopeCards(
  from oldName: String,
  to newName: String,
  setId: String,
  in database: SQLiteDatabase
) throws {
  try database.execute(
    inScopeTagsCTE + """
    UPDATE notebooks
    SET status = ?, updated_at = ?
    WHERE status = ?
      AND notebook_id IN (
        SELECT DISTINCT nt.notebook_id
        FROM notebook_tags nt
        INNER JOIN scoped_tags st ON nt.tag_id = st.tag_id
      )
    """,
    bindings: [.text(setId), .text(newName), .text(NoteStoreClock.system.now()), .text(oldName)]
  )
}

private func stableKanbanIdentifier(_ name: String) -> String {
  String(
    name.lowercased().map { character in
      character.isLetter || character.isNumber ? character : "-"
    }
  )
}
