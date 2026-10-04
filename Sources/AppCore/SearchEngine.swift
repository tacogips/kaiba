import Foundation

/// The engine boundary described in `design-docs/specs/search-engine-adapter.md`.
/// Callers depend only on this protocol so adapters can change independently.
public protocol SearchEngine: Sendable {
  var indexIdentity: String { get }
  func health() async throws -> SearchEngineHealth
  func ensureIndex() async throws
  func apply(_ operations: [SearchIndexOperation]) async throws -> [SearchIndexOperationResult]
  func search(_ query: SearchEngineQuery) async throws -> [SearchEngineHit]
  func relatedNotes(_ query: SearchEngineRelatedQuery) async throws -> [SearchEngineHit]
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
    updatedAt: String
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

  public init(
    libraryIds: [LibraryID]?,
    ownerUserId: UserID?,
    notebookId: NotebookID?,
    tagIds: [TagID],
    excludesLongTermMemory: Bool,
    excludedNoteIds: [NoteID]
  ) {
    self.libraryIds = libraryIds
    self.ownerUserId = ownerUserId
    self.notebookId = notebookId
    self.tagIds = tagIds
    self.excludesLongTermMemory = excludesLongTermMemory
    self.excludedNoteIds = excludedNoteIds
  }
}

public struct SearchEngineQuery: Equatable, Sendable {
  public var text: String
  public var filter: SearchEngineFilter
  public var from: Int
  public var size: Int

  public init(text: String, filter: SearchEngineFilter, from: Int, size: Int) {
    self.text = text
    self.filter = filter
    self.from = from
    self.size = size
  }
}

public struct SearchEngineRelatedQuery: Equatable, Sendable {
  public var likeText: String
  public var filter: SearchEngineFilter
  public var size: Int

  public init(likeText: String, filter: SearchEngineFilter, size: Int) {
    self.likeText = likeText
    self.filter = filter
    self.size = size
  }
}

public struct SearchEngineHit: Equatable, Sendable {
  public var noteId: NoteID
  public var score: Double
  public var highlight: String?

  public init(noteId: NoteID, score: Double, highlight: String?) {
    self.noteId = noteId
    self.score = score
    self.highlight = highlight
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

  public init(note: Note, snippet: String, score: Double) {
    self.note = note
    self.snippet = snippet
    self.score = score
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
