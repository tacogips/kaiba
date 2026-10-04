import Foundation
@testable import AppCore

final class FakeSearchEngine: SearchEngine, @unchecked Sendable {
  private let lock = NSLock()
  private var storedDocuments: [NoteID: SearchIndexDocument] = [:]
  private var storedAppliedBatches: [[SearchIndexOperation]] = []
  private var storedSearches: [SearchEngineQuery] = []
  private var storedRelated: [SearchEngineRelatedQuery] = []
  private var storedEnsureIndexCount = 0
  private var storedHealthCalls = 0
  private var storedFailure: SearchEngineError?
  private var storedFailingNoteIds: Set<NoteID> = []
  private var storedScriptedHits: [SearchEngineHit]?
  private var storedOnApply: (@Sendable ([SearchIndexOperation]) -> Void)?

  let indexIdentity: String

  init(indexIdentity: String = "fake:v1") {
    self.indexIdentity = indexIdentity
  }

  var documents: [NoteID: SearchIndexDocument] { lock.withLock { storedDocuments } }
  var appliedBatches: [[SearchIndexOperation]] { lock.withLock { storedAppliedBatches } }
  var recordedSearches: [SearchEngineQuery] { lock.withLock { storedSearches } }
  var recordedRelated: [SearchEngineRelatedQuery] { lock.withLock { storedRelated } }
  var ensureIndexCount: Int { lock.withLock { storedEnsureIndexCount } }
  var healthCalls: Int { lock.withLock { storedHealthCalls } }

  var failure: SearchEngineError? {
    get { lock.withLock { storedFailure } }
    set { lock.withLock { storedFailure = newValue } }
  }

  var failingNoteIds: Set<NoteID> {
    get { lock.withLock { storedFailingNoteIds } }
    set { lock.withLock { storedFailingNoteIds = newValue } }
  }

  var scriptedHits: [SearchEngineHit]? {
    get { lock.withLock { storedScriptedHits } }
    set { lock.withLock { storedScriptedHits = newValue } }
  }

  var onApply: (@Sendable ([SearchIndexOperation]) -> Void)? {
    get { lock.withLock { storedOnApply } }
    set { lock.withLock { storedOnApply = newValue } }
  }

  func health() async throws -> SearchEngineHealth {
    try lock.withLock {
      storedHealthCalls += 1
      if let storedFailure { throw storedFailure }
      return SearchEngineHealth(isAvailable: true, detail: "fake")
    }
  }

  func ensureIndex() async throws {
    try lock.withLock {
      storedEnsureIndexCount += 1
      if let storedFailure { throw storedFailure }
    }
  }

  func apply(_ operations: [SearchIndexOperation]) async throws -> [SearchIndexOperationResult] {
    let (error, failingIds, callback) = lock.withLock {
      (storedFailure, storedFailingNoteIds, storedOnApply)
    }
    if let error { throw error }
    callback?(operations)

    return lock.withLock {
      storedAppliedBatches.append(operations)
      return operations.map { operation in
        let noteId = operation.noteId
        guard !failingIds.contains(noteId) else {
          return SearchIndexOperationResult(noteId: noteId, outcome: .failed("fake failure"))
        }
        switch operation {
        case let .upsert(document):
          storedDocuments[noteId] = document
        case .delete:
          storedDocuments.removeValue(forKey: noteId)
        }
        return SearchIndexOperationResult(noteId: noteId, outcome: .succeeded)
      }
    }
  }

  func search(_ query: SearchEngineQuery) async throws -> [SearchEngineHit] {
    let snapshot = try lock.withLock { () throws -> ([SearchIndexDocument], [SearchEngineHit]?) in
      if let storedFailure { throw storedFailure }
      storedSearches.append(query)
      return (Array(storedDocuments.values), storedScriptedHits)
    }
    if let scriptedHits = snapshot.1 { return scriptedHits }

    let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let hits = snapshot.0
      .filter { document in
        let searchable = [document.title, document.body, document.tagNames.joined(separator: " "), document.context]
          .joined(separator: " ").lowercased()
        return searchable.contains(text) && matches(query.filter, document: document)
      }
      .sorted { $0.noteId < $1.noteId }
      .dropFirst(max(0, query.from))
      .prefix(max(0, query.size))
    return hits.map { SearchEngineHit(noteId: $0.noteId, score: 1, highlight: nil) }
  }

  func relatedNotes(_ query: SearchEngineRelatedQuery) async throws -> [SearchEngineHit] {
    let snapshot = try lock.withLock { () throws -> ([SearchIndexDocument], [SearchEngineHit]?) in
      if let storedFailure { throw storedFailure }
      storedRelated.append(query)
      return (Array(storedDocuments.values), storedScriptedHits)
    }
    if let scriptedHits = snapshot.1 { return scriptedHits }

    let sourceTokens = tokens(query.likeText)
    let hits = snapshot.0
      .filter { document in
        let searchable = [document.title, document.body, document.tagNames.joined(separator: " "), document.context]
          .joined(separator: " ")
        return !sourceTokens.isDisjoint(with: tokens(searchable)) && matches(query.filter, document: document)
      }
      .sorted { $0.noteId < $1.noteId }
      .prefix(max(0, query.size))
    return hits.map { SearchEngineHit(noteId: $0.noteId, score: 1, highlight: nil) }
  }

  private func matches(_ filter: SearchEngineFilter, document: SearchIndexDocument) -> Bool {
    if let libraryIds = filter.libraryIds, !libraryIds.contains(document.libraryId) { return false }
    if let ownerUserId = filter.ownerUserId, document.ownerUserId != ownerUserId { return false }
    if let notebookId = filter.notebookId, document.notebookId != notebookId { return false }
    if !filter.tagIds.isEmpty && filter.tagIds.allSatisfy({ !document.tagIds.contains($0) }) { return false }
    if filter.excludesLongTermMemory && document.isLongTermMemory { return false }
    return !filter.excludedNoteIds.contains(document.noteId)
  }

  private func tokens(_ text: String) -> Set<String> {
    Set(text.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }.filter { $0.count >= 2 })
  }
}
