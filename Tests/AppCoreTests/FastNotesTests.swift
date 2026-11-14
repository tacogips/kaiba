import XCTest
@testable import AppCore

final class FastNotesTests: NoteTestCase {
  func testFeedSortsByCreationAndSearchesBeforePagination() throws {
    let service = try makeService()
    let old = try service.captureQuickMemo(bodyMarkdown: "Old Needle")
    let middle = try service.captureQuickMemo(bodyMarkdown: "Middle other")
    let newest = try service.createNote(bodyMarkdown: "Newest Needle")
    try service.driver.withDatabase { db in
      for (id, date) in [(old.noteId, "2026-01-01T00:00:00Z"), (middle.noteId, "2026-02-01T00:00:00Z"), (newest.noteId, "2026-03-01T00:00:00Z")] {
        try db.execute("UPDATE notes SET created_at = ? WHERE note_id = ?", bindings: [.text(date), .id(id)])
      }
    }
    _ = try service.updateNoteBody(noteId: old.noteId, bodyMarkdown: "Old Needle edited today")
    XCTAssertEqual(try service.fastNotes(limit: 2).map(\.noteId), [newest.noteId, middle.noteId])
    XCTAssertEqual(try service.fastNotes(limit: 2, offset: 2).map(\.noteId), [old.noteId])
    XCTAssertEqual(try service.fastNotes(query: "needle", limit: 1, offset: 1).map(\.noteId), [old.noteId])
    XCTAssertEqual(try service.fastNotes(query: "old edited").map(\.noteId), [old.noteId])
    XCTAssertTrue(try service.fastNotes(query: "%_' SQL").isEmpty)
    XCTAssertThrowsError(try service.fastNotes(limit: 0))
  }

  func testFeedExcludesInternalNotesAndEnforcesOwnerScope() throws {
    let service = try makeService()
    let own = try service.createNote(bodyMarkdown: "Public thought")
    let page = syntheticPageDraft(pageNumber: 1,
      originFileId: try insertSyntheticOriginFile(service, mediaType: "image/png"),
      originMediaType: "image/png", text: "Hidden PDF page", readOnly: false)
    let document = try service.createNotebookWithNotes(title: "Reference document", pages: [page])
    XCTAssertFalse(try service.fastNotes().contains { $0.notebookId == document.notebook.notebookId })
    let conversation = try service.startAgentConversation(subjectNoteId: own.noteId)
    _ = try service.appendPendingAgentChatTurn(conversationNotebookId: conversation.notebookId, userMarkdown: "Hidden AI thought", agentAvailable: false)
    XCTAssertFalse(try service.fastNotes().contains { $0.notebookId == conversation.notebookId })
    let user = try service.createUser(email: "fast-feed-other@example.com", displayName: "Other")
    let other = service.scoped(to: user.userId)
    let foreign = try other.captureQuickMemo(bodyMarkdown: "Other private thought")
    XCTAssertEqual(try other.fastNotes().map(\.noteId), [foreign.noteId])
    XCTAssertFalse(try other.fastNotes(query: "Public thought").contains { $0.noteId == own.noteId })
  }
}
