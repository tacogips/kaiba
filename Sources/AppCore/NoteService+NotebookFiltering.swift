extension NoteService {
  public func listNotebooks(
    limit: Int = 50,
    offset: Int = 0,
    tagFilter: [String] = [],
    tagFilterGroups: [[String]] = [],
    tagFilterIdGroups: [[TagID]] = [],
    sort: NoteListSort = .createdAtDesc,
    createdAfter: String? = nil,
    createdBefore: String? = nil
  ) throws -> [Notebook] {
    try driver.withDatabase { database in
      let normalizedIdGroups = canonicalTagFilterGroups(tagFilterIdGroups, discardingEmpty: true)
      let usesIdGroups = !normalizedIdGroups.isEmpty
      let nameGroups = canonicalTagFilterGroups(tagFilterGroups, discardingEmpty: false)
      let requestedNameGroups = nameGroups.isEmpty
        ? (tagFilter.isEmpty ? [] : [orderedUnique(tagFilter).sorted()])
        : nameGroups
      // Both filter shapes are bounded by the same limits; only the element
       // type differs, so the check runs over the group sizes alone.
      let rawBoundedGroupSizes = usesIdGroups
        ? tagFilterIdGroups.filter { !$0.isEmpty }.map(\.count)
        : tagFilterGroups.map(\.count)
      if !rawBoundedGroupSizes.isEmpty {
        let fieldName = usesIdGroups ? "tagFilterIdGroups" : "tagFilterGroups"
        guard rawBoundedGroupSizes.count <= Self.maximumNotebookTagFilterGroups else {
          throw NoteServiceError.invalidInput(
            "\(fieldName) supports at most \(Self.maximumNotebookTagFilterGroups) groups"
          )
        }
        var inputCount = 0
        for groupSize in rawBoundedGroupSizes {
          guard groupSize <= Self.maximumNotebookTagFilterNames - inputCount else {
            throw NoteServiceError.invalidInput(
              "\(fieldName) supports at most \(Self.maximumNotebookTagFilterNames) " +
                (usesIdGroups ? "tag IDs" : "tag names")
            )
          }
          inputCount += groupSize
        }
      }
      if !usesIdGroups, !tagFilterGroups.isEmpty, nameGroups.isEmpty {
        return []
      }
      var expandedGroups: [[TagID]] = []
      var expandedIdentityCount = 0
      let boundedGroupExpansions: [[TagID]] = try usesIdGroups
        ? normalizedIdGroups.map { try expandedTagFilterIds($0, in: database) }
        : requestedNameGroups.map { try expandedLegacyTagFilterIds($0, in: database) }
      for expandedGroup in boundedGroupExpansions {
        guard !expandedGroup.isEmpty else { return [] }
        guard expandedGroup.count
          <= Self.maximumExpandedNotebookTagFilterNames - expandedIdentityCount else {
          throw NoteServiceError.invalidInput(
            "\(usesIdGroups ? "tagFilterIdGroups" : "tagFilterGroups") expands to at most " +
              "\(Self.maximumExpandedNotebookTagFilterNames) " +
              (usesIdGroups ? "tag IDs" : "tag names")
          )
        }
        expandedIdentityCount += expandedGroup.count
        expandedGroups.append(expandedGroup)
      }
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
      // A selected library narrows the catalog to it; without one, an unscoped
      // caller is still held to the libraries that need no authentication
      // (`design-docs/specs/library.md`).
      appendLibraryPredicates(alias: "notebooks", predicates: &predicates, bindings: &bindings)
      let whereClause = predicates.isEmpty ? "" : "WHERE \(predicates.joined(separator: " AND "))"
      bindings.append(.int(Int64(limit)))
      bindings.append(.int(Int64(offset)))
      var notebooks = try database.query(
        """
        SELECT notebook_id, title, read_only, created_at, updated_at, library_id,
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
