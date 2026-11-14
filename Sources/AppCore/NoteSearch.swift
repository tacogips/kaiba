import Foundation

struct FTSPayload {
  var rowId: Int64
  var title: String
  var body: String
  var tags: String
}

struct NoteSearchGraphOptions {
  var includeLinked: Bool
  var depth: Int
}

/// What a search may see: one notebook when the caller asked for it, and the
/// libraries the caller may reach at all (`design-docs/specs/library.md`).
struct NoteSearchScope {
  var notebookId: NotebookID?
  /// Nil is unrestricted — an authenticated caller with no library selected.
  var reachableLibraryIds: [LibraryID]?
  var actingUserId: UserID?
  var excludesLongTermMemory: Bool
  var createdAfter: String?
  var createdBefore: String?

  init(
    notebookId: NotebookID? = nil,
    reachableLibraryIds: [LibraryID]? = nil,
    actingUserId: UserID? = nil,
    excludesLongTermMemory: Bool = false,
    createdAfter: String? = nil,
    createdBefore: String? = nil
  ) {
    self.notebookId = notebookId
    self.reachableLibraryIds = reachableLibraryIds
    self.actingUserId = actingUserId
    self.excludesLongTermMemory = excludesLongTermMemory
    self.createdAfter = createdAfter
    self.createdBefore = createdBefore
  }
}

func appendLongTermMemoryExclusionPredicate(
  alias: String,
  excludesLongTermMemory: Bool,
  predicates: inout [String],
  bindings: inout [SQLiteValue]
) {
  guard excludesLongTermMemory else { return }
  predicates.append(
    "\(alias).notebook_id NOT IN (SELECT notebook_id FROM notebook_tags WHERE tag_id = ?)"
  )
  bindings.append(.id(NoteStoreSchema.longTermMemoryNotebookKindTagId))
}

/// Ownership is independent of library reach: an admin has unrestricted
/// libraries but still sees only its own notebooks on a scoped request.
func appendOwnerScopePredicate(
  alias: String,
  actingUserId: UserID?,
  predicates: inout [String],
  bindings: inout [SQLiteValue]
) {
  guard let actingUserId else { return }
  predicates.append("\(alias).notebook_id IN (SELECT notebook_id FROM notebooks WHERE owner_user_id = ?)")
  bindings.append(.id(actingUserId))
  // Long-term memory is a singleton internal notebook. It is currently
  // store-wide rather than per-user, so no scoped principal may discover its
  // rows simply because the bootstrap account owns it.
  predicates.append(
    "\(alias).notebook_id NOT IN (SELECT notebook_id FROM notebook_tags WHERE tag_id = ?)"
  )
  bindings.append(.id(NoteStoreSchema.longTermMemoryNotebookKindTagId))
}

func appendOwnerScopePredicate(
  alias: String,
  actingUserId: UserID?,
  sql: inout String,
  bindings: inout [SQLiteValue]
) {
  var predicates: [String] = []
  appendOwnerScopePredicate(alias: alias, actingUserId: actingUserId, predicates: &predicates, bindings: &bindings)
  for predicate in predicates { sql += "\n  AND \(predicate)" }
}

/// Restricts a note query to the libraries the caller may reach
/// (`design-docs/specs/library.md`). Nil means unrestricted — an authenticated
/// caller with no library selected. An empty list means nothing is reachable,
/// which must match no rows rather than every row.
func appendLibraryScopePredicate(
  alias: String,
  reachableLibraryIds: [LibraryID]?,
  predicates: inout [String],
  bindings: inout [SQLiteValue]
) {
  guard let reachableLibraryIds else {
    return
  }
  guard !reachableLibraryIds.isEmpty else {
    predicates.append("0")
    return
  }
  predicates.append(
    """
    \(alias).notebook_id IN (
      SELECT notebook_id FROM notebooks
      WHERE library_id IN (\(placeholders(count: reachableLibraryIds.count)))
    )
    """
  )
  bindings.append(contentsOf: reachableLibraryIds.sqliteBindings)
}

func appendLibraryScopePredicate(
  alias: String,
  reachableLibraryIds: [LibraryID]?,
  sql: inout String,
  bindings: inout [SQLiteValue]
) {
  var predicates: [String] = []
  appendLibraryScopePredicate(
    alias: alias,
    reachableLibraryIds: reachableLibraryIds,
    predicates: &predicates,
    bindings: &bindings
  )
  for predicate in predicates {
    sql += "\n  AND \(predicate)"
  }
}

