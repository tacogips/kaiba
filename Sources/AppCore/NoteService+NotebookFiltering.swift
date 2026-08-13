extension NoteService {
  public func listNotebooks(
    limit: Int = 50,
    offset: Int = 0,
    tagFilter: [String] = [],
    tagFilterGroups: [[String]] = [],
    tagFilterIdGroups: [[String]] = [],
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
      let boundedGroups = usesIdGroups ? normalizedIdGroups : requestedNameGroups
      let rawBoundedGroups = usesIdGroups
        ? tagFilterIdGroups.filter { !$0.isEmpty }
        : tagFilterGroups
      if !rawBoundedGroups.isEmpty {
        let fieldName = usesIdGroups ? "tagFilterIdGroups" : "tagFilterGroups"
        guard rawBoundedGroups.count <= Self.maximumNotebookTagFilterGroups else {
          throw NoteServiceError.invalidInput(
            "\(fieldName) supports at most \(Self.maximumNotebookTagFilterGroups) groups"
          )
        }
        var inputCount = 0
        for group in rawBoundedGroups {
          guard group.count <= Self.maximumNotebookTagFilterNames - inputCount else {
            throw NoteServiceError.invalidInput(
              "\(fieldName) supports at most \(Self.maximumNotebookTagFilterNames) " +
                (usesIdGroups ? "tag IDs" : "tag names")
            )
          }
          inputCount += group.count
        }
      }
      if !usesIdGroups, !tagFilterGroups.isEmpty, nameGroups.isEmpty {
        return []
      }
      var expandedGroups: [[String]] = []
      var expandedIdentityCount = 0
      for group in boundedGroups {
        let expandedGroup = usesIdGroups
          ? try expandedTagFilterIds(group, in: database)
          : try expandedLegacyTagFilterIds(group, in: database)
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
        bindings.append(contentsOf: expandedGroup.map(SQLiteValue.text))
      }
      appendCreatedAtPredicates(
        alias: "notebooks",
        createdAfter: createdAfter,
        createdBefore: createdBefore,
        predicates: &predicates,
        bindings: &bindings
      )
      let whereClause = predicates.isEmpty ? "" : "WHERE \(predicates.joined(separator: " AND "))"
      bindings.append(.int(Int64(limit)))
      bindings.append(.int(Int64(offset)))
      var notebooks = try database.query(
        """
        SELECT notebook_id, title, read_only, created_at, updated_at,
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
