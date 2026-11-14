import Foundation
@testable import AppCore
import XCTest

final class SearchEngineQueryTests: NoteTestCase {
  func testDisabledModeAndSearchNotesParity() async throws {
    let service = try makeService(function: #function)
    let first = try service.createNote(bodyMarkdown: "# Baseline\nneedle in the body")
    let before = try service.searchNotes(query: "needle")

    XCTAssertFalse(service.isSearchEngineEnabled)
    do {
      _ = try await service.engineSearchNotes(query: "needle")
      XCTFail("expected notConfigured")
    } catch {
      XCTAssertEqual(error as? SearchEngineError, .notConfigured)
    }
    do {
      _ = try await service.relatedNotes(noteId: first.noteId)
      XCTFail("expected notConfigured")
    } catch {
      XCTAssertEqual(error as? SearchEngineError, .notConfigured)
    }

    let engine = FakeSearchEngine()
    var enabled = service
    enabled.searchEngine = engine
    XCTAssertTrue(enabled.isSearchEngineEnabled)
    XCTAssertEqual(try enabled.searchNotes(query: "needle"), before)
    XCTAssertTrue(engine.recordedSearches.isEmpty)
    XCTAssertTrue(enabled.scoped(to: NoteStoreSchema.defaultUserId).isSearchEngineEnabled)
  }

  func testEngineSearchRejectsEmptyQueryAndPreservesOrderHighlightsAndFallback() async throws {
    let service = try makeService(function: #function)
    let first = try service.createNote(bodyMarkdown: "# First\nfirst body marker")
    let second = try service.createNote(bodyMarkdown: "# Second\nsecond body marker")
    let engine = FakeSearchEngine()
    engine.scriptedHits = [
      SearchEngineHit(noteId: second.noteId, score: 9, highlight: "  engine highlight  "),
      SearchEngineHit(noteId: first.noteId, score: 4, highlight: nil)
    ]
    var enabled = service
    enabled.searchEngine = engine

    do {
      _ = try await enabled.engineSearchNotes(query: " \n ")
      XCTFail("expected invalidInput")
    } catch {
      XCTAssertEqual(error as? NoteServiceError, .invalidInput("query must not be empty"))
    }
    let results = try await enabled.engineSearchNotes(query: " marker ")
    XCTAssertEqual(results.map(\.note.noteId), [second.noteId, first.noteId])
    XCTAssertEqual(results.map(\.score), [9, 4])
    XCTAssertEqual(results[0].snippet, "engine highlight")
    XCTAssertEqual(results[1].snippet, snippet(from: first.bodyMarkdown, query: "marker"))
    XCTAssertEqual(engine.recordedSearches.last?.text, "marker")
  }

  func testEngineSearchOverfetchesBeforeStoreRecheckAndSlicesPage() async throws {
    let service = try makeService(function: #function)
    var notes: [Note] = []
    for number in 1...30 {
      notes.append(try service.createNote(bodyMarkdown: "pagination item \(number)"))
    }
    let engine = FakeSearchEngine()
    engine.scriptedHits = notes.map { SearchEngineHit(noteId: $0.noteId, score: 1, highlight: nil) }
    var enabled = service
    enabled.searchEngine = engine

    let results = try await enabled.engineSearchNotes(query: "pagination", limit: 10, offset: 10)
    XCTAssertEqual(results.map(\.note.noteId), notes[10..<20].map(\.noteId))
    XCTAssertEqual(engine.recordedSearches.last?.from, 0)
    XCTAssertEqual(engine.recordedSearches.last?.size, 40)
  }

  func testTagFilterExpandsDescendantsAndUnknownTagSkipsEngine() async throws {
    let service = try makeService(function: #function)
    let parent = try service.defineTag(name: "engine-parent", classId: TagClassID("topic"))
    let child = try service.defineTag(
      name: "engine-child",
      classId: TagClassID("topic"),
      parentTagId: parent.tagId
    )
    let note = try service.createNote(
      bodyMarkdown: "tagged marker",
      tags: [NoteTagInput(name: child.name, classId: TagClassID("topic"))]
    )
    let engine = FakeSearchEngine()
    engine.scriptedHits = [SearchEngineHit(noteId: note.noteId, score: 1, highlight: nil)]
    var enabled = service
    enabled.searchEngine = engine

    let parentSearch = try await enabled.engineSearchNotes(query: "marker", tagFilter: [parent.name])
    XCTAssertEqual(parentSearch.map(\.note.noteId), [note.noteId])
    XCTAssertEqual(engine.recordedSearches.last?.filter.hierarchyTagIds, [parent.tagId])
    XCTAssertEqual(engine.recordedSearches.last?.filter.tagIds, [])
    let unknownTagSearch = try await enabled.engineSearchNotes(
      query: "marker",
      tagFilter: ["missing-engine-tag"]
    )
    XCTAssertTrue(unknownTagSearch.isEmpty)
    XCTAssertEqual(engine.recordedSearches.count, 1)
  }

  func testRelatedNotesExcludesSourceAndCapsLikeText() async throws {
    let service = try makeService(function: #function)
    let source = try service.createNote(
      title: "Source title",
      bodyMarkdown: String(repeating: "source text ", count: 500)
    )
    let related = try service.createNote(bodyMarkdown: "related text")
    let engine = FakeSearchEngine()
    engine.scriptedHits = [
      SearchEngineHit(noteId: source.noteId, score: 10, highlight: nil),
      SearchEngineHit(noteId: related.noteId, score: 8, highlight: " related highlight ")
    ]
    var enabled = service
    enabled.searchEngine = engine

    let results = try await enabled.relatedNotes(noteId: source.noteId, limit: 1)
    XCTAssertEqual(results.map(\.note.noteId), [related.noteId])
    XCTAssertEqual(results.first?.snippet, "related highlight")
    XCTAssertTrue(engine.recordedRelated[0].likeText.hasPrefix("Source title\n"))
    XCTAssertLessThanOrEqual(engine.recordedRelated[0].likeText.count, 4000)
    XCTAssertEqual(engine.recordedRelated[0].size, 21)
    XCTAssertEqual(engine.recordedRelated[0].filter.excludedNoteIds, [source.noteId])
  }
}
