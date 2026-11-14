import Foundation

public enum NoteGraphEdgeKind: String, Codable, Equatable, Sendable {
  case explicitLink = "explicit-link"
  case sharedTag = "shared-tag"
  case lexical
}

public struct NoteGraphNeighbor: Equatable, Sendable {
  public var seedNoteId: String
  public var note: Note
  public var edgeKind: NoteGraphEdgeKind
  public var weight: Double
  public var hopCount: Int
  public var pathNoteIds: [String]

  public init(
    seedNoteId: String,
    note: Note,
    edgeKind: NoteGraphEdgeKind,
    weight: Double,
    hopCount: Int,
    pathNoteIds: [String]
  ) {
    self.seedNoteId = seedNoteId
    self.note = note
    self.edgeKind = edgeKind
    self.weight = weight
    self.hopCount = hopCount
    self.pathNoteIds = pathNoteIds
  }
}

public enum NoteGraphPolicy {
  public static let defaultMaxDepth = 5
  public static let maximumDepth = 5
  public static let associationMaxDepth = 2
  public static let defaultLimit = 16
  public static let maximumLimit = 20
  public static let maximumSeedCount = 20
  public static let sourceCandidateLimit = 20
  public static let originCandidateLimit = 20
  public static let frontierLimit = 40
  public static let finalizedNodeLimit = 20
  public static let lexicalTermLimit = 8
  public static let lexicalRowsPerTermLimit = 20
  public static let hopDecay = 0.5
  public static let relevanceFloor = 0.03
}

public extension NoteService {
  func graphNeighbors(
    noteIds: [String],
    maxDepth: Int = NoteGraphPolicy.defaultMaxDepth,
    limit: Int = NoteGraphPolicy.defaultLimit
  ) throws -> [NoteGraphNeighbor] {
    try driver.withDatabase { database in
      try noteGraphNeighborsInDatabase(
        noteIds: noteIds,
        maxDepth: maxDepth,
        limit: limit,
        resultExclusions: [],
        in: database
      )
    }
  }
}
