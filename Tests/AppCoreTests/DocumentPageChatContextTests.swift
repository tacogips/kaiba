import Foundation
@testable import AppCore
import XCTest

private actor PageChatCapture: AgentInvoking {
  private(set) var request: AgentInvocationRequest?
  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    self.request = request
    return AgentInvocationResult(markdown: "captured")
  }
}

final class DocumentPageChatContextTests: NoteTestCase {
  func testPageChatSendsOriginOCRNeighboursAndRelatedText() async throws {
    let service = try makeService()
    let pages = try service.createNotebookWithNotes(
      title: "Synthetic pages",
      pages: (1...3).map { page in
        NotePageDraft(
          bodyMarkdown: "", readOnly: false,
          metaJSON: metadata(page: page, origin: "pending-\(page)"),
          noteNumber: page, searchText: "OCR page \(page)"
        )
      }
    )
    let subject = try XCTUnwrap(pages.notes.first { $0.noteNumber == 2 })
    let originBytes = Data([0x89, 0x50, 0x4e, 0x47])
    let origin = try service.attachFile(
      noteId: subject.noteId, data: originBytes, role: .sourcePageImage,
      mediaType: "image/png", originalFilename: "synthetic.png"
    )
    try service.driver.withDatabase { db in
      try db.execute(
        "UPDATE notes SET meta_json = jsonb(?) WHERE note_id = ?",
        bindings: [.text(metadata(page: 2, origin: origin.file.fileId.rawValue)), .id(subject.noteId)]
      )
    }
    let related = try service.createNote(bodyMarkdown: "The lighthouse is beside the old harbor.")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId, userMarkdown: "Where is the lighthouse?",
      agentAvailable: true
    )
    let invoker = PageChatCapture()
    try await service.generateAgentChatReply(turnNoteId: turn.noteId, invoker: invoker)

