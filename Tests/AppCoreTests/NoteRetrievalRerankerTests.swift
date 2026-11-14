import Foundation
@testable import AppCore
import XCTest

final class NoteRetrievalRerankerTests: XCTestCase {
  private func entry(_ id: String, sources: [NoteRetrievalSource] = [], reasons: [SearchEngineHitReasonKind] = []) -> NoteRetrievalCandidateEntry {
    NoteRetrievalCandidateEntry(
      noteId: NoteID(id),
      provenance: NoteRetrievalProvenance(sources: sources, reasons: reasons)
    )
  }

  private func list(
    _ ids: [String],
    label: NoteRetrievalSource? = nil,
    weight: Double = 1,
    tier: NoteRetrievalTier = .direct
  ) -> NoteRetrievalCandidateList {
    NoteRetrievalCandidateList(
      label: label,
      weight: weight,
      tier: tier,
      entries: ids.map { entry($0) }
    )
  }

  func testSingleDirectListPreservesOrderAndScoresDecrease() {
    let results = NoteRetrievalReranker.fuse([list(["a", "b", "c"])], limit: 10)

    XCTAssertEqual(results.map(\.noteId), [NoteID("a"), NoteID("b"), NoteID("c")])
    XCTAssertGreaterThan(results[0].score, results[1].score)
    XCTAssertGreaterThan(results[1].score, results[2].score)
  }

  func testCrossListFusionBreaksScoreTieByIdAndUnionsSources() {
    let results = NoteRetrievalReranker.fuse([
      list(["b", "a", "c"], label: .fullText),
      list(["b", "c", "a"], label: .searchEngine)
    ], limit: 10)

    XCTAssertEqual(results.map(\.noteId), [NoteID("b"), NoteID("a"), NoteID("c")])
    XCTAssertEqual(results[0].provenance.sources, [.searchEngine, .fullText])
    XCTAssertEqual(results[1].score, results[2].score)
  }

  func testScoresAndOrderingMatchExistingGroundingRRF() {
    let input = [
      (weight: 2.0, ids: [NoteID("b"), NoteID("a")]),
      (weight: 1.0, ids: [NoteID("c"), NoteID("b")]),
      (weight: 1.0, ids: [NoteID("a"), NoteID("c")])
    ]
    let expectedScores = reciprocalRankFusion(lists: input)
    let expected = expectedScores.keys.sorted { lhs, rhs in
      let lhsScore = expectedScores[lhs] ?? 0
      let rhsScore = expectedScores[rhs] ?? 0
      if lhsScore != rhsScore { return lhsScore > rhsScore }
      return lhs < rhs
    }
    let actual = NoteRetrievalReranker.fuse(input.map { weight, ids in
      NoteRetrievalCandidateList(
        label: .agentQuery,
        weight: weight,
        tier: .direct,
        entries: ids.map { NoteRetrievalCandidateEntry(noteId: $0, provenance: .init()) }
      )
    }, limit: 10)

    XCTAssertEqual(actual.map(\.noteId), expected)
    for candidate in actual {
      XCTAssertEqual(candidate.score, expectedScores[candidate.noteId])
    }
  }

  func testDuplicateWithinAListCountsOnlyFirstPosition() {
    let results = NoteRetrievalReranker.fuse([list(["a", "a", "b"])], limit: 10)

    XCTAssertEqual(results.map(\.noteId), [NoteID("a"), NoteID("b")])
    XCTAssertEqual(results[0].score, 1 / (NoteRetrievalFusionPolicy.k + 1))
    XCTAssertEqual(results[1].score, 1 / (NoteRetrievalFusionPolicy.k + 2))
  }

  func testDirectTierDominatesNeighborAndDropsNeighborContributionForDirectId() {
    let direct = list(["a"], label: .fullText)
    let neighbor = NoteRetrievalCandidateList(
      label: .graphNeighbor,
      weight: 1,
      tier: .neighbor,
      entries: [entry("a", sources: [.graphNeighbor]), entry("n")]
    )
    let results = NoteRetrievalReranker.fuse([direct, neighbor], limit: 10)

    XCTAssertEqual(results.map(\.noteId), [NoteID("a"), NoteID("n")])
    XCTAssertEqual(results[0].tier, .direct)
    XCTAssertEqual(results[0].provenance.sources, [.fullText])
    XCTAssertEqual(results[1].tier, .neighbor)
  }

  func testReasonsNormalizeToDeclarationOrderAndDeduplicate() {
    let results = NoteRetrievalReranker.fuse([
      NoteRetrievalCandidateList(
        label: nil,
        weight: 1,
        tier: .direct,
        entries: [entry("a", reasons: [.tagMatch, .textMatch, .tagMatch])]
      ),
      NoteRetrievalCandidateList(
        label: nil,
        weight: 1,
        tier: .direct,
        entries: [entry("a", reasons: [.linked])]
      )
    ], limit: 10)

    XCTAssertEqual(results.first?.provenance.reasons, [.textMatch, .tagMatch, .linked])
  }

  func testListCandidateAndOutputCapsAreApplied() {
    let lists = (0..<17).map { index in list(["\(index)"], label: .fullText) }
    let cappedLists = NoteRetrievalReranker.fuse(lists, limit: 100)
    XCTAssertFalse(cappedLists.contains { $0.noteId == NoteID("16") })
    XCTAssertEqual(cappedLists.count, 16)

    let candidates = (0...1000).map(String.init)
    let cappedCandidates = NoteRetrievalReranker.fuse([list(candidates)], limit: 1001)
    XCTAssertEqual(cappedCandidates.count, NoteRetrievalFusionPolicy.maximumFusedWindow)
    XCTAssertFalse(cappedCandidates.contains { $0.noteId == NoteID("1000") })
    XCTAssertEqual(NoteRetrievalReranker.fuse([list(["a", "b", "c"])], limit: 2).count, 2)
  }

  func testEmptyInputAndNonpositiveLimitReturnNoCandidates() {
    XCTAssertTrue(NoteRetrievalReranker.fuse([], limit: 10).isEmpty)
    XCTAssertTrue(NoteRetrievalReranker.fuse([list(["a"])], limit: 0).isEmpty)
    XCTAssertTrue(NoteRetrievalReranker.fuse([list(["a"], weight: 0)], limit: 10).isEmpty)
  }

  func testLegacyNoteSearchResultInitializerDefaultsProvenanceToNil() {
    let note = Note(
      noteId: NoteID("a"),
      notebookId: NotebookID("book"),
      noteNumber: 1,
      title: nil,
      bodyMarkdown: "body",
      readOnly: false,
      createdAt: "2026-01-01",
      updatedAt: "2026-01-01"
    )
    let result = NoteSearchResult(note: note, snippet: "body", rank: 1, matchedTags: [])

    XCTAssertNil(result.provenance)
  }
}
