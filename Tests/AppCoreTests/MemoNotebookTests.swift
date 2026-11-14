import Foundation
@testable import AppCore
import XCTest

final class MemoNotebookTests: NoteTestCase {
  func testMemoOnEmptyChatStillInheritsItsSource() throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "Initial chat context")
    let chat = try service.startAgentConversation(subjectNoteId: note.noteId)
    let memo = try service.addNotebookComment(notebookId: chat.notebookId, bodyMarkdown: "First side thought")
    let notebook = try service.openMemoNotebook(commentId: memo.commentId)
    XCTAssertTrue(try XCTUnwrap(service.agentChatSubjectSnapshot(
      conversationNotebookId: notebook.notebookId, editMode: false
    ).markdown).contains("Initial chat context"))
  }

  func testOlderMemoIsMaterializedOnceWithoutLosingComment() throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "Legacy source")
    let id = CommentID.generate()
    try service.driver.withDatabase { db in
      try db.execute(
        """
        INSERT INTO note_comments (comment_id, note_id, notebook_id, body_markdown, author, created_at)
        VALUES (?, ?, ?, 'Legacy thought', 'user', '2026-01-01T00:00:00Z')
        """,
        bindings: [.id(id), .id(note.noteId), .id(note.notebookId)]
      )
    }
    XCTAssertTrue(try service.listAgentConversations(subjectNoteId: note.noteId).isEmpty)
    let notebook = try service.openMemoNotebook(commentId: id)
    XCTAssertEqual(try service.openMemoNotebook(commentId: id).notebookId, notebook.notebookId)
    XCTAssertEqual(try service.listComments(noteId: note.noteId).first?.bodyMarkdown, "Legacy thought")
    XCTAssertEqual(try service.listNotes(notebookId: notebook.notebookId).first?.bodyMarkdown, "Legacy thought")
  }

  func testSavingMemoCreatesReusableNotebookWithoutDispatch() throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "Source note")
    let before = try service.listAutoActionDispatchAttempts().count
    let memo = try service.addComment(noteId: note.noteId, bodyMarkdown: "Saved thought")
    let chats = try service.listAgentConversations(subjectNoteId: note.noteId)
    XCTAssertEqual(chats.count, 1)
    let notebook = try service.openMemoNotebook(commentId: memo.commentId)
    XCTAssertEqual(chats.first?.notebook.notebookId, notebook.notebookId)
    XCTAssertEqual(try service.openMemoNotebook(commentId: memo.commentId).notebookId, notebook.notebookId)
    let turns = try service.listNotes(notebookId: notebook.notebookId)
    XCTAssertEqual(turns.count, 1)
    XCTAssertEqual(turns.first?.bodyMarkdown, "Saved thought")
    XCTAssertEqual(turns.first.flatMap(NoteService.chatTurnState)?.status, .answered)
    XCTAssertEqual(try service.listAutoActionDispatchAttempts().count, before)
    let context = try XCTUnwrap(service.agentChatSubjectSnapshot(
      conversationNotebookId: notebook.notebookId, editMode: false
    ).markdown)
    XCTAssertTrue(context.contains("Source note"))
    XCTAssertTrue(context.contains(try service.getNotebook(note.notebookId).title))
    _ = try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "Changed source")
    XCTAssertEqual(try service.agentChatSubjectSnapshot(
      conversationNotebookId: notebook.notebookId, editMode: false
    ).markdown, context)
  }

  func testMemoOnChatInheritsHistoryAndAcceptsFollowUp() async throws {
    let service = try makeService()
    let source = try service.createNote(bodyMarkdown: "Original document")
    let parent = try service.startAgentConversation(subjectNoteId: source.noteId)
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: parent.notebookId, userMarkdown: "Parent question", agentAvailable: true
    )
    _ = try service.completeAgentChatTurn(turnNoteId: turn.noteId, assistantMarkdown: "Parent answer")
    let thought = "My side thought\n## Agent\nThis heading is part of my memo"
    let memo = try service.addComment(noteId: turn.noteId, bodyMarkdown: thought)
    let notebook = try service.openMemoNotebook(commentId: memo.commentId)
    let followUp = try service.appendPendingAgentChatTurn(
      conversationNotebookId: notebook.notebookId, userMarkdown: "Explain my thought", agentAvailable: true
    )
    let invoker = MemoCaptureInvoker()
    try await service.generateAgentChatReply(turnNoteId: followUp.noteId, invoker: invoker)
    let request = await invoker.request
    XCTAssertTrue(request?.contextMarkdown?.contains("Original document") == true)
    XCTAssertTrue(request?.contextMarkdown?.contains("Parent answer") == true)
    XCTAssertEqual(request?.turns.map(\.markdown), [thought, "Explain my thought"])
    XCTAssertEqual(try service.listNotes(notebookId: parent.notebookId).count, 1)
  }

  func testNotebookMemoRetainsSnapshotAndLibrary() throws {
    let service = try makeService()
    let library = try service.createLibrary(name: "private", authRequired: true)
    let scoped = service.scoped(toLibrary: library.libraryId)
    let note = try scoped.createNote(bodyMarkdown: "Notebook source")
    let memo = try scoped.addNotebookComment(notebookId: note.notebookId, bodyMarkdown: "Notebook memo")
    let notebook = try scoped.openMemoNotebook(commentId: memo.commentId)
    XCTAssertEqual(notebook.libraryId, library.libraryId)
    _ = try scoped.updateNoteBody(noteId: note.noteId, bodyMarkdown: "Later source")
    XCTAssertTrue(try XCTUnwrap(scoped.agentChatSubjectSnapshot(
      conversationNotebookId: notebook.notebookId, editMode: false
    ).markdown).contains("Notebook source"))
    XCTAssertThrowsError(try service.scoped(to: NoteStoreSchema.defaultUserId).unauthenticated()
      .openMemoNotebook(commentId: memo.commentId))
  }
}

private actor MemoCaptureInvoker: AgentInvoking {
  var request: AgentInvocationRequest?
  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    self.request = request
    return AgentInvocationResult(markdown: "Answer")
  }
}