func searchNotesInDatabase(
  query: String,
  tagFilter: [String],
  classFilter: [String],
  scope: NoteSearchScope,
  sort: NoteListSort,
  graphOptions: NoteSearchGraphOptions,
  limit: Int,
  offset: Int,
  in database: SQLiteDatabase
) throws -> [NoteSearchResult] {
  let expandedTagFilterIds = try expandedLegacyTagFilterIds(tagFilter, in: database)
  guard tagFilter.isEmpty || !expandedTagFilterIds.isEmpty else {
    return []
  }
  let requestedLimit = max(0, limit)
  let requestedOffset = max(0, offset)
  // Guard against Int overflow: a hostile `offset` near `Int.max` must not trap
  // the process when combined with `limit`. Clamp the combined fetch window.
  let (sum, overflowed) = requestedLimit.addingReportingOverflow(requestedOffset)
  let fetchLimit = overflowed ? Int.max : sum
  guard fetchLimit > 0 else {
    return []
  }
  guard let matchQuery = ftsMatchQuery(from: query) else {
    // No FTS terms (e.g. a symbol-only query like "→"). When the trimmed query is
    // non-empty the trigram index can't match it, but a substring LIKE scan still
    // can, so run the same LIKE fallback used for sub-trigram terms rather than
    // dropping the query and returning filter-only results.
    let results: [NoteSearchResult]
    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      results = try searchNotesByFilters(
        tagFilterIds: expandedTagFilterIds,
        classFilter: classFilter,
        scope: scope,
        sort: sort,
        limit: fetchLimit,
        in: database
      )
    } else {
      results = try searchNotesByTextLike(
        query: query,
        tagFilterIds: expandedTagFilterIds,
        classFilter: classFilter,
        scope: scope,
        excludedNoteIds: [],
        sort: sort,
        limit: fetchLimit,
        in: database
      )
    }
    let expanded = try graphOptions.includeLinked
      ? appendLinkedNeighborResults(
          to: results,
          query: query,
          tagFilterIds: expandedTagFilterIds,
          classFilter: classFilter,
          scope: scope,
          sort: sort,
          depth: graphOptions.depth,
          limit: fetchLimit,
          in: database
        )
      : results
    return Array(expanded.dropFirst(requestedOffset).prefix(requestedLimit))
  }
  var sql = """
    SELECT m.note_id, bm25(note_fts) AS rank
    FROM note_fts
    INNER JOIN note_fts_map m ON m.fts_rowid = note_fts.rowid
    INNER JOIN notes n ON n.note_id = m.note_id
    WHERE note_fts MATCH ?
    """
  var bindings: [SQLiteValue] = [.text(matchQuery)]
  if let notebookId = scope.notebookId {
    sql += "\n  AND n.notebook_id = ?"
    bindings.append(.id(notebookId))
  }
  appendLibraryScopePredicate(
    alias: "n",
    reachableLibraryIds: scope.reachableLibraryIds,
    sql: &sql,
    bindings: &bindings
  )
  appendOwnerScopePredicate(alias: "n", actingUserId: scope.actingUserId, sql: &sql, bindings: &bindings)
  if scope.excludesLongTermMemory, scope.actingUserId == nil {
    sql += "\n  AND n.notebook_id NOT IN (SELECT notebook_id FROM notebook_tags WHERE tag_id = ?)"
    bindings.append(.id(NoteStoreSchema.longTermMemoryNotebookKindTagId))
  }
  appendCreatedAtPredicates(
    alias: "n",
    createdAfter: scope.createdAfter,
    createdBefore: scope.createdBefore,
    sql: &sql,
    bindings: &bindings
  )
  if !expandedTagFilterIds.isEmpty {
    sql += """

      AND EXISTS (
        SELECT 1
        FROM note_tags nt
        WHERE nt.note_id = n.note_id
          AND nt.tag_id IN (\(placeholders(count: expandedTagFilterIds.count)))
      )
      """
    bindings.append(contentsOf: expandedTagFilterIds.sqliteBindings)
  }
  if !classFilter.isEmpty {
    sql += """

      AND EXISTS (
        SELECT 1
        FROM note_tags nt
        INNER JOIN tags t ON t.tag_id = nt.tag_id
        WHERE nt.note_id = n.note_id
          AND t.class_id IN (\(placeholders(count: classFilter.count)))
      )
      """
    bindings.append(contentsOf: classFilter.map(SQLiteValue.text))
  }
  sql += " ORDER BY rank, \(noteSortOrderClause(alias: "n", sort: sort)) LIMIT ?"
  bindings.append(.int(Int64(fetchLimit)))

  let rows = try database.query(sql, bindings: bindings)
  let notesById = try requireNotes(rows.compactMap { $0.identifier("note_id", as: NoteID.self) }, in: database)
  var results = try rows.map { row in
    guard let noteId = row.identifier("note_id", as: NoteID.self) else {
      throw NoteServiceError.invalidRow("search row is missing note_id")
    }
    guard let note = notesById[noteId] else {
      throw NoteServiceError.notFound("note not found: \(noteId)")
    }
    let rank = Double(row["rank"] ?? "") ?? 0
    return NoteSearchResult(
      note: note,
      snippet: snippet(from: note.bodyMarkdown, query: query),
      rank: rank,
      matchedTags: note.tags.map(\.tag)
    )
  }
  if shouldRunTextLikeFallback(query: query, ftsResultCount: results.count) {
    let fallback = try searchNotesByTextLike(
      query: query,
      tagFilterIds: expandedTagFilterIds,
      classFilter: classFilter,
      scope: scope,
      excludedNoteIds: Set(results.map(\.note.noteId)),
      sort: sort,
      limit: fetchLimit - results.count,
      in: database
    )
    results.append(contentsOf: fallback)
  }
  let expanded = try graphOptions.includeLinked
    ? appendLinkedNeighborResults(
        to: results,
        query: query,
        tagFilterIds: expandedTagFilterIds,
        classFilter: classFilter,
        scope: scope,
        sort: sort,
        depth: graphOptions.depth,
        limit: fetchLimit,
        in: database
      )
    : results
  return Array(expanded.dropFirst(requestedOffset).prefix(requestedLimit))
}

