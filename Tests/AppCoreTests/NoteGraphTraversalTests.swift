import AppCore
import XCTest

final class NoteGraphTraversalTests: NoteTestCase {
  func testHardDepthStopAndDecayOrdering() throws {
    let service = try makeService()
    let seed = try service.createNote(bodyMarkdown: "# A\nx")
    let first = try service.createNote(bodyMarkdown: "# B\ny")
    let second = try service.createNote(bodyMarkdown: "# C\nz")
    let third = try service.createNote(bodyMarkdown: "# D\nq")
    _ = try service.linkNotes(from: seed.noteId, to: first.noteId)
    _ = try service.linkNotes(from: first.noteId, to: second.noteId)
    _ = try service.linkNotes(from: second.noteId, to: third.noteId)

    let depthTwo = try service.graphNeighbors(noteIds: [seed.noteId], maxDepth: 2)

    XCTAssertEqual(depthTwo.map(\.note.noteId), [first.noteId, second.noteId])
    XCTAssertEqual(depthTwo.map(\.hopCount), [1, 2])
    XCTAssertEqual(depthTwo.map(\.weight), [0.5, 0.25])
    XCTAssertFalse(depthTwo.map(\.note.noteId).contains(third.noteId))
  }

  func testDepthIsCappedAtFive() throws {
    let service = try makeService()
    var notes = [try service.createNote(bodyMarkdown: "# A\nx")]
    for character in ["B", "C", "D", "E", "F", "G"] {
      notes.append(try service.createNote(bodyMarkdown: "# \(character)\nx"))
    }
    for index in 0..<(notes.count - 1) {
      _ = try service.linkNotes(from: notes[index].noteId, to: notes[index + 1].noteId)
    }

    let results = try service.graphNeighbors(noteIds: [notes[0].noteId], maxDepth: 99)

    XCTAssertEqual(results.map(\.hopCount).max(), 5)
    XCTAssertFalse(results.map(\.note.noteId).contains(notes[6].noteId))
  }

  func testRareSharedTagOutranksCommonTagAndStructuralTagsAreExcluded() throws {
    let service = try makeService()
    let seed = try service.createNote(
      bodyMarkdown: "# A\nx",
      tags: [
        NoteTagInput(name: "rare-entity", classId: TagClassID("topic")),
        NoteTagInput(name: "common-entity", classId: TagClassID("topic")),
        NoteTagInput(name: "structural-label", classId: TagClassID("document-kind"))
      ]
    )
    let rare = try service.createNote(
      bodyMarkdown: "# B\ny",
      tags: [NoteTagInput(name: "rare-entity", classId: TagClassID("topic"))]
    )
    let common = try service.createNote(
      bodyMarkdown: "# C\nz",
      tags: [NoteTagInput(name: "common-entity", classId: TagClassID("topic"))]
    )
    let structural = try service.createNote(
      bodyMarkdown: "# D\nq",
      tags: [NoteTagInput(name: "structural-label", classId: TagClassID("document-kind"))]
    )
    for index in 0..<6 {
      _ = try service.createNote(
        bodyMarkdown: "# X\(index)\nq",
        tags: [NoteTagInput(name: "common-entity", classId: TagClassID("topic"))]
      )
    }

    let results = try service.graphNeighbors(noteIds: [seed.noteId], maxDepth: 1)
    let rareResult = try XCTUnwrap(results.first { $0.note.noteId == rare.noteId })
    let commonResult = try XCTUnwrap(results.first { $0.note.noteId == common.noteId })

    XCTAssertGreaterThan(rareResult.weight, commonResult.weight)
    XCTAssertEqual(rareResult.edgeKind, .sharedTag)
    XCTAssertFalse(results.map(\.note.noteId).contains(structural.noteId))
  }

  func testNodeCapAndNoEdgeTraversal() throws {
    let service = try makeService()
    let isolated = try service.createNote(bodyMarkdown: "# I\nx")
    XCTAssertTrue(try service.graphNeighbors(noteIds: [isolated.noteId]).isEmpty)

    let seed = try service.createNote(bodyMarkdown: "# A\ny")
    for index in 0..<25 {
      let neighbor = try service.createNote(bodyMarkdown: "# N\(index)\nz")
      _ = try service.linkNotes(from: seed.noteId, to: neighbor.noteId)
    }

    let results = try service.graphNeighbors(noteIds: [seed.noteId], limit: 99)
    XCTAssertEqual(results.count, NoteGraphPolicy.finalizedNodeLimit)
  }

