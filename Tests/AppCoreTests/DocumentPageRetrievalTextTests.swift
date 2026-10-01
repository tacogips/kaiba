import Foundation
@testable import AppCore
import XCTest

private actor RetrievalTextTagInvoker: AgentInvoking {
  private(set) var requests: [AgentInvocationRequest] = []

  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    requests.append(request)
    return AgentInvocationResult(markdown: "[]")
  }
}

final class DocumentPageRetrievalTextTests: NoteTestCase {
  private let ocrText = "Zephyrine harbor manifest"

  private func pageMetadata() throws -> String {
    let metadata = ImportedPageMetadata(
      pageNumber: 1,
      ocrState: "complete",
      analysis: DocumentPageAnalysis(),
      originFileId: "synthetic-origin",
      pendingBodySHA256: nil
    )
    let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(metadata))
    return try JSONValue.object(["documentPage": value]).encodedString()
  }

  private func fixture(_ service: NoteService) throws -> (page: Note, normal: Note) {
    let imported = try service.createNotebookWithNotes(
      title: "Retrieval fixture",
      pages: [
        NotePageDraft(bodyMarkdown: "", metaJSON: try pageMetadata(), searchText: ocrText),
        NotePageDraft(bodyMarkdown: "plain note body")
      ]
    )
    return (imported.notes[0], imported.notes[1])
  }

  func testSearchSnippetsAndLikeFallbackUsePageRetrievalText() throws {
    let service = try makeService()
    let notes = try fixture(service)

    let fts = try service.searchNotes(query: "Zephyrine")
    XCTAssertEqual(fts.first?.note.noteId, notes.page.noteId)
    XCTAssertTrue(fts.first?.snippet.contains("Zephyrine") == true)

    let like = try service.searchNotes(query: "ha")
    XCTAssertEqual(like.first?.note.noteId, notes.page.noteId)
    XCTAssertTrue(like.first?.snippet.contains("harbor") == true)
  }

  func testSubtrigramLikeFallbackMatchesSearchTextOnly() throws {
    let service = try makeService()
    let imported = try service.createNotebookWithNotes(
      title: "Search text only fixture",
      pages: [
        NotePageDraft(
          bodyMarkdown: "",
          metaJSON: try pageMetadata(),
          searchText: "Cargo ledger\nqx stamp"
        ),
        NotePageDraft(bodyMarkdown: "plain note body")
      ]
    )
    let page = imported.notes[0]
    let normal = imported.notes[1]

    let stored = try service.getNote(page.noteId)
    XCTAssertEqual(stored.title, "Cargo ledger")
    XCTAssertFalse(stored.bodyMarkdown.contains("qx"))
    XCTAssertTrue(stored.tags.isEmpty)

    let results = try service.searchNotes(query: "qx")
    XCTAssertEqual(results.first?.note.noteId, page.noteId)
    XCTAssertFalse(results.contains { $0.note.noteId == normal.noteId })
    XCTAssertTrue(results.first?.snippet.contains("qx") == true)
  }

  func testRelaxedSearchAndNormalNoteSnippetUseRetrievalText() throws {
    let service = try makeService()
    let notes = try fixture(service)

    let relaxed = try service.searchNotes(query: "Zephyrine missingtoken", limit: 10)
    let pageResult = try XCTUnwrap(relaxed.first { $0.note.noteId == notes.page.noteId })
    XCTAssertEqual(pageResult.termCoverage, 0.5)
    XCTAssertTrue(pageResult.snippet.contains("Zephyrine"))

    let normalResult = try XCTUnwrap(try service.searchNotes(query: "plain").first)
    XCTAssertEqual(normalResult.note.noteId, notes.normal.noteId)
    XCTAssertEqual(normalResult.snippet, snippet(from: "plain note body", query: "plain"))
  }

  func testAITagSubjectsUsePageRetrievalText() async throws {
    let service = try makeService()
    let notes = try fixture(service)
    let invoker = RetrievalTextTagInvoker()
    let extraction = AITagExtractionService(service: service, invoker: invoker)

    _ = try await extraction.extractTags(subject: .note(notes.page.noteId), dryRun: true)
    _ = try await extraction.extractTags(subject: .notebook(notes.page.notebookId), dryRun: true)

    let requests = await invoker.requests
    XCTAssertEqual(requests.count, 2)
    XCTAssertTrue(requests[0].turns.first?.markdown.contains(ocrText) == true)
    let notebookContext = try XCTUnwrap(requests[1].turns.first?.markdown)
    XCTAssertTrue(notebookContext.contains("## Zephyrine harbor manifest\n\(ocrText)"))
  }

  func testNotebookListPreviewUsesPageRetrievalText() throws {
    let service = try makeService()
    let notes = try fixture(service)

    let listed = try XCTUnwrap(service.listNotebooks().first { $0.notebookId == notes.page.notebookId })
    XCTAssertTrue(listed.firstNotePreview?.contains("Zephyrine") == true)
  }
}
