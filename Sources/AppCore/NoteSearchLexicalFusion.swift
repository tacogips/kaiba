import Foundation

/// Constants for the staged lexical pipeline
/// (`design-docs/specs/note-retrieval-fusion.md`, RF2).
enum NoteSearchFusionPolicy {
  /// bm25 with explicit column weights: title, body, tags, context. A title or
  /// tag hit outranks a body hit; the contextual breadcrumb counts like body
  /// text so a notebook title cannot swamp the note's own words.
  static let weightedBM25 = "bm25(note_fts, 3.0, 1.0, 2.0, 1.0)"
  /// Reciprocal rank fusion constant. 60 is the value the original RRF paper
  /// and the surveyed hybrid studies use.
  static let reciprocalRankK = 60.0
  /// Terms considered by the relaxed stage; longer queries are truncated.
  static let maximumTerms = 8
  /// Rows fetched per term before fusion.
  static let perTermCandidateLimit = 50
  /// Trigram tokens cannot match shorter terms.
  static let minimumIndexableTermScalars = 3
}

/// Reciprocal rank fusion over several ranked id lists. Each list contributes
/// `weight / (k + position)` for every id it holds (position is 1-based).
func reciprocalRankFusion<ID: Hashable>(
  lists: [(weight: Double, ids: [ID])],
  k: Double = NoteSearchFusionPolicy.reciprocalRankK
) -> [ID: Double] {
  var scores: [ID: Double] = [:]
  for list in lists {
    for (index, id) in list.ids.enumerated() {
      scores[id, default: 0] += list.weight / (k + Double(index + 1))
    }
  }
  return scores
}

/// Query terms the trigram index can match, deduplicated case-insensitively
/// and capped at `maximumTerms`.
func indexableSearchTerms(from query: String) -> [String] {
  var seen = Set<String>()
  return ftsTerms(from: query)
    .filter { $0.unicodeScalars.count >= NoteSearchFusionPolicy.minimumIndexableTermScalars }
    .filter { seen.insert($0.lowercased()).inserted }
    .prefix(NoteSearchFusionPolicy.maximumTerms)
    .map { $0 }
}

private struct RelaxedTermHit {
  var matchedTermCount: Int
  var fusedScore: Double
}

/// The relaxed stage: every indexable term is matched on its own and the
/// per-term rankings are fused. Runs only for queries with at least two
/// indexable terms; the strict stage already covers one-term queries. Strict
/// hits are excluded so a note is never listed twice, and the same scope,
/// tag, class, and date predicates apply.
func relaxedTermSearchResults(
  query: String,
  tagFilterIds: [TagID],
  classFilter: [String],
  scope: NoteSearchScope,
  excludedNoteIds: Set<NoteID>,
  sort: NoteListSort,
  limit: Int,
  in database: SQLiteDatabase
) throws -> [NoteSearchResult] {
  let terms = indexableSearchTerms(from: query)
  guard terms.count >= 2, limit > 0 else {
    return []
  }
  var perTermLists: [(weight: Double, ids: [NoteID])] = []
  var matchedTermCounts: [NoteID: Int] = [:]
  for term in terms {
    let ids = try ftsCandidateNoteIds(
      matchQuery: ftsMatchQuery(from: term) ?? "",
      tagFilterIds: tagFilterIds,
      classFilter: classFilter,
      scope: scope,
      excludedNoteIds: excludedNoteIds,
      sort: sort,
      limit: NoteSearchFusionPolicy.perTermCandidateLimit,
      in: database
    )
    perTermLists.append((weight: 1, ids: ids))
    for id in ids {
      matchedTermCounts[id, default: 0] += 1
    }
  }
  let fused = reciprocalRankFusion(lists: perTermLists)
  let hits = fused.map { id, score in
    (id, RelaxedTermHit(matchedTermCount: matchedTermCounts[id] ?? 0, fusedScore: score))
  }
  guard !hits.isEmpty else {
    return []
  }
  let notesById = try requireNotes(hits.map(\.0), in: database)
  let ordered = hits.sorted { lhs, rhs in
    if lhs.1.matchedTermCount != rhs.1.matchedTermCount {
      return lhs.1.matchedTermCount > rhs.1.matchedTermCount
    }
    if lhs.1.fusedScore != rhs.1.fusedScore {
      return lhs.1.fusedScore > rhs.1.fusedScore
    }
    guard let lhsNote = notesById[lhs.0], let rhsNote = notesById[rhs.0] else {
      return lhs.0 < rhs.0
    }
    return noteSortPrecedes(lhsNote, rhsNote, sort: sort)
  }
  return try ordered.prefix(limit).map { id, hit in
    guard let note = notesById[id] else {
      throw NoteServiceError.notFound("note not found: \(id)")
    }
    return NoteSearchResult(
      note: note,
      snippet: snippet(from: note.bodyMarkdown, query: relaxedSnippetQuery(terms: terms, body: note.bodyMarkdown)),
      rank: hit.fusedScore,
      matchedTags: note.tags.map(\.tag),
      termCoverage: Double(hit.matchedTermCount) / Double(terms.count)
    )
  }
}