  func testProposalsSurviveHubNoteWithMoreExistingLinksThanNodeBudget() throws {
    // Already-linked neighbors are excluded from proposals but must not consume
    // the finalized-node budget: a hub note with more existing links than
    // NoteGraphPolicy.finalizedNodeLimit still gets hop-2 proposals.
    let service = try makeService()
    let hub = try service.createNote(bodyMarkdown: "# Hub\nx")
    var firstLinked: Note?
    for index in 0..<(NoteGraphPolicy.finalizedNodeLimit + 1) {
      let linked = try service.createNote(bodyMarkdown: "# L\(index)\ny")
      _ = try service.linkNotes(from: hub.noteId, to: linked.noteId)
      if firstLinked == nil {
        firstLinked = linked
      }
    }
    let bridge = try XCTUnwrap(firstLinked)
    let candidate = try service.createNote(bodyMarkdown: "# Candidate\nz")
    _ = try service.linkNotes(from: bridge.noteId, to: candidate.noteId)

    let proposals = try service.proposeLinks(noteId: hub.noteId)

    XCTAssertEqual(proposals.map(\.targetNote.noteId), [candidate.noteId])
  }

  func testAssociationUsesDepthTwoBridgeWithoutPersistingProposal() throws {
    let service = try makeService()
    let seed = try service.createNote(bodyMarkdown: "# A\nx")
    let existing = try service.createNote(bodyMarkdown: "# B\ny")
    let candidate = try service.createNote(bodyMarkdown: "# C\nz")
    let tooFar = try service.createNote(bodyMarkdown: "# D\nq")
    _ = try service.linkNotes(from: seed.noteId, to: existing.noteId)
    _ = try service.linkNotes(from: existing.noteId, to: candidate.noteId)
    _ = try service.linkNotes(from: candidate.noteId, to: tooFar.noteId)

    let proposals = try service.proposeLinks(noteId: seed.noteId)

    XCTAssertEqual(proposals.map(\.targetNote.noteId), [candidate.noteId])
    XCTAssertTrue(proposals[0].reason.contains(seed.noteId.rawValue))
    XCTAssertTrue(proposals[0].reason.contains(candidate.noteId.rawValue))
    XCTAssertEqual(try service.listLinks(noteId: seed.noteId).count, 1)
  }

  func testSearchLinkedExpansionUsesSharedGraphPolicyAtRequestedDepth() throws {
    let service = try makeService()
    let direct = try service.createNote(
      bodyMarkdown: "# Seed\nprojectalpha",
      tags: [NoteTagInput(name: "shared-entity", classId: TagClassID("topic"))]
    )
    let neighbor = try service.createNote(
      bodyMarkdown: "# B\ny",
      tags: [NoteTagInput(name: "shared-entity", classId: TagClassID("topic"))]
    )

    XCTAssertEqual(try service.searchNotes(query: "projectalpha").map(\.note.noteId), [direct.noteId])
    let expanded = try service.searchNotes(query: "projectalpha", includeLinked: true, depth: 1)

    XCTAssertEqual(expanded.map(\.note.noteId), [direct.noteId, neighbor.noteId])
    XCTAssertEqual(expanded.map(\.isLinkedNeighbor), [false, true])
  }

  func testGraphRequestValidationAndDuplicateSeedNormalization() throws {
    let service = try makeService()
    let seed = try service.createNote(bodyMarkdown: "# A\nx")
    let neighbor = try service.createNote(bodyMarkdown: "# B\ny")
    _ = try service.linkNotes(from: seed.noteId, to: neighbor.noteId)

    XCTAssertEqual(
      try service.graphNeighbors(noteIds: [seed.noteId, seed.noteId]).map(\.note.noteId),
      [neighbor.noteId]
    )
    XCTAssertThrowsError(try service.graphNeighbors(noteIds: [seed.noteId], maxDepth: -1))
    XCTAssertThrowsError(try service.graphNeighbors(noteIds: [seed.noteId], limit: -1))
    XCTAssertThrowsError(try service.graphNeighbors(noteIds: [NoteID("missing-note")]))
  }

