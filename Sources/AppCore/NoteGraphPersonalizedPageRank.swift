import Foundation

/// Personalized PageRank over the subgraph induced by a search's direct hits
/// and their graph neighbours (`design-docs/specs/note-retrieval-fusion.md`,
/// RF3). Seeds are weighted by lexical rank, so a neighbour of a strong hit
/// gathers more mass than a neighbour of a weak one, and a neighbour reached
/// from several hits accumulates all of their contributions.
enum NoteGraphPageRankPolicy {
  /// HippoRAG 2's damping: half of the mass follows edges, half returns to the
  /// seeds each step, which keeps the walk close to the query.
  static let damping = 0.5
  static let iterations = 20
  /// Seed weight is `1 / (seedK + position)`, the same reciprocal-rank form the
  /// lexical fusion uses.
  static let seedK = 60.0
}

struct WeightedGraphEdge<Node: Hashable>: Equatable {
  var source: Node
  var destination: Node
  var weight: Double
}

typealias NoteGraphWeightedEdge = WeightedGraphEdge<NoteID>

/// Pure power iteration: `p <- d * W^T p + (1 - d) * s`, where `W` is the
/// edge-weight matrix row-normalised by weighted degree (a hub spreads its
/// mass thin instead of dominating) and `s` is the normalised personalization
/// vector. `p` is renormalised each step so a node without out-edges does
/// not leak mass. Nodes absent from `personalization` start at zero.
func personalizedPageRank<Node: Hashable>(
  nodes: [Node],
  edges: [WeightedGraphEdge<Node>],
  personalization: [Node: Double],
  damping: Double = NoteGraphPageRankPolicy.damping,
  iterations: Int = NoteGraphPageRankPolicy.iterations
) -> [Node: Double] {
  let nodeSet = Set(nodes)
  guard !nodeSet.isEmpty else {
    return [:]
  }
  let seedTotal = personalization.filter { nodeSet.contains($0.key) && $0.value > 0 }.values.reduce(0, +)
  guard seedTotal > 0 else {
    return Dictionary(uniqueKeysWithValues: nodeSet.map { ($0, 0.0) })
  }
  let seeds = personalization.compactMapValues { $0 > 0 ? $0 / seedTotal : nil }
    .filter { nodeSet.contains($0.key) }

  var outgoing: [Node: [(Node, Double)]] = [:]
  var weightedDegree: [Node: Double] = [:]
  for edge in edges where edge.weight > 0 && nodeSet.contains(edge.source) && nodeSet.contains(edge.destination) {
    outgoing[edge.source, default: []].append((edge.destination, edge.weight))
    weightedDegree[edge.source, default: 0] += edge.weight
  }

  var mass = seeds
  for _ in 0..<max(0, iterations) {
    var next: [Node: Double] = seeds.mapValues { $0 * (1 - damping) }
    for (source, sourceMass) in mass where sourceMass > 0 {
      guard let neighbours = outgoing[source], let degree = weightedDegree[source], degree > 0 else {
        continue
      }
      for (destination, weight) in neighbours {
        next[destination, default: 0] += damping * sourceMass * weight / degree
      }
    }
    let total = next.values.reduce(0, +)
    mass = total > 0 ? next.mapValues { $0 / total } : seeds
  }
  var result = Dictionary(uniqueKeysWithValues: nodeSet.map { ($0, 0.0) })
  for (node, value) in mass {
    result[node] = value
  }
  return result
}

