import Foundation
@testable import AppCore
import XCTest

private final class PageTranslationInvoker: AgentInvoking, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var sources: [String] = []

  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    let source = request.turns.last?.markdown ?? ""
    lock.withLock { sources.append(source) }
    return AgentInvocationResult(markdown: "Translated: " + source)
  }
}

final class DocumentPageTranslationTests: NoteTestCase {
  func testSelectedRangeTranslatesThePageTextOfEachSourcePage() async throws {
    let service = try makeService()
    let source = try makePDFNotebook(service, pages: [
      (.complete, "First page"),
      (.complete, "Second page\nSecond line"),
      (.complete, "Third page")
    ])
    let job = try service.startTranslationJob(
      notebookId: source.notebook.notebookId, targetLanguage: "Japanese", pageStart: 2, pageEnd: 2
    )
    XCTAssertEqual(job.pageStart, 2)
    XCTAssertEqual(job.pageEnd, 2)
    let invoker = PageTranslationInvoker()
    let completed = try await AITranslationService(service: service, invoker: invoker).run(jobId: job.jobId)
    XCTAssertEqual(completed.status, .completed)
    XCTAssertEqual(invoker.sources, ["Second page\nSecond line"])
    XCTAssertTrue(try service.noteTranslations(noteId: source.notes[0].noteId).isEmpty)
    XCTAssertTrue(try service.noteTranslations(noteId: source.notes[2].noteId).isEmpty)
    let versions = try service.noteTranslations(noteId: source.notes[1].noteId)
    XCTAssertEqual(versions.map(\.language), ["Japanese"])
    XCTAssertEqual(versions.first?.noteId, source.notes[1].noteId)
    XCTAssertEqual(versions.first?.body, "Translated: Second page\nSecond line")
    XCTAssertEqual(versions.first?.isCurrent, true)
  }

  func testBlankAndPendingOCRPagesAreSkippedUntilTheyHaveText() async throws {
    let service = try makeService()
    let source = try makePDFNotebook(service, pages: [
      (.complete, "Readable page"),
      (.complete, "  \n "),
      (.pending, "")
    ])
    let invoker = PageTranslationInvoker()
    let completed = try await AITranslationService(service: service, invoker: invoker)
      .translateNotebook(notebookId: source.notebook.notebookId, targetLanguage: "English")
    XCTAssertEqual(completed.status, .completed)
    XCTAssertEqual(invoker.sources, ["Readable page"])
    XCTAssertEqual(
      try source.notes.map { try service.noteTranslations(noteId: $0.noteId).count },
      [1, 0, 0]
    )

    // Once the pending page has text, a new job translates only that page.
    try service.driver.withDatabase { database in
      try database.execute(
        "UPDATE document_pages SET text = 'Recognized later', text_status = 'complete', text_source = 'ocr' WHERE note_id = ?",
        bindings: [.id(source.notes[2].noteId)]
      )
    }
    let later = PageTranslationInvoker()
    _ = try await AITranslationService(service: service, invoker: later)
      .translateNotebook(notebookId: source.notebook.notebookId, targetLanguage: "English")
    XCTAssertEqual(later.sources, ["Recognized later"])
    XCTAssertEqual(
      try service.noteTranslations(noteId: source.notes[2].noteId).map(\.body),
      ["Translated: Recognized later"]
    )
  }

  func testInvalidScopeDoesNotCreateTranslationJob() throws {
    let service = try makeService()
    let source = try service.createNotebookWithNotes(title: "PDF", pages: [NotePageDraft(bodyMarkdown: "One")])
    for range: (Int?, Int?) in [(0, 1), (2, 1), (1, 2), (1, nil), (nil, 1)] {
      XCTAssertThrowsError(try service.startTranslationJob(
        notebookId: source.notebook.notebookId, targetLanguage: "Japanese", pageStart: range.0, pageEnd: range.1
      ))
    }
    XCTAssertTrue(try service.translationJobs(notebookId: source.notebook.notebookId).isEmpty)
    XCTAssertTrue(try service.noteTranslations(noteId: source.notes[0].noteId).isEmpty)
  }

  /// A notebook of PDF pages whose OCR versions hold the given text.
  private func makePDFNotebook(
    _ service: NoteService,
    pages: [(DocumentPageTextStatus, String)]
  ) throws -> NotebookIngestResult {
    let fileId = FileID.generate()
    try service.driver.withDatabase { database in
      try database.execute(
        """
        INSERT INTO files (file_id, storage_kind, local_path, media_type, byte_size, sha256, created_at)
        VALUES (?, 'local', 'files/fixture.pdf', 'application/pdf', 0, 'fixture', ?)
        """,
        bindings: [.id(fileId), .text(NoteStoreClock.system.now())]
      )
    }
    return try service.createNotebookWithNotes(
      title: "PDF",
      pages: pages.enumerated().map { index, page in
        NotePageDraft(
          bodyMarkdown: "",
          noteNumber: index + 1,
          documentPage: DocumentPageDraft(
            page: DocumentPage(
              pageNumber: index + 1,
              originFileId: fileId,
              originMediaType: "application/pdf",
              textExtractionMode: .preferPDFText,
              textStatus: page.0,
              textSource: page.0 == .complete ? .pdfText : nil
            ),
            text: page.1
          )
        )
      }
    )
  }
}