private func shouldRunTextLikeFallback(query: String, ftsResultCount: Int) -> Bool {
  ftsResultCount == 0 || queryHasSubtrigramTerm(query)
}

private func searchNotesByFilters(
  tagFilterIds: [TagID],
  classFilter: [String],
  scope: NoteSearchScope,
  sort: NoteListSort,
  limit: Int,
  in database: SQLiteDatabase
) throws -> [NoteSearchResult] {
  guard !tagFilterIds.isEmpty || !classFilter.isEmpty || scope.createdAfter != nil || scope.createdBefore != nil
    || scope.notebookId != nil
  else {
    return []
  }
  var predicates: [String] = []
  var bindings: [SQLiteValue] = []
  appendLibraryScopePredicate(
    alias: "n",
    reachableLibraryIds: scope.reachableLibraryIds,
    predicates: &predicates,
    bindings: &bindings
  )
  appendOwnerScopePredicate(alias: "n", actingUserId: scope.actingUserId, predicates: &predicates, bindings: &bindings)
  if scope.excludesLongTermMemory, scope.actingUserId == nil {
    appendLongTermMemoryExclusionPredicate(
      alias: "n",
      excludesLongTermMemory: true,
      predicates: &predicates,
      bindings: &bindings
    )
  }
  if let notebookId = scope.notebookId {
    predicates.append("n.notebook_id = ?")
    bindings.append(.id(notebookId))
  }
  if !tagFilterIds.isEmpty {
    predicates.append(
      """
      EXISTS (
        SELECT 1
        FROM note_tags nt
        WHERE nt.note_id = n.note_id
          AND nt.tag_id IN (\(placeholders(count: tagFilterIds.count)))
      )
      """
    )
    bindings.append(contentsOf: tagFilterIds.sqliteBindings)
  }
  if !classFilter.isEmpty {
    predicates.append(
      """
      EXISTS (
        SELECT 1
        FROM note_tags nt
        INNER JOIN tags t ON t.tag_id = nt.tag_id
        WHERE nt.note_id = n.note_id
          AND t.class_id IN (\(placeholders(count: classFilter.count)))
      )
      """
    )
    bindings.append(contentsOf: classFilter.map(SQLiteValue.text))
  }
  appendCreatedAtPredicates(
    alias: "n",
    createdAfter: scope.createdAfter,
    createdBefore: scope.createdBefore,
    predicates: &predicates,
    bindings: &bindings
  )
  bindings.append(.int(Int64(limit)))
  let rows = try database.query(
    """
    SELECT n.note_id
    FROM notes n
    WHERE \(predicates.joined(separator: " AND "))
    ORDER BY \(noteSortOrderClause(alias: "n", sort: sort))
    LIMIT ?
    """,
    bindings: bindings
  )
  let notesById = try requireNotes(rows.compactMap { $0.identifier("note_id", as: NoteID.self) }, in: database)
  return try rows.map { row in
    guard let noteId = row.identifier("note_id", as: NoteID.self) else {
      throw NoteServiceError.invalidRow("filtered search row is missing note_id")
    }
    guard let note = notesById[noteId] else {
      throw NoteServiceError.notFound("note not found: \(noteId)")
    }
    return NoteSearchResult(
      note: note,
      snippet: snippet(from: note.bodyMarkdown, query: ""),
      rank: 0,
      matchedTags: note.tags.map(\.tag)
    )
  }
}

