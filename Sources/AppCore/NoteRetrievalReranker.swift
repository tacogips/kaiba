import Foundation

public enum NoteRetrievalSource: String, CaseIterable, Equatable, Sendable {
  case searchEngine = "search-engine"
  case fullText = "full-text"
  case agentQuery = "agent-query"
  case graphNeighbor = "graph-neighbor"
}

public struct NoteRetrievalProvenance: Equatable, Sendable {
  public var sources: [NoteRetrievalSource]
  public var reasons: [SearchEngineHitReasonKind]

  public init(sources: [NoteRetrievalSource] = [], reasons: [SearchEngineHitReasonKind] = []) {
    self.sources = sources
    self.reasons = reasons
  }

  func normalized() -> Self {
    Self(
      sources: NoteRetrievalSource.allCases.filter { sources.contains($0) },
      reasons: NoteRetrievalReranker.reasonOrder.filter { reasons.contains($0) }
    )
  }
}

public struct NoteRetrievalOutcome: Equatable, Sendable {
  public var results: [NoteSearchResult]
  public var usedSearchEngine: Bool

  public init(results: [NoteSearchResult], usedSearchEngine: Bool) {
    self.results = results
    self.usedSearchEngine = usedSearchEngine
  }
}

enum NoteRetrievalTier: Equatable, Sendable {
  case direct
  case neighbor
}

struct NoteRetrievalCandidateEntry: Equatable {
  var noteId: NoteID
  var provenance: NoteRetrievalProvenance
}

struct NoteRetrievalCandidateList {
  var label: NoteRetrievalSource?
  var weight: Double
  var tier: NoteRetrievalTier
  var entries: [NoteRetrievalCandidateEntry]
}

struct NoteRetrievalFusedCandidate: Equatable {
  var noteId: NoteID
  var score: Double
  var tier: NoteRetrievalTier
  var provenance: NoteRetrievalProvenance
}

enum NoteRetrievalFusionPolicy {
  static let k = NoteSearchFusionPolicy.reciprocalRankK
  static let maximumLists = 16
  static let maximumCandidatesPerList = 1000
  static let maximumEngineCandidates = 200
  static let maximumFusedWindow = 1000
}

enum NoteRetrievalReranker {
  static let reasonOrder: [SearchEngineHitReasonKind] = [
    .textMatch, .tagMatch, .tagHierarchyMatch, .textSimilarity,
    .sharedTag, .relatedTag, .sharedEntity, .linked
  ]

  private struct Accumulator {
    var noteId: NoteID
    var score: Double
    var tier: NoteRetrievalTier
    var sources: [NoteRetrievalSource]
    var reasons: [SearchEngineHitReasonKind]
  }

  static func fuse(_ lists: [NoteRetrievalCandidateList], limit: Int) -> [NoteRetrievalFusedCandidate] {
    guard limit > 0 else { return [] }
    let boundedLists = Array(lists.prefix(NoteRetrievalFusionPolicy.maximumLists))
    var directIds = Set<NoteID>()
    var rankedLists: [(list: NoteRetrievalCandidateList, entries: [NoteRetrievalCandidateEntry])] = []

    for list in boundedLists where list.weight > 0 {
      var seen = Set<NoteID>()
      let entries = list.entries
        .prefix(NoteRetrievalFusionPolicy.maximumCandidatesPerList)
        .filter { seen.insert($0.noteId).inserted }
      if list.tier == .direct {
        directIds.formUnion(entries.map(\.noteId))
      }
      rankedLists.append((list, entries))
    }

    var orderedIds: [NoteID] = []
    var indexById: [NoteID: Int] = [:]
    var accumulated: [Accumulator] = []
    for rankedList in rankedLists {
      for (index, entry) in rankedList.entries.enumerated() {
        if rankedList.list.tier == .neighbor, directIds.contains(entry.noteId) {
          continue
        }
        let tier: NoteRetrievalTier = directIds.contains(entry.noteId) ? .direct : .neighbor
        let score = rankedList.list.weight / (NoteRetrievalFusionPolicy.k + Double(index + 1))
        var sources = entry.provenance.sources
        if let label = rankedList.list.label {
          sources.append(label)
        }
        if let existingIndex = indexById[entry.noteId] {
          accumulated[existingIndex].score += score
          accumulated[existingIndex].sources.append(contentsOf: sources)
          accumulated[existingIndex].reasons.append(contentsOf: entry.provenance.reasons)
        } else {
          indexById[entry.noteId] = orderedIds.count
          orderedIds.append(entry.noteId)
          accumulated.append(Accumulator(
            noteId: entry.noteId,
            score: score,
            tier: tier,
            sources: sources,
            reasons: entry.provenance.reasons
          ))
        }
      }
    }

    let candidates = accumulated.map { candidate in
      NoteRetrievalFusedCandidate(
        noteId: candidate.noteId,
        score: candidate.score,
        tier: candidate.tier,
        provenance: NoteRetrievalProvenance(
          sources: candidate.sources,
          reasons: candidate.reasons
        ).normalized()
      )
    }
    return candidates.sorted { lhs, rhs in
      if lhs.tier != rhs.tier { return lhs.tier == .direct }
      if lhs.score != rhs.score { return lhs.score > rhs.score }
      return lhs.noteId < rhs.noteId
    }.prefix(min(limit, NoteRetrievalFusionPolicy.maximumFusedWindow)).map { $0 }
  }
}
