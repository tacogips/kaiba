import Foundation

private struct NoteGraphPath {
  var seedNoteId: NoteID
  var destinationNoteId: NoteID
  var terminalEdgeKind: NoteGraphEdgeKind
  var score: Double
  var hopCount: Int
  var noteIds: [NoteID]
}

private struct NoteGraphEdge {
  var destinationNoteId: NoteID
  var kind: NoteGraphEdgeKind
  var weight: Double
}

private struct NoteGraphTraversalState {
  var pending: [NoteID: NoteGraphPath] = [:]
  var finalized = Set<NoteID>()
  var eligibleResults: [NoteGraphPath] = []
}

func noteGraphNeighborsInDatabase(
  noteIds: [NoteID],
  maxDepth: Int,
  limit: Int,
  resultExclusions: Set<NoteID>,
  in database: SQLiteDatabase
) throws -> [NoteGraphNeighbor] {
  guard maxDepth >= 0 else {
    throw NoteServiceError.invalidInput("note graph depth must not be negative")
  }
  guard limit >= 0 else {
    throw NoteServiceError.invalidInput("note graph limit must not be negative")
  }
  let seeds = orderedUnique(noteIds)
  guard seeds.count <= NoteGraphPolicy.maximumSeedCount else {
    throw NoteServiceError.invalidInput(
      "note graph accepts at most \(NoteGraphPolicy.maximumSeedCount) distinct seed note ids"
    )
  }
  guard !seeds.isEmpty, maxDepth > 0, limit > 0 else {
    return []
  }
  let notesById = try requireNotes(seeds, in: database)
  for seed in seeds where notesById[seed] == nil {
    throw NoteServiceError.notFound("note not found: \(seed)")
  }

  let normalizedDepth = min(maxDepth, NoteGraphPolicy.maximumDepth)
  let normalizedLimit = min(limit, NoteGraphPolicy.maximumLimit)
  let noteCount = try graphNoteCount(in: database)
  let seedSet = Set(seeds)
  var state = NoteGraphTraversalState()

  for seed in seeds {
    let seedPath = NoteGraphPath(
      seedNoteId: seed,
      destinationNoteId: seed,
      terminalEdgeKind: .explicitLink,
      score: 1,
      hopCount: 0,
      noteIds: [seed]
    )
    try offerGraphExpansions(
      from: seedPath,
      seeds: seedSet,
      noteCount: noteCount,
      state: &state,
      database: database
    )
  }

  // Excluded destinations (already-linked notes for proposals, direct hits for
  // search expansion) are finalized for cycle avoidance but must not consume
  // the eligible-result budget: a hub note with 20+ existing links would
  // otherwise exhaust finalizedNodeLimit before any real candidate finalizes.
  // Work stays bounded because the allowance is capped by the caller-provided
  // exclusion set's size.
  let explorationLimit = NoteGraphPolicy.finalizedNodeLimit + resultExclusions.count
  while state.eligibleResults.count < normalizedLimit,
        state.finalized.count < explorationLimit,
        let path = popBestGraphPath(from: &state.pending) {
    guard state.finalized.insert(path.destinationNoteId).inserted else {
      continue
    }
    if !resultExclusions.contains(path.destinationNoteId) {
      state.eligibleResults.append(path)
    }
    guard state.eligibleResults.count < normalizedLimit,
          state.finalized.count < explorationLimit,
          path.hopCount < normalizedDepth else {
      continue
    }
    try offerGraphExpansions(
      from: path,
      seeds: seedSet,
      noteCount: noteCount,
      state: &state,
      database: database
    )
  }

  let resultPaths = state.eligibleResults.sorted(by: graphPublicOrder)
  let resultNotes = try requireNotes(resultPaths.map(\.destinationNoteId), in: database)
  return try resultPaths.map { path in
    guard let note = resultNotes[path.destinationNoteId] else {
      throw NoteServiceError.notFound("note not found: \(path.destinationNoteId)")
    }
    return NoteGraphNeighbor(
      seedNoteId: path.seedNoteId,
      note: note,
      edgeKind: path.terminalEdgeKind,
      weight: path.score,
      hopCount: path.hopCount,
      pathNoteIds: path.noteIds
    )
  }
}

