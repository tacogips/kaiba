import Foundation
@testable import AppCore
import XCTest

/// `design-docs/specs/note-retrieval-fusion.md`: contextual indexing (RF1),
/// relaxed term matching with reciprocal rank fusion (RF2), personalized
/// PageRank over the neighbour subgraph (RF3), recency-aware memory recall
/// (RF4), and fused agentic grounding (RF5).
final class NoteRetrievalFusionTests: NoteTestCase {
  private func ids(_ results: [NoteSearchResult]) -> [NoteID] {
    results.map(\.note.noteId)
  }

  // MARK: - RF1 contextual index column

  func testSearchMatchesNotebookTitleAndTagAncestorContext() throws {
    let service = try makeService()
    let notebook = try service.createNotebook(title: "Kubernetes migration")
    let parent = try service.defineTag(name: "infrastructure", classId: TagClassID("topic"))
    _ = try service.defineTag(name: "networking", classId: TagClassID("topic"), parentTagId: parent.tagId)
    let note = try service.createNote(
      notebookId: notebook.notebookId,
      bodyMarkdown: "# Step 3\nDrain the nodes before upgrading",
      tags: [NoteTagInput(name: "networking", classId: TagClassID("topic"))]
    )
    _ = try service.createNote(bodyMarkdown: "# Unrelated\nGrocery list")

    XCTAssertEqual(ids(try service.searchNotes(query: "Kubernetes")), [note.noteId])
    XCTAssertEqual(ids(try service.searchNotes(query: "infrastructure")), [note.noteId])
    XCTAssertEqual(ids(try service.searchNotes(query: "networking")), [note.noteId])
    try assertSearchIndexIntegrity(service)
  }

  func testTagReparentRefreshesTheContextColumnWithoutCorruptingTheIndex() throws {
    let service = try makeService()
    let oldParent = try service.defineTag(name: "infrastructure", classId: TagClassID("topic"))
    let newParent = try service.defineTag(name: "platform", classId: TagClassID("topic"))
    _ = try service.defineTag(name: "networking", classId: TagClassID("topic"), parentTagId: oldParent.tagId)
    let note = try service.createNote(
      bodyMarkdown: "# Routing\nBGP session notes",
      tags: [NoteTagInput(name: "networking", classId: TagClassID("topic"))]
    )
    XCTAssertEqual(ids(try service.searchNotes(query: "infrastructure")), [note.noteId])

    _ = try service.defineTag(name: "networking", classId: TagClassID("topic"), parentTagId: newParent.tagId)

    XCTAssertEqual(ids(try service.searchNotes(query: "platform")), [note.noteId])
    XCTAssertTrue(try service.searchNotes(query: "infrastructure").isEmpty)
    try assertSearchIndexIntegrity(service)

    // The delete path must repeat the stored context payload exactly.
    try service.deleteNote(noteId: note.noteId)
    XCTAssertTrue(try service.searchNotes(query: "platform").isEmpty)
    try assertSearchIndexIntegrity(service)
  }

  func testNoteTextStillOutranksContextOnlyMatches() throws {
    let service = try makeService()
    let notebook = try service.createNotebook(title: "Kubernetes migration")
    let contextOnly = try service.createNote(
      notebookId: notebook.notebookId,
      bodyMarkdown: "# Step 3\nDrain the nodes before upgrading"
    )
    let textual = try service.createNote(bodyMarkdown: "# Cluster\nKubernetes upgrade checklist")

    XCTAssertEqual(ids(try service.searchNotes(query: "Kubernetes")), [textual.noteId, contextOnly.noteId])
  }

  // MARK: - RF2 relaxed matching and coverage

  func testRelaxedSearchRanksFullMatchBeforePartialAndReportsCoverage() throws {
    let service = try makeService()
    let full = try service.createNote(bodyMarkdown: "# Full\nalpha beta gamma")
    let partial = try service.createNote(bodyMarkdown: "# Partial\nalpha beta only")
    let single = try service.createNote(bodyMarkdown: "# Single\ngamma only")
    _ = try service.createNote(bodyMarkdown: "# None\nnothing here")

    let results = try service.searchNotes(query: "alpha beta gamma", limit: 10)

    XCTAssertEqual(ids(results), [full.noteId, partial.noteId, single.noteId])
    XCTAssertEqual(results.map(\.termCoverage), [1, 2.0 / 3.0, 1.0 / 3.0])
    XCTAssertTrue(results[1].snippet.localizedCaseInsensitiveContains("alpha"))
    XCTAssertTrue(results[2].snippet.localizedCaseInsensitiveContains("gamma"))
  }

  func testRelaxedSearchDoesNotRunWhenStrictHitsFillTheWindow() throws {
    let service = try makeService()
    let full = try service.createNote(bodyMarkdown: "# Full\nalpha beta gamma")
    _ = try service.createNote(bodyMarkdown: "# Partial\nalpha beta only")

    XCTAssertEqual(ids(try service.searchNotes(query: "alpha beta gamma", limit: 1)), [full.noteId])
  }