private func searchNotesByTextLike(
  query: String,
  tagFilterIds: [TagID],
  classFilter: [String],
  scope: NoteSearchScope,
  excludedNoteIds: Set<NoteID>,
  sort: NoteListSort,
  limit: Int,
  in database: SQLiteDatabase
) throws -> [NoteSearchResult] {
  let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !normalizedQuery.isEmpty, limit > 0 else {
    return []
  }
  let likePattern = "%\(escapedLikePattern(normalizedQuery))%"
  var predicates: [String] = [
    """
    (
      n.title LIKE ? ESCAPE '\\'
      OR n.body_markdown LIKE ? ESCAPE '\\'
      OR EXISTS (
        SELECT 1
        FROM note_tags nt
        INNER JOIN tags t ON t.tag_id = nt.tag_id
        WHERE nt.note_id = n.note_id
          AND t.name LIKE ? ESCAPE '\\'
      )
    )
    """
  ]
  var bindings: [SQLiteValue] = [.text(likePattern), .text(likePattern), .text(likePattern)]
  appendLibraryScopePredicate(
    alias: "n",
    reachableLibraryIds: scope.reachableLibraryIds,
    predicates: &predicates,
    bindings: &bindings
  )
  appendOwnerScopePredicate(alias: "n", actingUserId: scope.actingUserId, predicates: &predicates, bindings: &bindings)
  if scope.excludesLongTermMemory, scope.actingUserId == nil {
    appendLongTermMemoryExclusionPredicate(
      alias: "n",
      excludesLongTermMemory: true,
      predicates: &predicates,
      bindings: &bindings
    )
  }
  if let notebookId = scope.notebookId {
    predicates.append("n.notebook_id = ?")
    bindings.append(.id(notebookId))
  }
  if !excludedNoteIds.isEmpty {
    predicates.append("n.note_id NOT IN (\(placeholders(count: excludedNoteIds.count)))")
    bindings.append(contentsOf: excludedNoteIds.sorted().sqliteBindings)
  }
  if !tagFilterIds.isEmpty {
    predicates.append(
      """
      EXISTS (
        SELECT 1
        FROM note_tags nt
        WHERE nt.note_id = n.note_id
          AND nt.tag_id IN (\(placeholders(count: tagFilterIds.count)))
      )
      """
    )
    bindings.append(contentsOf: tagFilterIds.sqliteBindings)
  }
  if !classFilter.isEmpty {
    predicates.append(
      """
      EXISTS (
        SELECT 1
        FROM note_tags nt
        INNER JOIN tags t ON t.tag_id = nt.tag_id
        WHERE nt.note_id = n.note_id
          AND t.class_id IN (\(placeholders(count: classFilter.count)))
      )
      """
    )
    bindings.append(contentsOf: classFilter.map(SQLiteValue.text))
  }
  appendCreatedAtPredicates(
    alias: "n",
    createdAfter: scope.createdAfter,
    createdBefore: scope.createdBefore,
    predicates: &predicates,
    bindings: &bindings
  )
  bindings.append(.int(Int64(limit)))
  let rows = try database.query(
    """
    SELECT n.note_id
    FROM notes n
    WHERE \(predicates.joined(separator: " AND "))
    ORDER BY \(noteSortOrderClause(alias: "n", sort: sort))
    LIMIT ?
    """,
    bindings: bindings
  )
  let notesById = try requireNotes(rows.compactMap { $0.identifier("note_id", as: NoteID.self) }, in: database)
  return try rows.map { row in
    guard let noteId = row.identifier("note_id", as: NoteID.self) else {
      throw NoteServiceError.invalidRow("fallback search row is missing note_id")
    }
    guard let note = notesById[noteId] else {
      throw NoteServiceError.notFound("note not found: \(noteId)")
    }
    return NoteSearchResult(
      note: note,
      snippet: snippet(from: note.bodyMarkdown, query: query),
      rank: 1,
      matchedTags: note.tags.map(\.tag)
    )
  }
}

