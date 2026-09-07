import Foundation
@testable import AppCore
import XCTest

final class AgentChatBranchTests: NoteTestCase {
  func testBranchCapturesHistoryThroughSelectedNoteAndRemainsIndependent() throws {
    let service = try makeService()
    let document = try service.createNote(bodyMarkdown: "Original source context")
    let parent = try service.startAgentConversation(subjectNoteId: document.noteId)
    let first = try answeredTurn(service, notebook: parent, question: "First question", answer: "First answer")
    _ = try answeredTurn(service, notebook: parent, question: "Later question", answer: "Later answer")
    let branch = try service.startAgentConversation(subjectNoteId: first.noteId)
    let initial = try service.agentChatSubjectSnapshot(conversationNotebookId: branch.notebookId, editMode: false)
    let context = try XCTUnwrap(initial.markdown)
    XCTAssertTrue(context.contains("Original source context"))
    XCTAssertTrue(context.contains("First question"))
    XCTAssertTrue(context.contains("First answer"))
    XCTAssertFalse(context.contains("Later question"))

    _ = try service.updateNoteBody(noteId: first.noteId, bodyMarkdown: "Edited parent")
    _ = try answeredTurn(service, notebook: parent, question: "Future question", answer: "Future answer")
    let branchTurn = try answeredTurn(service, notebook: branch, question: "Branch question", answer: "Branch answer")
    let current = try service.agentChatSubjectSnapshot(conversationNotebookId: branch.notebookId, editMode: false)
    XCTAssertEqual(current.markdown, context)
    let nested = try service.startAgentConversation(subjectNoteId: branchTurn.noteId)
    let nestedContext = try XCTUnwrap(service.agentChatSubjectSnapshot(
      conversationNotebookId: nested.notebookId, editMode: false
    ).markdown)
    XCTAssertTrue(nestedContext.contains("Original source context"))
    XCTAssertTrue(nestedContext.contains("First answer"))
    XCTAssertTrue(nestedContext.contains("Branch answer"))
    XCTAssertFalse(nestedContext.contains("Future question"))
  }

  func testOrdinaryNoteChatKeepsExistingContextBehavior() throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "Ordinary note")
    let chat = try service.startAgentConversation(subjectNoteId: note.noteId)
    XCTAssertNil(try NoteService.savedBranchContext(chat))
    let context = try XCTUnwrap(service.agentChatSubjectSnapshot(
      conversationNotebookId: chat.notebookId, editMode: false
    ).markdown)
    XCTAssertTrue(context.contains("Ordinary note"))
    XCTAssertTrue(context.contains(note.notebookId.rawValue))
  }

  func testLargeSubjectAndBranchRemainComplete() throws {
    let service = try makeService()
    let body = String(repeating: "x", count: 300 * 1024) + "End of source"
    let note = try service.createNote(bodyMarkdown: body)
    let chat = try service.startAgentConversation(subjectNoteId: note.noteId)
    let turn = try answeredTurn(service, notebook: chat, question: "Question", answer: "Answer")
    for editMode in [false, true] {
      XCTAssertTrue(try XCTUnwrap(service.agentChatSubjectSnapshot(
        conversationNotebookId: chat.notebookId, editMode: editMode
      ).markdown).contains(body))
    }
    let branch = try service.startAgentConversation(subjectNoteId: turn.noteId)
    let context = try XCTUnwrap(service.agentChatSubjectSnapshot(
      conversationNotebookId: branch.notebookId, editMode: false
    ).markdown)
    XCTAssertTrue(context.contains(body))
    XCTAssertTrue(context.contains("Answer"))
  }

  func testBranchSnapshotsParentAttachmentText() throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "Source")
    let parent = try service.startAgentConversation(subjectNoteId: note.noteId)
    let text = String(repeating: "Attachment context ", count: 20_000) + "Attachment end"
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: parent.notebookId, userMarkdown: "Question", agentAvailable: true,
      attachments: [AgentChatAttachment(
        data: Data(text.utf8), mediaType: "text/plain", originalFilename: "reference.txt"
      )]
    )
    let branch = try service.startAgentConversation(subjectNoteId: turn.noteId)
    let context = try XCTUnwrap(service.agentChatSubjectSnapshot(
      conversationNotebookId: branch.notebookId, editMode: false
    ).markdown)
    XCTAssertTrue(context.contains(text))
    XCTAssertTrue(context.contains("filename=\"reference.txt\""))
    let nestedTurn = try answeredTurn(service, notebook: branch, question: "Follow-up", answer: "Reply")
    let nested = try service.startAgentConversation(subjectNoteId: nestedTurn.noteId)
    XCTAssertTrue(try XCTUnwrap(service.agentChatSubjectSnapshot(
      conversationNotebookId: nested.notebookId, editMode: false
    ).markdown).contains(text))
  }

  private func answeredTurn(
    _ service: NoteService, notebook: Notebook, question: String, answer: String
  ) throws -> Note {
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: notebook.notebookId, userMarkdown: question, agentAvailable: true
    )
    return try service.completeAgentChatTurn(turnNoteId: turn.noteId, assistantMarkdown: answer)
  }

  func testNotebookContextIncludesNotesPastFormerPageLimit() throws {
    let service = try makeService()
    let result = try service.createNotebookWithNotes(
      title: "Long notebook",
      pages: (1...201).map { NotePageDraft(bodyMarkdown: "Page \($0)") }
    )
    let context = try service.notebookContextMarkdown(notebookId: result.notebook.notebookId)
    XCTAssertTrue(context.contains("Page 201"))
  }

  func testProviderReceivesHistoryPastOneHundredTurns() async throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "Source")
    let conversation = try service.startAgentConversation(subjectNoteId: note.noteId)
    for index in 1...101 {
      _ = try answeredTurn(service, notebook: conversation, question: "Question \(index)", answer: "Answer \(index)")
    }
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId, userMarkdown: "Final question", agentAvailable: true
    )
    let invoker = BranchHistoryInvoker()
    try await service.generateAgentChatReply(turnNoteId: turn.noteId, invoker: invoker)
    let request = await invoker.request
    XCTAssertEqual(request?.turns.count, 203)
    XCTAssertEqual(request?.turns.first?.markdown, "Question 1")
    XCTAssertTrue(request?.turns.contains { $0.markdown == "Answer 101" } == true)
  }
}

private actor BranchHistoryInvoker: AgentInvoking {
  var request: AgentInvocationRequest?

  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    self.request = request
    return AgentInvocationResult(markdown: "Done")
  }
}
