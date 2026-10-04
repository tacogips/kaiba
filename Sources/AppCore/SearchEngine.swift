import Foundation

/// The engine boundary described in `design-docs/specs/search-engine-adapter.md`.
/// Callers depend only on this protocol so adapters can change independently.
public protocol SearchEngine: Sendable {
  var indexIdentity: String { get }
  func health() async throws -> SearchEngineHealth
  func ensureIndex() async throws
  func apply(_ operations: [SearchIndexOperation]) async throws -> [SearchIndexOperationResult]
  func search(_ query: SearchEngineQuery) async throws -> [SearchEngineHit]
  func searchPage(_ query: SearchEngineQuery) async throws -> SearchEngineSearchPage
  func relatedNotes(_ query: SearchEngineRelatedQuery) async throws -> [SearchEngineHit]
}

public extension SearchEngine {
  func searchPage(_ query: SearchEngineQuery) async throws -> SearchEngineSearchPage {
    SearchEngineSearchPage(hits: try await search(query), facets: nil)
  }
}

public struct SearchIndexTagApplication: Equatable, Sendable {
  public var tagId: TagID
  public var provenance: String

  public init(tagId: TagID, provenance: String) {
    self.tagId = tagId
    self.provenance = provenance
  }
}

public struct SearchIndexPathTag: Equatable, Sendable {
  public var tagId: TagID
  public var name: String
  public var tagClass: String?
  public var isDirect: Bool

  public init(tagId: TagID, name: String, tagClass: String?, isDirect: Bool) {
    self.tagId = tagId
    self.name = name
    self.tagClass = tagClass
    self.isDirect = isDirect
  }
}

public struct SearchIndexDocument: Equatable, Sendable {
  public var noteId: NoteID
  public var notebookId: NotebookID
  public var libraryId: LibraryID
  public var ownerUserId: UserID?
  public var title: String
  public var body: String
  public var tagIds: [TagID]
  public var tagNames: [String]
  public var context: String
  public var isLongTermMemory: Bool
  public var createdAt: String
  public var updatedAt: String
  public var tagApplications: [SearchIndexTagApplication]
  public var pathTags: [SearchIndexPathTag]
  public var outgoingLinkNoteIds: [NoteID]
  public var incomingLinkNoteIds: [NoteID]

  public init(
    noteId: NoteID,
    notebookId: NotebookID,
    libraryId: LibraryID,
    ownerUserId: UserID?,
    title: String,
    body: String,
    tagIds: [TagID],
    tagNames: [String],
    context: String,
    isLongTermMemory: Bool,
    createdAt: String,
    updatedAt: String,
    tagApplications: [SearchIndexTagApplication] = [],
    pathTags: [SearchIndexPathTag] = [],
    outgoingLinkNoteIds: [NoteID] = [],
    incomingLinkNoteIds: [NoteID] = []
  ) {
    self.noteId = noteId
    self.notebookId = notebookId
    self.libraryId = libraryId
    self.ownerUserId = ownerUserId
    self.title = title
    self.body = body
    self.tagIds = tagIds
    self.tagNames = tagNames
    self.context = context
    self.isLongTermMemory = isLongTermMemory
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.tagApplications = tagApplications
    self.pathTags = pathTags
    self.outgoingLinkNoteIds = outgoingLinkNoteIds
    self.incomingLinkNoteIds = incomingLinkNoteIds
  }
}

public enum SearchIndexOperation: Equatable, Sendable {
  case upsert(SearchIndexDocument)
  case delete(NoteID)

  public var noteId: NoteID {
    switch self {
    case let .upsert(document): document.noteId
    case let .delete(noteId): noteId
    }
  }
}

public struct SearchIndexOperationResult: Equatable, Sendable {
  public var noteId: NoteID
  public var outcome: SearchIndexOperationOutcome

  public init(noteId: NoteID, outcome: SearchIndexOperationOutcome) {
    self.noteId = noteId
    self.outcome = outcome
  }
}

public enum SearchIndexOperationOutcome: Equatable, Sendable {
  case succeeded
  case failed(String)
}