private func appendLinkedNeighborResults(
  to directResults: [NoteSearchResult],
  query: String,
  tagFilterIds: [TagID],
  classFilter: [String],
  scope: NoteSearchScope,
  sort: NoteListSort,
  depth: Int,
  limit: Int,
  in database: SQLiteDatabase
) throws -> [NoteSearchResult] {
  guard !directResults.isEmpty, limit > directResults.count else {
    return directResults
  }
  let directNoteIds = directResults.map(\.note.noteId)
  let directNoteIdSet = Set(directNoteIds)
  let neighborLimit = limit - directResults.count
  // Exclude direct hits from the traversal results and fetch a full candidate
  // set: eligibility (tag/date) filtering happens below, so truncating to the
  // neighbor budget before filtering would let a direct hit or a filter-failing
  // note consume a slot and undercount genuine neighbors.
  let graphResults = try noteGraphNeighborsInDatabase(
    noteIds: Array(directNoteIds.prefix(NoteGraphPolicy.maximumSeedCount)),
    maxDepth: depth,
    limit: NoteGraphPolicy.maximumLimit,
    resultExclusions: directNoteIdSet,
    scope: scope,
    in: database
  )
  guard !graphResults.isEmpty else {
    return directResults
  }
  let candidateIds = graphResults.map(\.note.noteId).filter { !directNoteIdSet.contains($0) }
  guard !candidateIds.isEmpty else {
    return directResults
  }
  var predicates: [String] = [
    "n.note_id IN (\(placeholders(count: candidateIds.count)))"
  ]
  var bindings = candidateIds.sqliteBindings
  appendLibraryScopePredicate(
    alias: "n",
    reachableLibraryIds: scope.reachableLibraryIds,
    predicates: &predicates,
    bindings: &bindings
  )
  appendOwnerScopePredicate(alias: "n", actingUserId: scope.actingUserId, predicates: &predicates, bindings: &bindings)
  if scope.excludesLongTermMemory, scope.actingUserId == nil {
    appendLongTermMemoryExclusionPredicate(
      alias: "n",
      excludesLongTermMemory: true,
      predicates: &predicates,
      bindings: &bindings
    )
  }
  if let notebookId = scope.notebookId {
    predicates.append("n.notebook_id = ?")
    bindings.append(.id(notebookId))
  }
  appendCreatedAtPredicates(
    alias: "n",
    createdAfter: scope.createdAfter,
    createdBefore: scope.createdBefore,
    predicates: &predicates,
    bindings: &bindings
  )
  appendTagPredicates(
    alias: "n",
    tagFilterIds: tagFilterIds,
    classFilter: classFilter,
    predicates: &predicates,
    bindings: &bindings
  )
  let eligibleRows = try database.query(
    """
    SELECT n.note_id
    FROM notes n
    WHERE \(predicates.joined(separator: " AND "))
    """,
    bindings: bindings
  )
  let eligibleIds = Set(eligibleRows.compactMap { $0.identifier("note_id", as: NoteID.self) })
  let neighbors = graphResults.compactMap { graphResult -> NoteSearchResult? in
    guard !directNoteIdSet.contains(graphResult.note.noteId),
          eligibleIds.contains(graphResult.note.noteId) else {
      return nil
    }
    return NoteSearchResult(
      note: graphResult.note,
      snippet: snippet(from: graphResult.note.bodyMarkdown, query: query),
      rank: graphResult.weight,
      matchedTags: graphResult.note.tags.map(\.tag),
      isLinkedNeighbor: true
    )
  }
  return directResults + neighbors.prefix(max(0, neighborLimit))
}