private func offerGraphExpansions(
  from path: NoteGraphPath,
  seeds: Set<NoteID>,
  noteCount: Int,
  state: inout NoteGraphTraversalState,
  database: SQLiteDatabase
) throws {
  let invalidDestinations = seeds
    .union(path.noteIds)
    .union(state.finalized)
  var edges = try explicitGraphEdges(
    from: path,
    excluding: invalidDestinations,
    database: database
  )
  edges.append(contentsOf: try sharedTagGraphEdges(
    from: path,
    noteCount: noteCount,
    excluding: invalidDestinations,
    database: database
  ))
  if path.hopCount == 0 {
    edges.append(contentsOf: try lexicalGraphEdges(
      from: path,
      excluding: invalidDestinations,
      database: database
    ))
  }

  var bestByDestination: [NoteID: NoteGraphPath] = [:]
  for edge in edges {
    let candidate = NoteGraphPath(
      seedNoteId: path.seedNoteId,
      destinationNoteId: edge.destinationNoteId,
      terminalEdgeKind: edge.kind,
      score: path.score * edge.weight * NoteGraphPolicy.hopDecay,
      hopCount: path.hopCount + 1,
      noteIds: path.noteIds + [edge.destinationNoteId]
    )
    guard candidate.score >= NoteGraphPolicy.relevanceFloor else {
      continue
    }
    if let current = bestByDestination[edge.destinationNoteId],
       !graphEvidenceOrder(candidate, current) {
      continue
    }
    bestByDestination[edge.destinationNoteId] = candidate
  }

  let offered = bestByDestination.values
    .sorted(by: graphPublicOrder)
    .prefix(NoteGraphPolicy.originCandidateLimit)
  for candidate in offered {
    offerGraphPath(candidate, to: &state.pending)
  }
}

private func explicitGraphEdges(
  from path: NoteGraphPath,
  excluding invalidDestinations: Set<NoteID>,
  database: SQLiteDatabase
) throws -> [NoteGraphEdge] {
  let candidateScore = path.score * NoteGraphPolicy.hopDecay
  guard candidateScore >= NoteGraphPolicy.relevanceFloor else {
    return []
  }
  let excluded = invalidDestinations.sorted()
  var sql = """
    SELECT destination_note_id
    FROM (
      SELECT to_note_id AS destination_note_id
      FROM note_links
      WHERE from_note_id = ?
      UNION
      SELECT from_note_id AS destination_note_id
      FROM note_links
      WHERE to_note_id = ?
    )
    """
  var bindings: [SQLiteValue] = [
    .id(path.destinationNoteId),
    .id(path.destinationNoteId)
  ]
  if !excluded.isEmpty {
    sql += " WHERE destination_note_id NOT IN (\(placeholders(count: excluded.count)))"
    bindings.append(contentsOf: excluded.sqliteBindings)
  }
  sql += " ORDER BY destination_note_id LIMIT ?"
  bindings.append(.int(Int64(NoteGraphPolicy.sourceCandidateLimit)))
  return try database.query(sql, bindings: bindings).compactMap { row in
    row.identifier("destination_note_id", as: NoteID.self).map {
      NoteGraphEdge(destinationNoteId: $0, kind: .explicitLink, weight: 1)
    }
  }
}