    let captured = await invoker.request
    let request = try XCTUnwrap(captured)
    XCTAssertEqual(request.images.count, 1)
    XCTAssertEqual(request.images.first?.data, originBytes)
    XCTAssertEqual(request.images.first?.mediaType, "image/png")
    XCTAssertTrue(try XCTUnwrap(request.contextMarkdown).contains("OCR page 2"))
    XCTAssertTrue(try XCTUnwrap(request.contextMarkdown).contains("### Page 1"))
    XCTAssertTrue(try XCTUnwrap(request.contextMarkdown).contains("### Page 3"))
    XCTAssertTrue(try XCTUnwrap(request.contextMarkdown).contains("The lighthouse is beside the old harbor."))
    XCTAssertTrue(request.systemPrompt.hasSuffix(documentPageChatSystemPromptSuffix))
    XCTAssertEqual(try service.getNote(related.noteId).bodyMarkdown, "The lighthouse is beside the old harbor.")
  }

  func testNonPageNoteChatRequestIsUnchanged() async throws {
    let service = try makeService()
    let created = try service.createNote(bodyMarkdown: "Plain note body about the lighthouse.")
    let note = try service.getNote(created.noteId)
    let notebook = try service.getNotebook(note.notebookId)
    let conversation = try service.startAgentConversation(subjectNoteId: note.noteId)
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId, userMarkdown: "Where is the lighthouse?",
      agentAvailable: true
    )
    let invoker = PageChatCapture()
    try await service.generateAgentChatReply(turnNoteId: turn.noteId, invoker: invoker)

    let captured = await invoker.request
    let request = try XCTUnwrap(captured)
    XCTAssertTrue(request.images.isEmpty)
    XCTAssertEqual(request.systemPrompt, NoteService.chatSystemPrompt)
    let expectedContext = [
      "# Source notebook",
      "Title: \(notebook.title)",
      "Notebook ID: \(notebook.notebookId)",
      "",
      "# Source note",
      "Note ID: \(note.noteId)",
      "Note number: \(note.noteNumber)",
      "",
      note.bodyMarkdown
    ].joined(separator: "\n")
    let context = try XCTUnwrap(request.contextMarkdown)
    XCTAssertEqual(context, expectedContext)
    XCTAssertFalse(context.contains("# Related material from the user's notes"))
    XCTAssertFalse(context.contains("Neighbouring pages"))
  }

  func testPageOCRBoundIsCharacterBasedAndEditModeIsRefused() throws {
    let source = String(repeating: "界", count: 9_000)
    let bounded = boundedDocumentPageText(source, limit: DocumentPageChatBudget.subjectPageCharacters)
    XCTAssertEqual(String(bounded.dropLast(DocumentPageChatBudget.truncationMarker.count)).count, 8_000)
    XCTAssertTrue(bounded.hasSuffix(DocumentPageChatBudget.truncationMarker))

    let service = try makeService()
    let page = try service.createNotebookWithNotes(
      title: "Page", pages: [NotePageDraft(
        bodyMarkdown: "", readOnly: false, metaJSON: metadata(page: 1, origin: "origin"),
        searchText: "OCR"
      )]
    ).notes[0]
    let conversation = try service.startAgentConversation(subjectNoteId: page.noteId)
    XCTAssertThrowsError(try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Edit the page", agentAvailable: true, mode: .edit
    )) { error in
      XCTAssertEqual(error as? NoteServiceError, .invalidInput("note edit mode is not available for document pages"))
    }
  }

  func testOriginFailuresReturnNoticesWithoutImages() throws {
    let service = try makeService()
    let unsupported = try pageWithOrigin(service, data: Data([1, 2]), mediaType: "image/tiff")
    let unsupportedAddition = try XCTUnwrap(service.documentPageChatAdditions(
      subjectNoteId: unsupported.noteId, libraryId: try XCTUnwrap(service.getNotebook(unsupported.notebookId).libraryId),
      query: "page"
    ))
    XCTAssertTrue(unsupportedAddition.images.isEmpty)
    XCTAssertTrue(unsupportedAddition.contextAppendix.contains("The page image is too large or in an unsupported format and was not sent."))

    let oversized = try pageWithOrigin(
      service, data: Data(repeating: 1, count: AgentInvocationImage.maximumBytes + 1), mediaType: "image/png"
    )
    let oversizedAddition = try XCTUnwrap(service.documentPageChatAdditions(
      subjectNoteId: oversized.noteId, libraryId: try XCTUnwrap(service.getNotebook(oversized.notebookId).libraryId),
      query: "page"
    ))
    XCTAssertTrue(oversizedAddition.images.isEmpty)
    XCTAssertTrue(oversizedAddition.contextAppendix.contains("The page image is too large or in an unsupported format and was not sent."))

    let missing = try service.createNotebookWithNotes(
      title: "Missing origin", pages: [NotePageDraft(
        bodyMarkdown: "", readOnly: false, metaJSON: metadata(page: 1, origin: "missing-file"), searchText: "OCR"
      )]
    ).notes[0]
    let missingAddition = try XCTUnwrap(service.documentPageChatAdditions(
      subjectNoteId: missing.noteId, libraryId: try XCTUnwrap(service.getNotebook(missing.notebookId).libraryId),
      query: "page"
    ))
    XCTAssertTrue(missingAddition.images.isEmpty)
    XCTAssertTrue(missingAddition.contextAppendix.contains("The page image is unavailable and was not sent."))
  }

  func testRetrievalCapsResultsAndExcludesAgentConversationNotebooks() throws {
    let service = try makeService()
    let subject = try service.createNotebookWithNotes(
      title: "Page", pages: [NotePageDraft(
        bodyMarkdown: "", readOnly: false, metaJSON: metadata(page: 1, origin: "missing"), searchText: "OCR"
      )]
    ).notes[0]
    for index in 1...10 {
      _ = try service.createNote(title: "Related \(index)", bodyMarkdown: "lighthouse reference \(index)")
    }
    let foreignLibrary = try service.createLibrary(name: "outside-page-library")
    _ = try service.scoped(toLibrary: foreignLibrary.libraryId).createNote(
      bodyMarkdown: "lighthouse foreign library secret"
    )
    let conversationSubject = try service.createNote(bodyMarkdown: "Other subject")
    let chat = try service.startAgentConversation(subjectNoteId: conversationSubject.noteId)
    _ = try service.appendPendingAgentChatTurn(
      conversationNotebookId: chat.notebookId, userMarkdown: "lighthouse private conversation text",
      agentAvailable: true
    )

    let additions = try XCTUnwrap(service.documentPageChatAdditions(
      subjectNoteId: subject.noteId, libraryId: try XCTUnwrap(service.getNotebook(subject.notebookId).libraryId),
      query: "lighthouse"
    ))
    XCTAssertFalse(additions.contextAppendix.contains("private conversation text"))
    XCTAssertFalse(additions.contextAppendix.contains("foreign library secret"))
    XCTAssertEqual(additions.contextAppendix.components(separatedBy: " (note ").count - 1, 6)
  }

  func testNotebookSubjectContextUsesEveryPagesOCRAndPunctuationHasNoRetrievalSection() throws {
    let service = try makeService()
    let notebook = try service.createNotebookWithNotes(
      title: "Notebook pages", pages: (1...3).map { page in
        NotePageDraft(
          bodyMarkdown: "", readOnly: false, metaJSON: metadata(page: page, origin: "missing-\(page)"),
          noteNumber: page, searchText: "notebook page OCR \(page)"
        )
      }
    )
    let context = try service.notebookContextMarkdown(notebookId: notebook.notebook.notebookId)
    for page in 1...3 {
      XCTAssertTrue(context.contains("notebook page OCR \(page)"))
    }
    let subject = try XCTUnwrap(notebook.notes.first)
    let additions = try XCTUnwrap(service.documentPageChatAdditions(
      subjectNoteId: subject.noteId, libraryId: try XCTUnwrap(notebook.notebook.libraryId), query: "??"
    ))
    XCTAssertFalse(additions.contextAppendix.contains("# Related material from the user's notes"))
  }

  private func pageWithOrigin(_ service: NoteService, data: Data, mediaType: String) throws -> Note {
    let page = try service.createNotebookWithNotes(
      title: "Synthetic origin", pages: [NotePageDraft(
        bodyMarkdown: "", readOnly: false, metaJSON: metadata(page: 1, origin: "pending"), searchText: "OCR"
      )]
    ).notes[0]
    let attachment = try service.attachFile(
      noteId: page.noteId, data: data, role: .sourcePageImage, mediaType: mediaType
    )
    try service.driver.withDatabase { database in
      try database.execute(
        "UPDATE notes SET meta_json = jsonb(?) WHERE note_id = ?",
        bindings: [.text(metadata(page: 1, origin: attachment.file.fileId.rawValue)), .id(page.noteId)]
      )
    }
    return try service.getNote(page.noteId)
  }

  private func metadata(page: Int, origin: String) -> String {
    #"{"documentPage":{"pageNumber":\#(page),"ocrState":"complete","analysis":{"writingMode":"unknown","binding":"unknown"},"originFileId":"\#(origin)"}}"#
  }
}