func noteSortOrderClause(alias: String, sort: NoteListSort) -> String {
  switch sort {
  case .createdAtDesc:
    return "\(alias).created_at DESC, \(alias).note_id"
  case .createdAtAsc:
    return "\(alias).created_at ASC, \(alias).note_id"
  case .updatedAtDesc:
    return "\(alias).updated_at DESC, \(alias).note_id"
  case .title:
    return "lower(coalesce(\(alias).title, \(alias).note_id)) ASC, \(alias).note_id"
  }
}

func notebookSortOrderClause(alias: String, sort: NoteListSort) -> String {
  switch sort {
  case .createdAtDesc:
    return "\(alias).created_at DESC, \(alias).notebook_id"
  case .createdAtAsc:
    return "\(alias).created_at ASC, \(alias).notebook_id"
  case .updatedAtDesc:
    return "\(alias).updated_at DESC, \(alias).notebook_id"
  case .title:
    return "lower(\(alias).title) ASC, \(alias).notebook_id"
  }
}

private func appendTagPredicates(
  alias: String,
  tagFilterIds: [TagID],
  classFilter: [String],
  predicates: inout [String],
  bindings: inout [SQLiteValue]
) {
  if !tagFilterIds.isEmpty {
    predicates.append(
      """
      EXISTS (
        SELECT 1
        FROM note_tags nt
        WHERE nt.note_id = \(alias).note_id
          AND nt.tag_id IN (\(placeholders(count: tagFilterIds.count)))
      )
      """
    )
    bindings.append(contentsOf: tagFilterIds.sqliteBindings)
  }
  if !classFilter.isEmpty {
    predicates.append(
      """
      EXISTS (
        SELECT 1
        FROM note_tags nt
        INNER JOIN tags t ON t.tag_id = nt.tag_id
        WHERE nt.note_id = \(alias).note_id
          AND t.class_id IN (\(placeholders(count: classFilter.count)))
      )
      """
    )
    bindings.append(contentsOf: classFilter.map(SQLiteValue.text))
  }
}

func appendCreatedAtPredicates(
  alias: String,
  createdAfter: String?,
  createdBefore: String?,
  predicates: inout [String],
  bindings: inout [SQLiteValue]
) {
  if let createdAfter = normalizedCreatedAfter(createdAfter) {
    predicates.append("\(alias).created_at >= ?")
    bindings.append(.text(createdAfter))
  }
  if let createdBefore = normalizedCreatedBefore(createdBefore) {
    predicates.append("\(alias).created_at <= ?")
    bindings.append(.text(createdBefore))
  }
}

private func normalizedCreatedAfter(_ value: String?) -> String? {
  normalizedDateBound(value, suffix: "T00:00:00.000Z")
}

private func normalizedCreatedBefore(_ value: String?) -> String? {
  normalizedDateBound(value, suffix: "T23:59:59.999Z")
}

private func normalizedDateBound(_ value: String?, suffix: String) -> String? {
  guard let value else {
    return nil
  }
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else {
    return nil
  }
  if trimmed.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
    return trimmed + suffix
  }
  return trimmed
}

private func appendCreatedAtPredicates(
  alias: String,
  createdAfter: String?,
  createdBefore: String?,
  sql: inout String,
  bindings: inout [SQLiteValue]
) {
  if let createdAfter = normalizedCreatedAfter(createdAfter) {
    sql += "\n  AND \(alias).created_at >= ?"
    bindings.append(.text(createdAfter))
  }
  if let createdBefore = normalizedCreatedBefore(createdBefore) {
    sql += "\n  AND \(alias).created_at <= ?"
    bindings.append(.text(createdBefore))
  }
}

