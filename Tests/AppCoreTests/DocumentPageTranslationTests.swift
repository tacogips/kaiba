import Foundation
@testable import AppCore
import XCTest

private struct PageTranslationInvoker: AgentInvoking {
  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    AgentInvocationResult(markdown: "Translated: " + (request.turns.last?.markdown ?? ""))
  }
}

final class DocumentPageTranslationTests: NoteTestCase {
  func testSelectedRangeUsesPDFSearchTextAndLinksEachSourcePage() async throws {
    let service = try makeService()
    let source = try service.createNotebookWithNotes(title: "PDF", pages: [
      NotePageDraft(bodyMarkdown: "", searchText: "First page"),
      NotePageDraft(bodyMarkdown: "", searchText: "Second page\nSecond line"),
      NotePageDraft(bodyMarkdown: "", searchText: "Third page")
    ])
    let pending = try service.startNotebookTranslation(
      sourceNotebookId: source.notebook.notebookId, targetLanguage: "Japanese", pageStart: 2, pageEnd: 2
    )
    let completed = try await AITranslationService(service: service, invoker: PageTranslationInvoker()).run(
      translationNotebookId: pending.notebookId
    )
    let state = try XCTUnwrap(NoteService.translationState(of: completed))
    XCTAssertEqual(state.status, .completed)
    XCTAssertEqual(state.pageStart, 2)
    XCTAssertEqual(state.pageEnd, 2)
    XCTAssertTrue(try service.documentPageTranslations(noteId: source.notes[0].noteId).isEmpty)
    XCTAssertTrue(try service.documentPageTranslations(noteId: source.notes[2].noteId).isEmpty)
    let versions = try service.documentPageTranslations(noteId: source.notes[1].noteId)
    XCTAssertEqual(versions.count, 1)
    XCTAssertEqual(versions.first?.sourceNoteId, source.notes[1].noteId)
    XCTAssertEqual(versions.first?.notebookId, pending.notebookId)
    XCTAssertEqual(versions.first?.targetLanguage, "Japanese")
    XCTAssertTrue(versions.first?.text.contains("Second page\nSecond line") == true)
    XCTAssertFalse(versions.first?.text.contains("Third page") == true)
  }

  func testInvalidScopeDoesNotCreateTranslation() throws {
    let service = try makeService()
    let source = try service.createNotebookWithNotes(title: "PDF", pages: [NotePageDraft(bodyMarkdown: "One")])
    for range: (Int?, Int?) in [(0, 1), (2, 1), (1, 2), (1, nil), (nil, 1)] {
      XCTAssertThrowsError(try service.startNotebookTranslation(
        sourceNotebookId: source.notebook.notebookId, targetLanguage: "Japanese", pageStart: range.0, pageEnd: range.1
      ))
    }
    XCTAssertTrue(try service.documentPageTranslations(noteId: source.notes[0].noteId).isEmpty)
  }
}
