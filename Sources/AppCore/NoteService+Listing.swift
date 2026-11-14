extension NoteService {
  public func listNotes(notebookId: NotebookID, limit: Int = 100, offset: Int = 0) throws -> [Note] {
    try driver.withDatabase { database in
      _ = try requireNotebook(notebookId, in: database)
      let rows = try database.query(
        """
        SELECT note_id, notebook_id, note_number, title, body_markdown, read_only,
          created_at, updated_at,
          CASE WHEN meta_json IS NULL THEN NULL ELSE json(meta_json) END AS meta_json
        FROM notes
        WHERE notebook_id = ?
        ORDER BY note_number, note_id
        LIMIT ? OFFSET ?
        """,
        bindings: [.id(notebookId), .int(Int64(limit)), .int(Int64(offset))]
      )
      return try notes(from: rows, in: database)
    }
  }

  public func listNotes(
    limit: Int = 100,
    offset: Int = 0,
    notebookId: NotebookID? = nil,
    tagFilter: [String] = []
  ) throws -> [Note] {
    try driver.withDatabase { database in
      let expandedTagFilterIds = try expandedTagFilterIds(names: tagFilter, in: database)
      guard tagFilter.isEmpty || !expandedTagFilterIds.isEmpty else {
        return []
      }
      var predicates: [String] = []
      var bindings: [SQLiteValue] = []
      // The cross-notebook feed spans libraries, so it carries the same scope
      // the catalog does (`design-docs/specs/library.md`).
      appendLibraryScopePredicate(
        alias: "notes",
        reachableLibraryIds: try reachableLibraryIds(in: database),
        predicates: &predicates,
        bindings: &bindings
      )
      appendOwnerScopePredicate(
        alias: "notes",
        actingUserId: actingUserId,
        predicates: &predicates,
        bindings: &bindings
      )
      if isUnauthenticatedPrincipal, actingUserId == nil {
        appendLongTermMemoryExclusionPredicate(
          alias: "notes",
          excludesLongTermMemory: true,
          predicates: &predicates,
          bindings: &bindings
        )
      }
      if let notebookId {
        _ = try requireNotebook(notebookId, in: database)
        predicates.append("notebook_id = ?")
        bindings.append(.id(notebookId))
      }
      if !allowsPendingNotebookIngestAccess {
        predicates.append(
          "notes.notebook_id NOT IN (SELECT notebook_id FROM notebooks " +
            "WHERE json_extract(meta_json, '$._kaibaNotebookIngest.state') = 'pending')"
        )
      }
      if !expandedTagFilterIds.isEmpty {
        predicates.append(
          """
          EXISTS (
            SELECT 1
            FROM note_tags nt
            WHERE nt.note_id = notes.note_id
              AND nt.tag_id IN (\(placeholders(count: expandedTagFilterIds.count)))
          )
          """
        )
        bindings.append(contentsOf: expandedTagFilterIds.sqliteBindings)
      }
      let whereClause = predicates.isEmpty ? "" : "WHERE \(predicates.joined(separator: " AND "))"
      // A notebook-scoped listing returns the notebook's pages in their intrinsic
      // order (note_number); `created_at DESC` is reserved for the cross-notebook
      // feed, where recency is the only meaningful ordering.
      let orderClause = notebookId == nil ? "created_at DESC, note_id" : "note_number, note_id"
      bindings.append(.int(Int64(limit)))
      bindings.append(.int(Int64(offset)))
      let rows = try database.query(
        """
        SELECT note_id, notebook_id, note_number, title, body_markdown, read_only,
          created_at, updated_at,
          CASE WHEN meta_json IS NULL THEN NULL ELSE json(meta_json) END AS meta_json
        FROM notes
        \(whereClause)
        ORDER BY \(orderClause)
        LIMIT ? OFFSET ?
        """,
        bindings: bindings
      )
      return try notes(from: rows, in: database)
    }
  }
}