public struct SearchEngineFilter: Equatable, Sendable {
  public var libraryIds: [LibraryID]?
  public var ownerUserId: UserID?
  public var notebookId: NotebookID?
  public var tagIds: [TagID]
  public var excludesLongTermMemory: Bool
  public var excludedNoteIds: [NoteID]
  public var hierarchyTagIds: [TagID]
  public var tagClassFilters: [SearchEngineTagClassFilter]

  public init(
    libraryIds: [LibraryID]?,
    ownerUserId: UserID?,
    notebookId: NotebookID?,
    tagIds: [TagID],
    excludesLongTermMemory: Bool,
    excludedNoteIds: [NoteID],
    hierarchyTagIds: [TagID] = [],
    tagClassFilters: [SearchEngineTagClassFilter] = []
  ) {
    self.libraryIds = libraryIds
    self.ownerUserId = ownerUserId
    self.notebookId = notebookId
    self.tagIds = tagIds
    self.excludesLongTermMemory = excludesLongTermMemory
    self.excludedNoteIds = excludedNoteIds
    self.hierarchyTagIds = hierarchyTagIds
    self.tagClassFilters = tagClassFilters
  }
}

public struct SearchEngineTagClassFilter: Equatable, Sendable {
  public var tagClass: String
  public var tagId: TagID?

  public init(tagClass: String, tagId: TagID? = nil) {
    self.tagClass = tagClass
    self.tagId = tagId
  }
}

public struct SearchEngineFacetRequest: Equatable, Sendable {
  public var tagClassLimit: Int
  public var tagLimit: Int

  public init(tagClassLimit: Int = 10, tagLimit: Int = 15) {
    self.tagClassLimit = tagClassLimit
    self.tagLimit = tagLimit
  }
}

public struct SearchEngineFacetBucket: Equatable, Sendable {
  public var value: String
  public var count: Int

  public init(value: String, count: Int) {
    self.value = value
    self.count = count
  }
}

public struct SearchEngineFacets: Equatable, Sendable {
  public var tagClasses: [SearchEngineFacetBucket]
  public var tags: [SearchEngineFacetBucket]

  public init(tagClasses: [SearchEngineFacetBucket], tags: [SearchEngineFacetBucket]) {
    self.tagClasses = tagClasses
    self.tags = tags
  }
}

public struct SearchEngineSearchPage: Equatable, Sendable {
  public var hits: [SearchEngineHit]
  public var facets: SearchEngineFacets?

  public init(hits: [SearchEngineHit], facets: SearchEngineFacets?) {
    self.hits = hits
    self.facets = facets
  }
}

public struct SearchEngineQuery: Equatable, Sendable {
  public var text: String
  public var filter: SearchEngineFilter
  public var from: Int
  public var size: Int
  public var expansionTagIds: [TagID]
  public var facets: SearchEngineFacetRequest?

  public init(
    text: String,
    filter: SearchEngineFilter,
    from: Int,
    size: Int,
    expansionTagIds: [TagID] = [],
    facets: SearchEngineFacetRequest? = nil
  ) {
    self.text = text
    self.filter = filter
    self.from = from
    self.size = size
    self.expansionTagIds = expansionTagIds
    self.facets = facets
  }
}

public struct SearchEngineRelatedQuery: Equatable, Sendable {
  public var likeText: String
  public var filter: SearchEngineFilter
  public var size: Int
  public var signals: SearchEngineRelatedSignals?

  public init(
    likeText: String,
    filter: SearchEngineFilter,
    size: Int,
    signals: SearchEngineRelatedSignals? = nil
  ) {
    self.likeText = likeText
    self.filter = filter
    self.size = size
    self.signals = signals
  }
}

public struct SearchEngineHit: Equatable, Sendable {
  public var noteId: NoteID
  public var score: Double
  public var highlight: String?
  public var reasons: [SearchEngineHitReason]

  public init(noteId: NoteID, score: Double, highlight: String?, reasons: [SearchEngineHitReason] = []) {
    self.noteId = noteId
    self.score = score
    self.highlight = highlight
    self.reasons = reasons
  }
}

