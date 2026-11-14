import Foundation
@testable import AppCore
import XCTest

final class SearchEngineOntologyQueryTests: NoteTestCase {
  func testHierarchyAndClassFiltersResolveAndUnknownEntriesSkipEngine() async throws {
    let service = try makeService(function: #function)
    let parent = try service.defineTag(name: "ontology-parent", classId: .topic)
    let child = try service.defineTag(name: "ontology-child", classId: .topic, parentTagId: parent.tagId)
    let alice = try service.defineTag(name: "Alice", classId: .person)
    let note = try service.createNote(bodyMarkdown: "body", tags: [
      NoteTagInput(name: child.name, classId: .topic),
      NoteTagInput(name: alice.name, classId: .person)
    ])
    let engine = FakeSearchEngine()
    engine.scriptedHits = [SearchEngineHit(noteId: note.noteId, score: 1, highlight: nil)]
    let enabled = service
    enabled.searchEngine = engine

    _ = try await enabled.engineSearchNotesPage(query: "body", tagFilter: [parent.name])
    XCTAssertEqual(engine.recordedSearchPages.last?.filter.hierarchyTagIds, [parent.tagId])
    XCTAssertEqual(engine.recordedSearchPages.last?.filter.tagIds, [])

    _ = try await enabled.engineSearchNotesPage(query: "body", tagClassFilter: ["person"])
    XCTAssertEqual(engine.recordedSearchPages.last?.filter.tagClassFilters, [SearchEngineTagClassFilter(tagClass: "person")])
    _ = try await enabled.engineSearchNotesPage(query: "body", tagClassFilter: ["person:Alice"])
    XCTAssertEqual(
      engine.recordedSearchPages.last?.filter.tagClassFilters,
      [SearchEngineTagClassFilter(tagClass: "person", tagId: alice.tagId)]
    )
    let beforeInvalid = engine.recordedSearchPages.count
    let unknownTag = try await enabled.engineSearchNotesPage(query: "body", tagFilter: ["nope"])
    let mismatchedClass = try await enabled.engineSearchNotesPage(query: "body", tagClassFilter: ["event:Alice"])
    let unknownClass = try await enabled.engineSearchNotesPage(query: "body", tagClassFilter: ["bogus"])
    XCTAssertTrue(unknownTag.hits.isEmpty)
    XCTAssertTrue(mismatchedClass.hits.isEmpty)
    XCTAssertTrue(unknownClass.hits.isEmpty)
    XCTAssertEqual(engine.recordedSearchPages.count, beforeInvalid)
    do {
      _ = try await enabled.engineSearchNotesPage(query: "body", tagClassFilter: Array(repeating: "person", count: 11))
      XCTFail("expected tagClassFilter limit error")
    } catch {
      XCTAssertEqual(error as? NoteServiceError, .invalidInput("tagClassFilter allows at most 10 entries"))
    }
  }

  func testOntologyExpansionUsesUnicodeSubstringASCIIWordBoundariesAndCap() async throws {
    let service = try makeService(function: #function)
    let tokyo = try service.defineTag(name: "東京", classId: .topic)
    let art = try service.defineTag(name: "art", classId: .topic)
    let systemName = NoteStoreSchema.longTermMemoryNotebookKindTag
    let maybeSystemId = try service.driver.withDatabase { database in
      try database.query("SELECT tag_id FROM tags WHERE name = ?", bindings: [.text(systemName)])
        .first?.identifier("tag_id", as: TagID.self)
    }
    let systemId = try XCTUnwrap(maybeSystemId)
    let matching = try (1...12).map { number in
      try service.defineTag(name: "ontology match \(String(repeating: "x", count: number))", classId: .topic)
    }
    try service.driver.withDatabase { database in
      XCTAssertEqual(try ontologyExpansionTagIds(query: "東京旅行", in: database), [tokyo.tagId])
      XCTAssertFalse(try ontologyExpansionTagIds(query: "party", in: database).contains(art.tagId))
      XCTAssertTrue(try ontologyExpansionTagIds(query: "art history", in: database).contains(art.tagId))
      XCTAssertFalse(try ontologyExpansionTagIds(query: systemName, in: database).contains(systemId))
      let expanded = try ontologyExpansionTagIds(query: matching.map(\.name).joined(separator: " "), in: database)
      XCTAssertEqual(expanded.count, 10)
      XCTAssertEqual(expanded.first, matching.last?.tagId)
    }

    let engine = FakeSearchEngine()
    let enabled = service
    enabled.searchEngine = engine
    _ = try await enabled.engineSearchNotesPage(query: "東京旅行", expandOntology: false)
    XCTAssertEqual(engine.recordedSearchPages.last?.expansionTagIds, [])
  }

  func testFacetsHydrateKnownTagsAndDropUnknownOrSystemTags() async throws {
    let service = try makeService(function: #function)
    let topic = try service.defineTag(name: "facet-topic", classId: .topic)
    let note = try service.createNote(bodyMarkdown: "facets")
    let maybeSystemId = try service.driver.withDatabase { database in
      try database.query(
        "SELECT tag_id FROM tags WHERE is_system = 1 ORDER BY tag_id LIMIT 1"
      ).first?.identifier("tag_id", as: TagID.self)
    }
    let systemId = try XCTUnwrap(maybeSystemId)
    let engine = FakeSearchEngine()
    engine.scriptedHits = [SearchEngineHit(noteId: note.noteId, score: 1, highlight: nil)]
    engine.scriptedFacets = SearchEngineFacets(
      tagClasses: [SearchEngineFacetBucket(value: "topic", count: 3)],
      tags: [
        SearchEngineFacetBucket(value: topic.tagId.rawValue, count: 2),
        SearchEngineFacetBucket(value: "unknown-tag", count: 1),
        SearchEngineFacetBucket(value: systemId.rawValue, count: 4)
      ]
    )
    let enabled = service
    enabled.searchEngine = engine
    let page = try await enabled.engineSearchNotesPage(query: "facets", includeFacets: true)
    XCTAssertEqual(page.facets?.tagClasses, [SearchEngineFacetBucket(value: "topic", count: 3)])
    XCTAssertEqual(page.facets?.tags, [NoteEngineTagFacet(tagId: topic.tagId, name: topic.name, tagClass: "topic", count: 2)])
    XCTAssertNotNil(engine.recordedSearchPages.last?.facets)
    let noFacets = try await enabled.engineSearchNotesPage(query: "facets", includeFacets: false)
    XCTAssertNil(noFacets.facets)
    XCTAssertNil(engine.recordedSearchPages.last?.facets)
  }

  func testRelatedSignalsReasonsAndStoreAccessRecheck() async throws {
    let service = try makeService(function: #function)
    let grandparent = try service.defineTag(name: "ontology-grandparent", classId: .topic)
    let parent = try service.defineTag(name: "ontology-parent", classId: .topic, parentTagId: grandparent.tagId)
    let topic = try service.defineTag(name: "OntologyTopic", classId: .topic, parentTagId: parent.tagId)
    let alice = try service.defineTag(name: "OntologyAlice", classId: .person)
    let source = try service.createNote(bodyMarkdown: "source", tags: [
      NoteTagInput(name: topic.name, classId: .topic),
      NoteTagInput(name: alice.name, classId: .person)
    ])
    let matching = try service.createNote(bodyMarkdown: "matching", tags: [
      NoteTagInput(name: topic.name, classId: .topic)
    ])
    let stale = try service.createNote(bodyMarkdown: "stale")
    let privateLibrary = try service.createLibrary(name: "ontology-private", authRequired: true)
    let privateNote = try service.scoped(toLibrary: privateLibrary.libraryId).createNote(bodyMarkdown: "private")
    let engine = FakeSearchEngine()
    engine.scriptedHits = [
      SearchEngineHit(noteId: source.noteId, score: 10, highlight: nil),
      SearchEngineHit(noteId: matching.noteId, score: 9, highlight: nil, reasons: [
        SearchEngineHitReason(kind: .sharedTag), SearchEngineHitReason(kind: .textSimilarity)
      ]),
      SearchEngineHit(noteId: stale.noteId, score: 8, highlight: nil, reasons: [SearchEngineHitReason(kind: .sharedEntity)]),
      SearchEngineHit(noteId: privateNote.noteId, score: 7, highlight: nil)
    ]
    let enabled = service.scoped(to: NoteStoreSchema.defaultUserId).unauthenticated()
    enabled.searchEngine = engine

    let results = try await enabled.relatedNotes(noteId: source.noteId)
    XCTAssertEqual(results.map(\.note.noteId), [matching.noteId, stale.noteId])
    XCTAssertEqual(results.first?.reasons, [
      SearchEngineHitReason(kind: .sharedTag, tagNames: [topic.name]),
      SearchEngineHitReason(kind: .textSimilarity)
    ])
    XCTAssertTrue(results.last?.reasons.isEmpty == true)
    let signals = engine.recordedRelated[0].signals
    XCTAssertEqual(signals?.sourceNoteId, source.noteId)
    XCTAssertEqual(signals?.sharedTagIds, [alice.tagId, topic.tagId].sorted())
    XCTAssertEqual(signals?.nearTagIds, [alice.tagId, parent.tagId, topic.tagId].sorted())
    XCTAssertEqual(signals?.ancestorTagIds, [grandparent.tagId, parent.tagId].sorted())
    XCTAssertEqual(signals?.entityTags, [SearchEngineClassTag(tagClass: "person", tagId: alice.tagId)])
  }
}
