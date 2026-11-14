import Foundation
@testable import AppCore
import XCTest

private struct StubChatInvoker: AgentInvoking {
  var reply: String
  var error: AgentInvocationError?

  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    if let error {
      throw error
    }
    return AgentInvocationResult(markdown: reply)
  }
}

final class AgentChatTests: NoteTestCase {
  func testStartConversationBindsSubjectAndKind() throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# The Document\nContent.")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)

    XCTAssertTrue(conversation.title.contains("The Document"))
    XCTAssertTrue(conversation.tags.contains {
      $0.tag.name == NoteStoreSchema.agentConversationNotebookKindTag
    })
    XCTAssertEqual(
      try service.chatSubjectNoteId(notebookId: conversation.notebookId),
      subject.noteId
    )
  }

  func testPendingTurnLifecycleCompleteAndFail() throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\nBody.")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)

    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "What is this about?",
      agentAvailable: true
    )
    var state = try XCTUnwrap(NoteService.chatTurnState(of: turn))
    XCTAssertEqual(state.status, .pending)
    XCTAssertEqual(state.userMarkdown, "What is this about?")
    XCTAssertTrue(turn.bodyMarkdown.contains("_(no reply yet)_"))

    let links = try service.listLinks(noteId: turn.noteId)
    XCTAssertTrue(links.contains {
      $0.toNoteId == subject.noteId && $0.linkKind == "source-citation"
    })

    let answered = try service.completeAgentChatTurn(
      turnNoteId: turn.noteId,
      assistantMarkdown: "It is about testing."
    )
    state = try XCTUnwrap(NoteService.chatTurnState(of: answered))
    XCTAssertEqual(state.status, .answered)
    XCTAssertTrue(answered.bodyMarkdown.contains("It is about testing."))
    XCTAssertEqual(
      NoteService.assistantMarkdown(fromTurnBody: answered.bodyMarkdown),
      "It is about testing."
    )

    let secondTurn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Another question",
      agentAvailable: true
    )
    let failed = try service.failAgentChatTurn(
      turnNoteId: secondTurn.noteId,
      message: "model exploded"
    )
    let failedState = try XCTUnwrap(NoteService.chatTurnState(of: failed))
    XCTAssertEqual(failedState.status, .failed)
    XCTAssertEqual(failedState.errorMessage, "model exploded")
  }

  func testUnavailableStatusWhenAgentMissing() throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\nBody.")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Anyone there?",
      agentAvailable: false
    )
    XCTAssertEqual(NoteService.chatTurnState(of: turn)?.status, .unavailable)
  }

  func testIdempotentSendReplaysExistingTurn() throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\nBody.")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let first = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Same question",
      agentAvailable: true,
      idempotencyKey: "key-1"
    )
    let replay = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Same question",
      agentAvailable: true,
      idempotencyKey: "key-1"
    )
    XCTAssertEqual(first.noteId, replay.noteId)
    XCTAssertEqual(try service.listNotes(notebookId: conversation.notebookId).count, 1)
  }

  func testRejectsNonConversationNotebookAndEmptyMessage() throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Plain\nBody.")
    XCTAssertThrowsError(try service.appendPendingAgentChatTurn(
      conversationNotebookId: note.notebookId,
      userMarkdown: "hello",
      agentAvailable: true
    ))
    let conversation = try service.startAgentConversation(subjectNoteId: note.noteId)
    XCTAssertThrowsError(try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "   ",
      agentAvailable: true
    ))
  }

  func testListAgentConversationsFindsBySubject() throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\nBody.")
    let other = try service.createNote(bodyMarkdown: "# Other\nBody.")
    let conversationA = try service.startAgentConversation(subjectNoteId: subject.noteId)
    _ = try service.startAgentConversation(subjectNoteId: other.noteId)
    _ = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversationA.notebookId,
      userMarkdown: "Q1",
      agentAvailable: false
    )

    let conversations = try service.listAgentConversations(subjectNoteId: subject.noteId)
    XCTAssertEqual(conversations.count, 1)
    XCTAssertEqual(conversations[0].notebook.notebookId, conversationA.notebookId)
    XCTAssertEqual(conversations[0].turnCount, 1)
  }

  func testGenerateReplyCompletesPendingTurnAndSkipsAnswered() async throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\nDocument content.")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Summarize this.",
      agentAvailable: true
    )
    try await service.generateAgentChatReply(
      turnNoteId: turn.noteId,
      invoker: StubChatInvoker(reply: "A concise summary.")
    )
    let answered = try service.getNote(turn.noteId)
    XCTAssertEqual(NoteService.chatTurnState(of: answered)?.status, .answered)
    XCTAssertTrue(answered.bodyMarkdown.contains("A concise summary."))

    // A retry must not re-invoke (an error invoker would throw).
    try await service.generateAgentChatReply(
      turnNoteId: turn.noteId,
      invoker: StubChatInvoker(reply: "", error: .failed("must not be called"))
    )
    XCTAssertEqual(
      NoteService.chatTurnState(of: try service.getNote(turn.noteId))?.status,
      .answered
    )
  }

  func testGenerateReplyFailureMarksTurnFailedAndStaysRetryable() async throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\nBody.")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Question",
      agentAvailable: true
    )
    do {
      try await service.generateAgentChatReply(
        turnNoteId: turn.noteId,
        invoker: StubChatInvoker(reply: "", error: .unavailable("down"))
      )
      XCTFail("expected throw")
    } catch {}
    XCTAssertEqual(
      NoteService.chatTurnState(of: try service.getNote(turn.noteId))?.status,
      .failed
    )

    // A later retry succeeds and answers the turn.
    try await service.generateAgentChatReply(
      turnNoteId: turn.noteId,
      invoker: StubChatInvoker(reply: "Recovered answer.")
    )
    XCTAssertEqual(
      NoteService.chatTurnState(of: try service.getNote(turn.noteId))?.status,
      .answered
    )
  }
}