  func testSourceLimitFiltersRequestSeedsBeforeTruncation() throws {
    let service = try makeService()
    let primary = try service.createNote(bodyMarkdown: "# A\nx")
    var seeds = [primary]
    for index in 0..<19 {
      let seed = try service.createNote(bodyMarkdown: "# S\(index)\ny")
      seeds.append(seed)
      _ = try service.linkNotes(from: primary.noteId, to: seed.noteId)
    }
    let valid = try service.createNote(bodyMarkdown: "# V\nz")
    _ = try service.linkNotes(from: primary.noteId, to: valid.noteId)

    let results = try service.graphNeighbors(noteIds: seeds.map(\.noteId), maxDepth: 1)

    XCTAssertEqual(results.map(\.note.noteId), [valid.noteId])
  }

  func testStrongerLaterPathReplacesPendingEvidence() throws {
    let service = try makeService()
    let seed = try service.createNote(
      bodyMarkdown: "# A\nx",
      tags: [NoteTagInput(name: "seed-to-b", classId: TagClassID("topic"))]
    )
    let first = try service.createNote(
      bodyMarkdown: "# B\ny",
      tags: [NoteTagInput(name: "first-to-destination", classId: TagClassID("topic"))]
    )
    let later = try service.createNote(
      bodyMarkdown: "# C\nz",
      tags: [NoteTagInput(name: "seed-to-b", classId: TagClassID("topic"))]
    )
    let destination = try service.createNote(
      bodyMarkdown: "# D\nq",
      tags: [NoteTagInput(name: "first-to-destination", classId: TagClassID("topic"))]
    )
    _ = try service.linkNotes(from: seed.noteId, to: first.noteId)
    _ = try service.linkNotes(from: later.noteId, to: destination.noteId)

    let results = try service.graphNeighbors(noteIds: [seed.noteId], maxDepth: 2)
    let destinationResult = try XCTUnwrap(results.first { $0.note.noteId == destination.noteId })

    XCTAssertEqual(destinationResult.pathNoteIds, [seed.noteId, later.noteId, destination.noteId])
    XCTAssertEqual(destinationResult.edgeKind, .explicitLink)
  }

  func testSearchSurfacesFilterPassingNeighborWhenTopCandidateFailsFilters() throws {
    // Per the design (search: "Existing tag, class, and created-date filters
    // also apply to appended neighbors") and the pre-existing shipped R7
    // contract, tag/class/date filters apply to the bounded graph-candidate set
    // rather than only to the single highest-weighted candidate: a
    // filter-passing neighbor is surfaced even when a higher-weighted sibling
    // fails the filter. The no-backfill rule is scoped to direct-hit
    // deduplication only, not to filter removal.
    let service = try makeService()
    let direct = try service.createNote(
      bodyMarkdown: "# Seed\nprojectalpha",
      tags: [
        NoteTagInput(name: "eligible", classId: TagClassID("topic")),
        NoteTagInput(name: "shared-entity", classId: TagClassID("topic"))
      ]
    )
    // Highest-weight neighbor (explicit link, weight 0.5) but fails the filter.
    let filteredExplicit = try service.createNote(bodyMarkdown: "# B\nx")
    // Lower-weight shared-tag neighbor that passes the "eligible" filter.
    let eligibleShared = try service.createNote(
      bodyMarkdown: "# C\ny",
      tags: [
        NoteTagInput(name: "eligible", classId: TagClassID("topic")),
        NoteTagInput(name: "shared-entity", classId: TagClassID("topic"))
      ]
    )
    _ = try service.linkNotes(from: direct.noteId, to: filteredExplicit.noteId)

    let results = try service.searchNotes(
      query: "projectalpha",
      tagFilter: ["eligible"],
      includeLinked: true,
      depth: 1,
      limit: 2
    )

    XCTAssertEqual(results.map(\.note.noteId), [direct.noteId, eligibleShared.noteId])
    XCTAssertEqual(results.last?.isLinkedNeighbor, true)
    XCTAssertFalse(results.map(\.note.noteId).contains(filteredExplicit.noteId))
  }
}