private func sharedTagGraphEdges(
  from path: NoteGraphPath,
  noteCount: Int,
  excluding invalidDestinations: Set<NoteID>,
  database: SQLiteDatabase
) throws -> [NoteGraphEdge] {
  guard noteCount > 0,
        let maximumTagFrequency = maximumEligibleTagFrequency(pathScore: path.score, noteCount: noteCount)
  else {
    return []
  }
  let excluded = invalidDestinations.sorted()
  var sql = """
    WITH eligible_origin_tags AS (
      SELECT t.tag_id
      FROM note_tags origin
      INNER JOIN tags t ON t.tag_id = origin.tag_id
      INNER JOIN tag_classes tc ON tc.class_id = t.class_id
      WHERE origin.note_id = ?
        AND t.is_system = 0
        AND t.class_id <> 'document-kind'
        AND t.name NOT LIKE 'notebook-kind:%'
    ), tag_frequency AS (
      SELECT note_tags.tag_id, count(DISTINCT note_tags.note_id) AS note_count
      FROM note_tags
      INNER JOIN eligible_origin_tags ON eligible_origin_tags.tag_id = note_tags.tag_id
      GROUP BY note_tags.tag_id
    )
    SELECT other.note_id AS destination_note_id,
      min(tag_frequency.note_count) AS winning_tag_note_count
    FROM note_tags other
    INNER JOIN eligible_origin_tags ON eligible_origin_tags.tag_id = other.tag_id
    INNER JOIN tag_frequency ON tag_frequency.tag_id = other.tag_id
    WHERE other.note_id <> ?
    """
  var bindings: [SQLiteValue] = [
    .id(path.destinationNoteId),
    .id(path.destinationNoteId)
  ]
  if !excluded.isEmpty {
    sql += " AND other.note_id NOT IN (\(placeholders(count: excluded.count)))"
    bindings.append(contentsOf: excluded.sqliteBindings)
  }
  sql += """
    GROUP BY other.note_id
    HAVING min(tag_frequency.note_count) <= ?
    ORDER BY winning_tag_note_count, destination_note_id
    LIMIT ?
    """
  bindings.append(.int(Int64(maximumTagFrequency)))
  bindings.append(.int(Int64(NoteGraphPolicy.sourceCandidateLimit)))
  return try database.query(sql, bindings: bindings).compactMap { row in
    guard let destination = row.identifier("destination_note_id", as: NoteID.self),
          let frequencyText = row["winning_tag_note_count"],
          let frequency = Int(frequencyText) else {
      return nil
    }
    return NoteGraphEdge(
      destinationNoteId: destination,
      kind: .sharedTag,
      weight: sharedTagWeight(noteCount: noteCount, tagNoteCount: frequency)
    )
  }
}

private func lexicalGraphEdges(
  from path: NoteGraphPath,
  excluding invalidDestinations: Set<NoteID>,
  database: SQLiteDatabase
) throws -> [NoteGraphEdge] {
  // The seed was reached through a library-filtered candidate query; this is
  // the row read for it, not an authorization point.
  let seed = try loadNote(path.destinationNoteId, in: database)
  let terms = noteGraphTerms(from: [seed.title, seed.bodyMarkdown].compactMap { $0 }.joined(separator: "\n"))
  guard !terms.isEmpty else {
    return []
  }
  let excluded = invalidDestinations.sorted()
  var matches: [NoteID: Set<Int>] = [:]
  for (termIndex, term) in terms.enumerated() {
    var sql = """
      SELECT m.note_id, bm25(note_fts) AS rank
      FROM note_fts
      INNER JOIN note_fts_map m ON m.fts_rowid = note_fts.rowid
      WHERE note_fts MATCH ?
      """
    var bindings: [SQLiteValue] = [.text(graphFTSMatchQuery(term))]
    if !excluded.isEmpty {
      sql += " AND m.note_id NOT IN (\(placeholders(count: excluded.count)))"
      bindings.append(contentsOf: excluded.sqliteBindings)
    }
    sql += " ORDER BY rank, m.note_id LIMIT ?"
    bindings.append(.int(Int64(NoteGraphPolicy.lexicalRowsPerTermLimit)))
    for row in try database.query(sql, bindings: bindings) {
      guard let destination = row.identifier("note_id", as: NoteID.self) else {
        continue
      }
      matches[destination, default: []].insert(termIndex)
    }
  }
  return matches.map { destination, matchedTerms in
    let ratio = Double(matchedTerms.count) / Double(terms.count)
    return NoteGraphEdge(
      destinationNoteId: destination,
      kind: .lexical,
      weight: 0.10 + (0.15 * ratio)
    )
  }.filter { path.score * $0.weight * NoteGraphPolicy.hopDecay >= NoteGraphPolicy.relevanceFloor }
    .sorted {
      if $0.weight != $1.weight {
        return $0.weight > $1.weight
      }
      return $0.destinationNoteId < $1.destinationNoteId
    }
    .prefix(NoteGraphPolicy.sourceCandidateLimit)
    .map { $0 }
}

func noteGraphTerms(from text: String) -> [String] {
  var seen = Set<String>()
  var terms: [String] = []
  var current = String.UnicodeScalarView()
  func flush() {
    let term = String(current)
    current.removeAll(keepingCapacity: true)
    guard term.count >= 4, seen.insert(term.lowercased()).inserted else {
      return
    }
    terms.append(term)
  }
  for scalar in text.unicodeScalars {
    if CharacterSet.alphanumerics.contains(scalar) {
      current.append(scalar)
    } else {
      flush()
    }
    if terms.count >= NoteGraphPolicy.lexicalTermLimit {
      break
    }
  }
  if terms.count < NoteGraphPolicy.lexicalTermLimit {
    flush()
  }
  return Array(terms.prefix(NoteGraphPolicy.lexicalTermLimit))
}