func refreshFTS(noteId: NoteID, previous: FTSPayload?, in database: SQLiteDatabase) throws {
  if let previous {
    try database.execute(
      """
      INSERT INTO note_fts(note_fts, rowid, title, body, tags)
      VALUES('delete', ?, ?, ?, ?)
      """,
      bindings: [
        .int(previous.rowId),
        .text(previous.title),
        .text(previous.body),
        .text(previous.tags)
      ]
    )
    try database.execute("DELETE FROM note_fts_map WHERE note_id = ?", bindings: [.id(noteId)])
  }

  let payload = try currentFTSPayload(noteId: noteId, rowId: previous?.rowId, in: database)
  try database.execute(
    "INSERT INTO note_fts(rowid, title, body, tags) VALUES (?, ?, ?, ?)",
    bindings: [
      .int(payload.rowId),
      .text(payload.title),
      .text(payload.body),
      .text(payload.tags)
    ]
  )
  try database.execute(
    """
    INSERT INTO note_fts_map (fts_rowid, note_id)
    VALUES (?, ?)
    ON CONFLICT(note_id) DO UPDATE SET fts_rowid = excluded.fts_rowid
    """,
    bindings: [.int(payload.rowId), .id(noteId)]
  )
}

func ftsPayload(noteId: NoteID, in database: SQLiteDatabase) throws -> FTSPayload? {
  let rows = try database.query(
    """
    SELECT m.fts_rowid, n.title, n.body_markdown, ifnull((
        SELECT group_concat(ordered_tags.name, ' ')
        FROM (
          SELECT t.name
          FROM note_tags nt
          INNER JOIN tags t ON t.tag_id = nt.tag_id
          WHERE nt.note_id = n.note_id
          ORDER BY t.name
        ) ordered_tags
      ), '') AS tags
    FROM note_fts_map m
    INNER JOIN notes n ON n.note_id = m.note_id
    WHERE m.note_id = ?
    LIMIT 1
    """,
    bindings: [.id(noteId)]
  )
  guard let row = rows.first, let rowIdText = row["fts_rowid"], let rowId = Int64(rowIdText) else {
    return nil
  }
  return FTSPayload(
    rowId: rowId,
    title: row["title"] ?? "",
    body: row["body_markdown"] ?? "",
    tags: row["tags"] ?? ""
  )
}

private func currentFTSPayload(noteId: NoteID, rowId: Int64?, in database: SQLiteDatabase) throws -> FTSPayload {
  // Internal FTS bookkeeping for a note the caller just wrote.
  let note = try loadNote(noteId, in: database)
  let ftsRowId: Int64
  if let rowId {
    ftsRowId = rowId
  } else {
    ftsRowId = try nextFTSRowId(in: database)
  }
  return FTSPayload(
    rowId: ftsRowId,
    title: note.title ?? "",
    body: note.bodyMarkdown,
    tags: note.tags.map(\.tag.name).joined(separator: " ")
  )
}

private func nextFTSRowId(in database: SQLiteDatabase) throws -> Int64 {
  let rows = try database.query("SELECT ifnull(max(fts_rowid), 0) + 1 AS next_rowid FROM note_fts_map")
  return Int64(rows.first?["next_rowid"] ?? "") ?? 1
}

func snippet(from body: String, query: String) -> String {
  let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !normalizedQuery.isEmpty,
        let range = body.range(of: normalizedQuery, options: [.caseInsensitive, .diacriticInsensitive])
  else {
    return String(body.replacingOccurrences(of: "\n", with: " ").prefix(200))
  }
  let lower = body.index(range.lowerBound, offsetBy: -80, limitedBy: body.startIndex) ?? body.startIndex
  let upper = body.index(range.upperBound, offsetBy: 80, limitedBy: body.endIndex) ?? body.endIndex
  return String(body[lower..<upper].replacingOccurrences(of: "\n", with: " "))
}

func placeholders(count: Int) -> String {
  Array(repeating: "?", count: count).joined(separator: ",")
}

func escapedLikePattern(_ value: String) -> String {
  value
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "%", with: "\\%")
    .replacingOccurrences(of: "_", with: "\\_")
}

func ftsMatchQuery(from query: String) -> String? {
  let terms = ftsTerms(from: query)
  guard !terms.isEmpty else {
    return nil
  }
  return terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
    .joined(separator: " ")
}

private func queryHasSubtrigramTerm(_ query: String) -> Bool {
  ftsTerms(from: query).contains { term in
    term.unicodeScalars.count < 3
  }
}

private func ftsTerms(from query: String) -> [String] {
  query.unicodeScalars.split { scalar in
    !CharacterSet.alphanumerics.contains(scalar)
  }.map(String.init).filter { !$0.isEmpty }
}
