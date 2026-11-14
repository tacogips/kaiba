import Foundation
@testable import AppCore
import XCTest

final class AgenticGroundingEngineTests: NoteTestCase {
  private struct LegacyGrounding {
    var noteMatches: [NoteSearchResult]
    var relatedNotes: [NoteSearchResult]
    var context: String
  }

  func testFtsGroundingKeepsLegacyOrderAndContextWithoutProvenance() throws {
    let service = try makeService(function: #function)
    let pepper = try service.createNote(bodyMarkdown: "# Pepper\nblack pepper sauce recipe")
    let sauce = try service.createNote(bodyMarkdown: "# Sauce\nsauce only")
    let linked = try service.createNote(bodyMarkdown: "# Linked\nnothing")
    _ = try service.linkNotes(from: pepper.noteId, to: linked.noteId)
    let query = "pepper sauce"
    let terms = AIAgenticSearchService.grepTerms(from: query)
    let expected = try legacyGrounding(terms: terms, notebookId: nil, limit: 10, service: service)

    let actual = try AIAgenticSearchService.groundingResults(
      query: query,
      terms: terms,
      notebookId: nil,
      limit: 10,
      service: service
    )
    let actualContext = AIAgenticSearchService.grepContextMarkdown(
      query: query,
      noteMatches: actual.noteMatches,
      relatedNotes: actual.relatedNotes,
      memoMatches: []
    )

    XCTAssertEqual(actual.noteMatches.map(\.note.noteId), expected.noteMatches.map(\.note.noteId))
    XCTAssertEqual(actualContext, expected.context)
    XCTAssertFalse(actualContext.contains("[sources:"))
    XCTAssertEqual(actual.noteMatches.map(\.note.noteId), [pepper.noteId, sauce.noteId])
    XCTAssertEqual(actual.relatedNotes.map(\.note.noteId), [linked.noteId])
  }

  func testEngineOnlyGroundingCarriesProvenanceAndUsesOneRequestPerTerm() async throws {
    let service = try makeService(function: #function)
    let note = try service.createNote(bodyMarkdown: "# Engine vault\nStored without any query words.")
    let query = "find pepper sauce"
    let terms = AIAgenticSearchService.grepTerms(from: query)
    let engine = RecordingGroundingSearchEngine(hitsByQuery: Dictionary(
      uniqueKeysWithValues: terms.map { ($0, [SearchEngineHit(noteId: note.noteId, score: 1, highlight: nil)]) }
    ))
    let enabled = service
    enabled.searchEngine = engine

    let outcome = try await AIAgenticSearchService.engineGroundingResults(
      query: query,
      terms: terms,
      notebookId: nil,
      limit: 10,
      service: enabled
    )
    let grounding = try XCTUnwrap(outcome)
    let match = try XCTUnwrap(grounding.noteMatches.first)
    let context = AIAgenticSearchService.grepContextMarkdown(
      query: query,
      noteMatches: grounding.noteMatches,
      relatedNotes: grounding.relatedNotes,
      memoMatches: []
    )

    XCTAssertEqual(grounding.noteMatches.map(\.note.noteId), [note.noteId])
    XCTAssertTrue(match.provenance?.sources.contains(.searchEngine) == true)
    XCTAssertTrue(context.contains("[sources: search-engine"))
    XCTAssertEqual(engine.recordedSearches.count, terms.count)
  }

  func testNonFirstTermAddsAgentQueryProvenance() async throws {
    let service = try makeService(function: #function)
    let note = try service.createNote(bodyMarkdown: "# Saffron\nAn engine-only note.")
    let engine = RecordingGroundingSearchEngine(hitsByQuery: [
      "saffron": [SearchEngineHit(noteId: note.noteId, score: 1, highlight: "saffron engine result")]
    ])
    let enabled = service
    enabled.searchEngine = engine
    let terms = AIAgenticSearchService.grepTerms(from: "find saffron")

    let outcome = try await AIAgenticSearchService.engineGroundingResults(
      query: "find saffron",
      terms: terms,
      notebookId: nil,
      limit: 10,
      service: enabled
    )
    let grounding = try XCTUnwrap(outcome)

    XCTAssertEqual(grounding.noteMatches.map(\.note.noteId), [note.noteId])
    XCTAssertTrue(grounding.noteMatches[0].provenance?.sources.contains(.agentQuery) == true)
    XCTAssertEqual(engine.recordedSearches.map(\.text), terms)
  }

  func testFirstEngineFailureStopsPassAndSearchUsesExactFtsContext() async throws {
    let baseline = try makeService(function: #function)
    _ = try baseline.createNote(bodyMarkdown: "# Fallback\npepper sauce planning details")
    let expectedInvoker = ContextCapturingInvoker()
    _ = try await AIAgenticSearchService(service: baseline, invoker: expectedInvoker)
      .search(query: "which notes mention pepper sauce")
    let enabled = baseline
    let engine = RecordingGroundingSearchEngine(
      hitsByQuery: [:],
      failingQueries: ["which notes mention pepper sauce"]
    )
    enabled.searchEngine = engine
    let actualInvoker = ContextCapturingInvoker()
    let terms = AIAgenticSearchService.grepTerms(from: "which notes mention pepper sauce")

    let failedPass = try await AIAgenticSearchService.engineGroundingResults(
      query: "which notes mention pepper sauce",
      terms: terms,
      notebookId: nil,
      limit: 10,
      service: enabled
    )
    _ = try await AIAgenticSearchService(service: enabled, invoker: actualInvoker)
      .search(query: "which notes mention pepper sauce")
    let actualRequest = await actualInvoker.latestRequest()
    let expectedRequest = await expectedInvoker.latestRequest()

    XCTAssertNil(failedPass)
    XCTAssertEqual(engine.recordedSearches.count, 2)
    XCTAssertEqual(actualRequest?.contextMarkdown, expectedRequest?.contextMarkdown)
  }

  func testFullQueryLinkedNeighborStaysInRelatedNotes() async throws {
    let service = try makeService(function: #function)
    let seed = try service.createNote(bodyMarkdown: "# Engine seed\nNo query terms in this text.")
    let neighbor = try service.createNote(bodyMarkdown: "# Neighbor\nAlso unrelated text.")
    _ = try service.linkNotes(from: seed.noteId, to: neighbor.noteId)
    let query = "find saffron"
    let terms = AIAgenticSearchService.grepTerms(from: query)
    let engine = RecordingGroundingSearchEngine(hitsByQuery: Dictionary(
      uniqueKeysWithValues: terms.map { ($0, [SearchEngineHit(noteId: seed.noteId, score: 1, highlight: nil)]) }
    ))
    let enabled = service
    enabled.searchEngine = engine

    let outcome = try await AIAgenticSearchService.engineGroundingResults(
      query: query,
      terms: terms,
      notebookId: nil,
      limit: 10,
      service: enabled
    )
    let grounding = try XCTUnwrap(outcome)

    XCTAssertEqual(grounding.noteMatches.map(\.note.noteId), [seed.noteId])
    XCTAssertEqual(grounding.relatedNotes.map(\.note.noteId), [neighbor.noteId])
    XCTAssertTrue(grounding.relatedNotes[0].isLinkedNeighbor)
  }

  private func legacyGrounding(
    terms: [String],
    notebookId: NotebookID?,
    limit: Int,
    service: NoteService
  ) throws -> LegacyGrounding {
    var scores: [NoteID: Double] = [:]
    var resultsById: [NoteID: NoteSearchResult] = [:]
    var relatedNotes: [NoteSearchResult] = []
    for (termIndex, term) in terms.enumerated() {
      let results = try service.searchNotes(
        query: term,
        notebookId: notebookId,
        includeLinked: termIndex == 0,
        depth: 1,
        limit: limit
      )
      var directIds: [NoteID] = []
      for result in results {
        if result.isLinkedNeighbor {
          if resultsById[result.note.noteId] == nil,
             !relatedNotes.contains(where: { $0.note.noteId == result.note.noteId }) {
            relatedNotes.append(result)
          }
          continue
        }
        directIds.append(result.note.noteId)
        if resultsById[result.note.noteId] == nil { resultsById[result.note.noteId] = result }
      }
      for (rank, noteId) in directIds.enumerated() {
        scores[noteId, default: 0] += Double(termIndex == 0 ? 2 : 1) / (60 + Double(rank + 1))
      }
    }
    let noteMatches = scores.sorted { lhs, rhs in
      if lhs.value != rhs.value { return lhs.value > rhs.value }
      return lhs.key < rhs.key
    }.prefix(limit).compactMap { resultsById[$0.key] }
    let matchedIds = Set(noteMatches.map(\.note.noteId))
    let keptRelated = Array(relatedNotes.filter { !matchedIds.contains($0.note.noteId) }.prefix(limit))
    let context = AIAgenticSearchService.grepContextMarkdown(
      query: "pepper sauce",
      noteMatches: noteMatches,
      relatedNotes: keptRelated,
      memoMatches: []
    )
    return LegacyGrounding(noteMatches: noteMatches, relatedNotes: keptRelated, context: context)
  }
}

private final class RecordingGroundingSearchEngine: SearchEngine, @unchecked Sendable {
  let indexIdentity = "test:agentic-grounding"
  private let lock = NSLock()
  private let hitsByQuery: [String: [SearchEngineHit]]
  private let failingQueries: Set<String>
  private var searches: [SearchEngineQuery] = []

  init(hitsByQuery: [String: [SearchEngineHit]], failingQueries: Set<String> = []) {
    self.hitsByQuery = hitsByQuery
    self.failingQueries = failingQueries
  }

  var recordedSearches: [SearchEngineQuery] { lock.withLock { searches } }

  func health() async throws -> SearchEngineHealth {
    SearchEngineHealth(isAvailable: true, detail: "test")
  }

  func ensureIndex() async throws {}

  func apply(_ operations: [SearchIndexOperation]) async throws -> [SearchIndexOperationResult] {
    operations.map { SearchIndexOperationResult(noteId: $0.noteId, outcome: .succeeded) }
  }

  func search(_ query: SearchEngineQuery) async throws -> [SearchEngineHit] {
    let shouldFail = lock.withLock {
      searches.append(query)
      return failingQueries.contains(query.text)
    }
    if shouldFail { throw SearchEngineError.unavailable("test failure") }
    return hitsByQuery[query.text] ?? []
  }

  func relatedNotes(_ query: SearchEngineRelatedQuery) async throws -> [SearchEngineHit] { [] }
}

private actor ContextCapturingInvoker: AgentInvoking {
  private var request: AgentInvocationRequest?

  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    self.request = request
    return AgentInvocationResult(markdown: "captured")
  }

  func latestRequest() -> AgentInvocationRequest? { request }
}