  func testRelaxedSearchAppliesTagFilterNotebookScopeAndPagination() throws {
    let service = try makeService()
    let notebook = try service.createNotebook(title: "Scoped")
    _ = try service.createNote(bodyMarkdown: "# Partial\nalpha beta only")
    let tagged = try service.createNote(
      notebookId: notebook.notebookId,
      bodyMarkdown: "# Tagged\ngamma only",
      tags: [NoteTagInput(name: "keep", classId: TagClassID("topic"))]
    )
    let scopedPartial = try service.createNote(notebookId: notebook.notebookId, bodyMarkdown: "# Scoped\nalpha only")

    let byTag = try service.searchNotes(query: "alpha beta gamma", tagFilter: ["keep"], limit: 10)
    XCTAssertEqual(ids(byTag), [tagged.noteId])
    XCTAssertEqual(byTag.first?.termCoverage, 1.0 / 3.0)

    let byNotebook = try service.searchNotes(query: "alpha beta gamma", notebookId: notebook.notebookId, limit: 10)
    XCTAssertEqual(Set(ids(byNotebook)), [tagged.noteId, scopedPartial.noteId])

    let page = try service.searchNotes(query: "alpha beta gamma", notebookId: notebook.notebookId, limit: 1, offset: 1)
    XCTAssertEqual(ids(page), [ids(byNotebook)[1]])
  }

  func testSingleTermQueriesKeepTheStrictPipeline() throws {
    let service = try makeService()
    let hit = try service.createNote(bodyMarkdown: "# Hit\nalpha only")
    _ = try service.createNote(bodyMarkdown: "# Miss\nbeta only")

    let results = try service.searchNotes(query: "alpha", limit: 10)
    XCTAssertEqual(ids(results), [hit.noteId])
    XCTAssertEqual(results.first?.termCoverage, 1)
  }

  // MARK: - RF3 personalized PageRank

  func testPersonalizedPageRankConservesMassAndFavoursMultiSeedNeighbours() {
    let pairs = [("s1", "shared"), ("s2", "shared"), ("s1", "only-s1"), ("s2", "only-s2"), ("hub", "hub-leaf-1")]
    let edges = pairs.flatMap { source, destination in
      [
        WeightedGraphEdge(source: source, destination: destination, weight: 1),
        WeightedGraphEdge(source: destination, destination: source, weight: 1)
      ]
    }
    let nodes = ["s1", "s2", "shared", "only-s1", "only-s2", "hub", "hub-leaf-1"]
    let mass = personalizedPageRank(
      nodes: nodes,
      edges: edges,
      personalization: ["s1": 1 / 60.0, "s2": 1 / 61.0]
    )

    XCTAssertEqual(mass.values.reduce(0, +), 1, accuracy: 1e-9)
    XCTAssertGreaterThan(mass["shared"] ?? 0, mass["only-s1"] ?? 0)
    XCTAssertGreaterThan(mass["only-s1"] ?? 0, mass["only-s2"] ?? 0)
    XCTAssertEqual(mass["hub"], 0)
    XCTAssertEqual(mass["hub-leaf-1"], 0)
    XCTAssertEqual(
      mass,
      personalizedPageRank(nodes: nodes, edges: edges, personalization: ["s1": 1 / 60.0, "s2": 1 / 61.0])
    )
    XCTAssertTrue(personalizedPageRank(nodes: nodes, edges: edges, personalization: [:]).values.allSatisfy { $0 == 0 })
  }

  func testLinkedExpansionRanksNeighbourSharedByTwoHitsFirst() throws {
    let service = try makeService()
    let strongHit = try service.createNote(bodyMarkdown: "# A\nplanning planning")
    let weakHit = try service.createNote(bodyMarkdown: "# B\nplanning")
    let shared = try service.createNote(bodyMarkdown: "# S\none")
    let strongOnly = try service.createNote(bodyMarkdown: "# T\ntwo")
    let weakOnly = try service.createNote(bodyMarkdown: "# U\nsix")
    _ = try service.linkNotes(from: strongHit.noteId, to: shared.noteId)
    _ = try service.linkNotes(from: weakHit.noteId, to: shared.noteId)
    _ = try service.linkNotes(from: strongHit.noteId, to: strongOnly.noteId)
    _ = try service.linkNotes(from: weakHit.noteId, to: weakOnly.noteId)

    let results = try service.searchNotes(query: "planning", includeLinked: true, limit: 10)

    XCTAssertEqual(
      ids(results),
      [strongHit.noteId, weakHit.noteId, shared.noteId, strongOnly.noteId, weakOnly.noteId]
    )
    XCTAssertEqual(results.map(\.isLinkedNeighbor), [false, false, true, true, true])
    let neighbourRanks = results.filter(\.isLinkedNeighbor).map(\.rank)
    XCTAssertEqual(neighbourRanks, neighbourRanks.sorted(by: >))
    XCTAssertGreaterThan(neighbourRanks[0], neighbourRanks[1])
  }