/// The first query term the body actually contains, so a relaxed hit's
/// snippet is centred on matched text rather than falling back to the head of
/// the note.
private func relaxedSnippetQuery(terms: [String], body: String) -> String {
  terms.first { body.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil } ?? ""
}

/// One scoped FTS lookup returning note ids in bm25 order. Shared by the
/// relaxed stage and the agent-facing term queries.
func ftsCandidateNoteIds(
  matchQuery: String,
  tagFilterIds: [TagID],
  classFilter: [String],
  scope: NoteSearchScope,
  excludedNoteIds: Set<NoteID>,
  sort: NoteListSort,
  limit: Int,
  in database: SQLiteDatabase
) throws -> [NoteID] {
  guard !matchQuery.isEmpty, limit > 0 else {
    return []
  }
  var predicates: [String] = ["note_fts MATCH ?"]
  var bindings: [SQLiteValue] = [.text(matchQuery)]
  if let notebookId = scope.notebookId {
    predicates.append("n.notebook_id = ?")
    bindings.append(.id(notebookId))
  }
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
  if !excludedNoteIds.isEmpty {
    predicates.append("n.note_id NOT IN (\(placeholders(count: excludedNoteIds.count)))")
    bindings.append(contentsOf: excludedNoteIds.sorted().sqliteBindings)
  }
  bindings.append(.int(Int64(limit)))
  return try database.query(
    """
    SELECT m.note_id, \(NoteSearchFusionPolicy.weightedBM25) AS rank
    FROM note_fts
    INNER JOIN note_fts_map m ON m.fts_rowid = note_fts.rowid
    INNER JOIN notes n ON n.note_id = m.note_id
    WHERE \(predicates.joined(separator: "\n  AND "))
    ORDER BY rank, \(noteSortOrderClause(alias: "n", sort: sort))
    LIMIT ?
    """,
    bindings: bindings
  ).compactMap { $0.identifier("note_id", as: NoteID.self) }
}

/// In-memory equivalent of `noteSortOrderClause` for lists that are ordered
/// after fusion rather than by SQL.
func noteSortPrecedes(_ lhs: Note, _ rhs: Note, sort: NoteListSort) -> Bool {
  switch sort {
  case .createdAtDesc:
    if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
  case .createdAtAsc:
    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
  case .updatedAtDesc:
    if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
  case .title:
    let lhsTitle = (lhs.title ?? lhs.noteId.rawValue).lowercased()
    let rhsTitle = (rhs.title ?? rhs.noteId.rawValue).lowercased()
    if lhsTitle != rhsTitle { return lhsTitle < rhsTitle }
  }
  return lhs.noteId < rhs.noteId
}