/// Undirected explicit-link and shared-tag edges among a bounded note set.
/// Explicit links weigh 1; a shared tag weighs `sharedTagWeight` (the
/// traversal's idf form) for the rarest tag the pair shares. Structural tags
/// are skipped the way the traversal skips them. Both directions are emitted.
func graphEdgesAmong(
  noteIds: [NoteID],
  scope: NoteSearchScope?,
  in database: SQLiteDatabase
) throws -> [NoteGraphWeightedEdge] {
  let ids = orderedUnique(noteIds)
  guard ids.count >= 2 else {
    return []
  }
  var edges: [NoteGraphWeightedEdge] = []
  let idPlaceholders = placeholders(count: ids.count)
  let linkRows = try database.query(
    """
    SELECT from_note_id, to_note_id
    FROM note_links
    WHERE from_note_id IN (\(idPlaceholders)) AND to_note_id IN (\(idPlaceholders))
    ORDER BY from_note_id, to_note_id
    """,
    bindings: ids.sqliteBindings + ids.sqliteBindings
  )
  for row in linkRows {
    guard let from = row.identifier("from_note_id", as: NoteID.self),
          let to = row.identifier("to_note_id", as: NoteID.self),
          from != to else {
      continue
    }
    edges.append(NoteGraphWeightedEdge(source: from, destination: to, weight: 1))
    edges.append(NoteGraphWeightedEdge(source: to, destination: from, weight: 1))
  }

  let noteCount = try graphNoteCount(scope: scope, in: database)
  guard noteCount > 0 else {
    return edges
  }
  var frequencyPredicates: [String] = []
  var frequencyBindings: [SQLiteValue] = []
  appendGraphScopePredicates(
    alias: "frequency_note",
    scope: scope,
    predicates: &frequencyPredicates,
    bindings: &frequencyBindings
  )
  let frequencyWhere = frequencyPredicates.isEmpty ? "" : "WHERE \(frequencyPredicates.joined(separator: " AND "))"
  let tagRows = try database.query(
    """
    WITH tag_frequency AS (
      SELECT note_tags.tag_id, count(DISTINCT note_tags.note_id) AS note_count
      FROM note_tags
      INNER JOIN notes frequency_note ON frequency_note.note_id = note_tags.note_id
      \(frequencyWhere)
      GROUP BY note_tags.tag_id
    )
    SELECT a.note_id AS source_note_id, b.note_id AS destination_note_id,
      min(tag_frequency.note_count) AS winning_tag_note_count
    FROM note_tags a
    INNER JOIN note_tags b ON b.tag_id = a.tag_id AND b.note_id <> a.note_id
    INNER JOIN tags t ON t.tag_id = a.tag_id
    INNER JOIN tag_frequency ON tag_frequency.tag_id = a.tag_id
    WHERE a.note_id IN (\(idPlaceholders)) AND b.note_id IN (\(idPlaceholders))
      AND t.is_system = 0
      AND t.class_id <> 'document-kind'
      AND t.name NOT LIKE 'notebook-kind:%'
    GROUP BY a.note_id, b.note_id
    ORDER BY a.note_id, b.note_id
    """,
    bindings: frequencyBindings + ids.sqliteBindings + ids.sqliteBindings
  )
  for row in tagRows {
    guard let source = row.identifier("source_note_id", as: NoteID.self),
          let destination = row.identifier("destination_note_id", as: NoteID.self),
          let frequency = Int(row["winning_tag_note_count"] ?? "") else {
      continue
    }
    edges.append(NoteGraphWeightedEdge(
      source: source,
      destination: destination,
      weight: sharedTagWeight(noteCount: noteCount, tagNoteCount: frequency)
    ))
  }
  return edges
}

/// Orders graph neighbours by the mass they gather from the direct hits.
/// Direct hits are seeds only; they are never returned here. Ties fall back to
/// the traversal weight and then the note id, so a single seed with a single
/// candidate reproduces the previous order.
func rankNeighborsByPersonalizedPageRank(
  directResults: [NoteSearchResult],
  neighbors: [NoteSearchResult],
  scope: NoteSearchScope?,
  in database: SQLiteDatabase
) throws -> [NoteSearchResult] {
  guard !neighbors.isEmpty else {
    return []
  }
  let seedIds = directResults.map(\.note.noteId)
  let neighborIds = neighbors.map(\.note.noteId)
  let nodes = orderedUnique(seedIds + neighborIds)
  let edges = try graphEdgesAmong(noteIds: nodes, scope: scope, in: database)
  var personalization: [NoteID: Double] = [:]
  for (position, seedId) in seedIds.enumerated() where personalization[seedId] == nil {
    personalization[seedId] = 1 / (NoteGraphPageRankPolicy.seedK + Double(position))
  }
  let mass = personalizedPageRank(
    nodes: nodes,
    edges: edges,
    personalization: personalization
  )
  return neighbors
    .map { neighbor -> (NoteSearchResult, Double) in
      (neighbor, mass[neighbor.note.noteId] ?? 0)
    }
    .sorted { lhs, rhs in
      if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
      if lhs.0.rank != rhs.0.rank { return lhs.0.rank > rhs.0.rank }
      return lhs.0.note.noteId < rhs.0.note.noteId
    }
    .map { neighbor, pageRankMass in
      var ranked = neighbor
      ranked.rank = pageRankMass
      return ranked
    }
}