public enum SearchEngineHitReasonKind: String, Equatable, Sendable {
  case textMatch = "text-match"
  case tagMatch = "tag-match"
  case tagHierarchyMatch = "tag-hierarchy-match"
  case textSimilarity = "text-similarity"
  case sharedTag = "shared-tag"
  case relatedTag = "related-tag"
  case sharedEntity = "shared-entity"
  case linked
}

public struct SearchEngineHitReason: Equatable, Sendable {
  public var kind: SearchEngineHitReasonKind
  public var tagNames: [String]

  public init(kind: SearchEngineHitReasonKind, tagNames: [String] = []) {
    self.kind = kind
    self.tagNames = tagNames
  }
}

public struct SearchEngineClassTag: Equatable, Sendable {
  public var tagClass: String
  public var tagId: TagID

  public init(tagClass: String, tagId: TagID) {
    self.tagClass = tagClass
    self.tagId = tagId
  }
}

public struct SearchEngineRelatedSignals: Equatable, Sendable {
  public var sourceNoteId: NoteID
  public var sharedTagIds: [TagID]
  public var nearTagIds: [TagID]
  public var ancestorTagIds: [TagID]
  public var entityTags: [SearchEngineClassTag]

  public init(
    sourceNoteId: NoteID,
    sharedTagIds: [TagID],
    nearTagIds: [TagID],
    ancestorTagIds: [TagID],
    entityTags: [SearchEngineClassTag]
  ) {
    self.sourceNoteId = sourceNoteId
    self.sharedTagIds = sharedTagIds
    self.nearTagIds = nearTagIds
    self.ancestorTagIds = ancestorTagIds
    self.entityTags = entityTags
  }
}

public struct SearchEngineHealth: Equatable, Sendable {
  public var isAvailable: Bool
  public var detail: String

  public init(isAvailable: Bool, detail: String) {
    self.isAvailable = isAvailable
    self.detail = detail
  }
}

public struct NoteEngineSearchHit: Equatable, Sendable {
  public var note: Note
  public var snippet: String
  public var score: Double
  public var reasons: [SearchEngineHitReason]

  public init(note: Note, snippet: String, score: Double, reasons: [SearchEngineHitReason] = []) {
    self.note = note
    self.snippet = snippet
    self.score = score
    self.reasons = reasons
  }
}

public struct NoteEngineTagFacet: Equatable, Sendable {
  public var tagId: TagID
  public var name: String
  public var tagClass: String?
  public var count: Int

  public init(tagId: TagID, name: String, tagClass: String?, count: Int) {
    self.tagId = tagId
    self.name = name
    self.tagClass = tagClass
    self.count = count
  }
}

public struct NoteEngineSearchFacets: Equatable, Sendable {
  public var tagClasses: [SearchEngineFacetBucket]
  public var tags: [NoteEngineTagFacet]

  public init(tagClasses: [SearchEngineFacetBucket], tags: [NoteEngineTagFacet]) {
    self.tagClasses = tagClasses
    self.tags = tags
  }
}

public struct NoteEngineSearchPage: Equatable, Sendable {
  public var hits: [NoteEngineSearchHit]
  public var facets: NoteEngineSearchFacets?

  public init(hits: [NoteEngineSearchHit], facets: NoteEngineSearchFacets?) {
    self.hits = hits
    self.facets = facets
  }
}

public enum SearchEngineError: Error, Equatable, Sendable, CustomStringConvertible {
  case notConfigured
  case unavailable(String)
  case rejected(status: Int, reason: String)
  case invalidResponse(String)

  public var description: String {
    switch self {
    case .notConfigured:
      "search engine is not configured"
    case let .unavailable(detail):
      "search engine unavailable: \(detail)"
    case let .rejected(status, reason):
      "search engine rejected the request (HTTP \(status)): \(reason)"
    case let .invalidResponse(detail):
      "search engine returned an invalid response: \(detail)"
    }
  }
}

public extension SearchEngine {
  func upsert(_ document: SearchIndexDocument) async throws -> SearchIndexOperationResult {
    try await apply([.upsert(document)])[0]
  }

  func delete(noteId: NoteID) async throws -> SearchIndexOperationResult {
    try await apply([.delete(noteId)])[0]
  }
}