private func graphFTSMatchQuery(_ term: String) -> String {
  "\"\(term.replacingOccurrences(of: "\"", with: "\"\""))\""
}

private func graphNoteCount(in database: SQLiteDatabase) throws -> Int {
  let rows = try database.query("SELECT count(*) AS note_count FROM notes")
  return Int(rows.first?["note_count"] ?? "") ?? 0
}

private func sharedTagWeight(noteCount: Int, tagNoteCount: Int) -> Double {
  let numerator = log(Double(noteCount + 1) / Double(tagNoteCount + 1))
  let denominator = log(Double(noteCount + 1))
  let idf = denominator > 0 ? numerator / denominator : 0
  return 0.30 + (0.35 * idf)
}

private func maximumEligibleTagFrequency(pathScore: Double, noteCount: Int) -> Int? {
  // sharedTagWeight is strictly decreasing in tagNoteCount, so eligibility is
  // monotone (true up to a boundary frequency, false after). Binary-search the
  // boundary instead of scanning 1...noteCount linearly: this runs once per
  // expanded node per hop and the linear scan is O(noteCount) log() calls on
  // large stores.
  guard noteCount >= 1 else {
    return nil
  }
  func eligible(_ frequency: Int) -> Bool {
    pathScore * sharedTagWeight(noteCount: noteCount, tagNoteCount: frequency)
      * NoteGraphPolicy.hopDecay >= NoteGraphPolicy.relevanceFloor
  }
  guard eligible(1) else {
    return nil
  }
  if eligible(noteCount) {
    return noteCount
  }
  var lastEligible = 1
  var firstIneligible = noteCount
  while firstIneligible - lastEligible > 1 {
    let middle = lastEligible + (firstIneligible - lastEligible) / 2
    if eligible(middle) {
      lastEligible = middle
    } else {
      firstIneligible = middle
    }
  }
  return lastEligible
}

private func offerGraphPath(_ path: NoteGraphPath, to pending: inout [NoteID: NoteGraphPath]) {
  if let current = pending[path.destinationNoteId], !graphEvidenceOrder(path, current) {
    return
  }
  pending[path.destinationNoteId] = path
  guard pending.count > NoteGraphPolicy.frontierLimit else {
    return
  }
  let retainedIds = Set(pending.values.sorted(by: graphPublicOrder)
    .prefix(NoteGraphPolicy.frontierLimit)
    .map(\.destinationNoteId))
  pending = pending.filter { retainedIds.contains($0.key) }
}

private func popBestGraphPath(from pending: inout [NoteID: NoteGraphPath]) -> NoteGraphPath? {
  guard let best = pending.values.sorted(by: graphPublicOrder).first else {
    return nil
  }
  pending.removeValue(forKey: best.destinationNoteId)
  return best
}

private func graphPublicOrder(_ lhs: NoteGraphPath, _ rhs: NoteGraphPath) -> Bool {
  if lhs.score != rhs.score {
    return lhs.score > rhs.score
  }
  return lhs.destinationNoteId < rhs.destinationNoteId
}

private func graphEvidenceOrder(_ lhs: NoteGraphPath, _ rhs: NoteGraphPath) -> Bool {
  if lhs.score != rhs.score {
    return lhs.score > rhs.score
  }
  if lhs.hopCount != rhs.hopCount {
    return lhs.hopCount < rhs.hopCount
  }
  let lhsKind = graphEdgeKindPrecedence(lhs.terminalEdgeKind)
  let rhsKind = graphEdgeKindPrecedence(rhs.terminalEdgeKind)
  if lhsKind != rhsKind {
    return lhsKind < rhsKind
  }
  if lhs.seedNoteId != rhs.seedNoteId {
    return lhs.seedNoteId < rhs.seedNoteId
  }
  return lhs.noteIds.rawValues.joined(separator: "\u{0}") < rhs.noteIds.rawValues.joined(separator: "\u{0}")
}

private func graphEdgeKindPrecedence(_ kind: NoteGraphEdgeKind) -> Int {
  switch kind {
  case .explicitLink:
    return 0
  case .sharedTag:
    return 1
  case .lexical:
    return 2
  }
}
