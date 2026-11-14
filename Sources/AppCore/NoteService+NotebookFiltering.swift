extension NoteService {
  /// Lists notebooks visible to this service value. `tagFilterIdGroups` is a
  /// conjunction of disjunctions: a notebook matches when, for every group, it
  /// carries at least one of the group's tags or their descendants. Empty
  /// groups are ignored; an unknown id fails closed to an empty list.
  public func listNotebooks(
    limit: Int = 50,
    offset: Int = 0,
    tagFilterIdGroups: [[TagID]] = [],
    sort: NoteListSort = .createdAtDesc,
    createdAfter: String? = nil,
    createdBefore: String? = nil
  ) throws -> [Notebook] {
    try driver.withDatabase { database in
      let expandedGroups = try expandedNotebookTagFilterGroups(tagFilterIdGroups, in: database)
      guard let expandedGroups else { return [] }
      var predicates: [String] = []
      var bindings: [SQLiteValue] = []
      for expandedGroup in expandedGroups {
        predicates.append(
          """
          EXISTS (
            SELECT 1
            FROM notebook_tags nt
            WHERE nt.notebook_id = notebooks.notebook_id
              AND nt.tag_id IN (\(placeholders(count: expandedGroup.count)))
          )
          """
        )
        bindings.append(contentsOf: expandedGroup.sqliteBindings)
      }
      appendCreatedAtPredicates(
        alias: "notebooks",
        createdAfter: createdAfter,
        createdBefore: createdBefore,
        predicates: &predicates,
        bindings: &bindings
      )
      // A scoped service sees one account's catalog; the unscoped value (the
      // CLI, internal bootstrap paths) still sees the whole store.
      if let actingUserId {
        predicates.append("notebooks.owner_user_id = ?")
        bindings.append(.id(actingUserId))
      }
      if actingUserId != nil || isUnauthenticatedPrincipal {
        predicates.append(
          "notebooks.notebook_id NOT IN (SELECT notebook_id FROM notebook_tags WHERE tag_id = ?)"
        )
        bindings.append(.id(NoteStoreSchema.longTermMemoryNotebookKindTagId))
      }
      // A selected library narrows the catalog to it; without one, an unscoped
      // caller is still held to the libraries that need no authentication
      // (`design-docs/specs/library.md`).
      appendLibraryPredicates(alias: "notebooks", predicates: &predicates, bindings: &bindings)
      let whereClause = predicates.isEmpty ? "" : "WHERE \(predicates.joined(separator: " AND "))"
      bindings.append(.int(Int64(limit)))
      bindings.append(.int(Int64(offset)))
      var notebooks = try database.query(
        """
        SELECT notebook_id, title, read_only, created_at, updated_at, library_id, owner_user_id, created_by, updated_by,
          CASE WHEN meta_json IS NULL THEN NULL ELSE json(meta_json) END AS meta_json
        FROM notebooks
        \(whereClause)
        ORDER BY \(notebookSortOrderClause(alias: "notebooks", sort: sort))
        LIMIT ? OFFSET ?
        """,
        bindings: bindings
      )
      .map { row in
        try notebook(from: row, in: database)
      }
      try enrichNotebookListMetadata(&notebooks, in: database)
      return notebooks
    }
  }
}

private extension NoteService {
  /// Bounds the request before touching the store, then expands every group to
  /// its descendant closure. Returns nil when a group matches nothing, which
  /// makes the whole filter unsatisfiable.
  func expandedNotebookTagFilterGroups(
    _ tagFilterIdGroups: [[TagID]],
    in database: SQLiteDatabase
  ) throws -> [[TagID]]? {
    let boundedGroupSizes = tagFilterIdGroups.filter { !$0.isEmpty }.map(\.count)
    guard boundedGroupSizes.count <= Self.maximumNotebookTagFilterGroups else {
      throw NoteServiceError.invalidInput(
        "tagFilterIdGroups supports at most \(Self.maximumNotebookTagFilterGroups) groups"
      )
    }
    var inputCount = 0
    for groupSize in boundedGroupSizes {
      guard groupSize <= Self.maximumNotebookTagFilterNames - inputCount else {
        throw NoteServiceError.invalidInput(
          "tagFilterIdGroups supports at most \(Self.maximumNotebookTagFilterNames) tag IDs"
        )
      }
      inputCount += groupSize
    }
    var expandedGroups: [[TagID]] = []
    var expandedIdentityCount = 0
    for group in canonicalTagFilterGroups(tagFilterIdGroups, discardingEmpty: true) {
      let expandedGroup = try expandedTagFilterIds(group, in: database)
      guard !expandedGroup.isEmpty else { return nil }
      guard expandedGroup.count
        <= Self.maximumExpandedNotebookTagFilterNames - expandedIdentityCount else {
        throw NoteServiceError.invalidInput(
          "tagFilterIdGroups expands to at most " +
            "\(Self.maximumExpandedNotebookTagFilterNames) tag IDs"
        )
      }
      expandedIdentityCount += expandedGroup.count
      expandedGroups.append(expandedGroup)
    }
    return expandedGroups
  }
}