  func testGraphEdgesAmongCoverLinksAndSharedRareTags() throws {
    let service = try makeService()
    let first = try service.createNote(
      bodyMarkdown: "# A\nx",
      tags: [NoteTagInput(name: "rare-entity", classId: TagClassID("topic"))]
    )
    let second = try service.createNote(
      bodyMarkdown: "# B\ny",
      tags: [NoteTagInput(name: "rare-entity", classId: TagClassID("topic"))]
    )
    let third = try service.createNote(bodyMarkdown: "# C\nz")
    _ = try service.linkNotes(from: first.noteId, to: third.noteId)

    let edges = try service.driver.withDatabase { database in
      try graphEdgesAmong(noteIds: [first.noteId, second.noteId, third.noteId], scope: nil, in: database)
    }

    let pairs = Set(edges.map { "\($0.source.rawValue)->\($0.destination.rawValue)" })
    XCTAssertTrue(pairs.contains("\(first.noteId.rawValue)->\(third.noteId.rawValue)"))
    XCTAssertTrue(pairs.contains("\(third.noteId.rawValue)->\(first.noteId.rawValue)"))
    let tagEdge = try XCTUnwrap(edges.first { $0.source == first.noteId && $0.destination == second.noteId })
    XCTAssertGreaterThan(tagEdge.weight, 0.3)
    XCTAssertLessThan(tagEdge.weight, 1)
    XCTAssertNil(edges.first { $0.source == second.noteId && $0.destination == third.noteId })
  }

  // MARK: - RF4 recency-aware memory recall

  func testRecallRecencyWeightOnlyReordersNearTies() throws {
    let service = try makeService()
    let older = try service.appendLongTermMemoryNotes(
      [
        LongTermMemoryEntryInput(
          bodyMarkdown: "cutover cutover cutover rehearsal",
          periodEnd: Date(timeIntervalSince1970: 1_700_000_000)
        )
      ],
      idempotencyKey: "older"
    ).notes[0]
    let newer = try service.appendLongTermMemoryNotes(
      [
        LongTermMemoryEntryInput(
          bodyMarkdown: "cutover rehearsal follow-up",
          periodEnd: Date(timeIntervalSince1970: 1_760_000_000)
        )
      ],
      idempotencyKey: "newer"
    ).notes[0]

    let defaultOrder = try service.recallLongTermMemories(query: "cutover")
    XCTAssertEqual(defaultOrder.map(\.note.noteId), [older.noteId, newer.noteId])
    XCTAssertEqual(
      try service.recallLongTermMemories(query: "cutover", recencyWeight: 0).map(\.note.noteId),
      [older.noteId, newer.noteId]
    )
    XCTAssertEqual(
      try service.recallLongTermMemories(query: "cutover", recencyWeight: 3).map(\.note.noteId),
      [newer.noteId, older.noteId]
    )
    XCTAssertTrue(try service.recallLongTermMemories(query: "hydroponics", recencyWeight: 3).isEmpty)
    XCTAssertThrowsError(try service.recallLongTermMemories(query: "cutover", recencyWeight: -1))
  }

  // MARK: - RF5 agentic grounding

  func testGroundingResultsRankMultiTermSupportFirstAndLabelRelatedNotes() throws {
    let service = try makeService()
    let pepper = try service.createNote(bodyMarkdown: "# Pepper\nblack pepper sauce recipe")
    let sauce = try service.createNote(bodyMarkdown: "# Sauce\nsauce only")
    let linked = try service.createNote(bodyMarkdown: "# Linked\nnothing")
    _ = try service.linkNotes(from: pepper.noteId, to: linked.noteId)

    let query = "pepper sauce"
    let grounding = try AIAgenticSearchService.groundingResults(
      query: query,
      terms: AIAgenticSearchService.grepTerms(from: query),
      notebookId: nil,
      limit: 10,
      service: service
    )

    XCTAssertEqual(grounding.noteMatches.map(\.note.noteId), [pepper.noteId, sauce.noteId])
    XCTAssertEqual(grounding.relatedNotes.map(\.note.noteId), [linked.noteId])

    let markdown = AIAgenticSearchService.grepContextMarkdown(
      query: query,
      noteMatches: grounding.noteMatches,
      relatedNotes: grounding.relatedNotes,
      memoMatches: []
    )
    XCTAssertTrue(markdown.contains("## Related notes"))
    XCTAssertTrue(markdown.contains("noteId: \(linked.noteId)"))
    XCTAssertTrue(markdown.contains("[partial match: 50% of terms]"))
  }

  private func assertSearchIndexIntegrity(
    _ service: NoteService,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    do {
      try service.driver.withDatabase { database in
        try database.execute("INSERT INTO note_fts(note_fts) VALUES('integrity-check')")
      }
    } catch {
      XCTFail("FTS integrity check failed: \(error)", file: file, line: line)
      throw error
    }
  }
}
