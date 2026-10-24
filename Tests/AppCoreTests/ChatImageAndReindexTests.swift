import Foundation
import XCTest
@testable import AppCore

private actor RegionChatInvoker: AgentInvoking {
  var requests: [AgentInvocationRequest] = []
  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    requests.append(request)
    return AgentInvocationResult(markdown: "The selected region contains a diagram.")
  }
  func recorded() -> [AgentInvocationRequest] { requests }
}

final class ChatImageAndReindexTests: NoteTestCase {
  func testSelectedImageReachesProviderAndRemainsAvailableForFollowUp() async throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "Source page")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let bytes = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l90AAAAASUVORK5CYII="))
    let attachment = try AgentChatAttachmentValidation.validate(data: bytes, declaredMediaType: "image/png", originalFilename: "page-1-selection.png")
    let first = try service.appendPendingAgentChatTurn(conversationNotebookId: conversation.notebookId,
      userMarkdown: "What is in this region?", agentAvailable: true, attachments: [attachment])
    let invoker = RegionChatInvoker()
    try await service.generateAgentChatReply(turnNoteId: first.noteId, invoker: invoker)
    let followUp = try service.appendPendingAgentChatTurn(conversationNotebookId: conversation.notebookId,
      userMarkdown: "Explain that diagram", agentAvailable: true)
    try await service.generateAgentChatReply(turnNoteId: followUp.noteId, invoker: invoker)
    let requests = await invoker.recorded()
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests.first?.images, [AgentInvocationImage(data: bytes, mediaType: "image/png")])
    XCTAssertEqual(requests.last?.images, requests.first?.images)
    XCTAssertTrue(requests.first?.turns.last?.markdown.contains("page-1-selection.png") == true)
    XCTAssertEqual(try service.listFiles(noteId: first.noteId).count, 1)
    XCTAssertThrowsError(try AgentChatAttachmentValidation.validate([
      AgentChatAttachment(data: Data("fake PNG".utf8), mediaType: "image/png", originalFilename: "fake.png")
    ]))
  }

  func testConversationQuestionsAndRepliesArePersistedAndIndexedAndNotebookRebuildIncludesThem() async throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "Source page")
    let unrelated = try service.createNotebook(title: "Unrelated notebook")
    let engine = FakeSearchEngine()
    _ = try service.activateSearchEngineSync(indexIdentity: engine.indexIdentity)
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let turn = try service.appendPendingAgentChatTurn(conversationNotebookId: conversation.notebookId,
      userMarkdown: "UniqueQuestionMarker", agentAvailable: true)
    _ = try service.completeAgentChatTurn(turnNoteId: turn.noteId, assistantMarkdown: "UniqueAnswerMarker")
    XCTAssertTrue(try service.searchNotes(query: "UniqueQuestionMarker").contains { $0.note.noteId == turn.noteId })
    XCTAssertTrue(try service.searchNotes(query: "UniqueAnswerMarker").contains { $0.note.noteId == turn.noteId })
    _ = try await SearchIndexSynchronizer(service: service).drainUntilIdle(engine: engine)
    XCTAssertTrue(engine.documents[turn.noteId]?.body.contains("UniqueQuestionMarker") == true)
    XCTAssertTrue(engine.documents[turn.noteId]?.body.contains("UniqueAnswerMarker") == true)
    let branch = try service.startAgentConversation(subjectNoteId: turn.noteId)
    _ = try service.appendPendingAgentChatTurn(conversationNotebookId: branch.notebookId,
      userMarkdown: "Branch question", agentAvailable: false)
    let report = try service.rebuildNotebookSearchIndex(notebookId: subject.notebookId)
    XCTAssertEqual(report.notes, 1)
    XCTAssertEqual(report.conversationTurns, 2)
    XCTAssertTrue(report.engineQueued)
    let other = try service.createUser(email: "other-reindex@example.com", displayName: "Other")
    XCTAssertThrowsError(try service.scoped(to: other.userId).rebuildNotebookSearchIndex(notebookId: subject.notebookId))
    XCTAssertEqual(try service.rebuildNotebookSearchIndex(notebookId: unrelated.notebookId).notes, 0)
  }
  func testRelatedTopicsIdentifyDestinationTagAndCommonAncestor() throws {
    let service = try makeService()
    let parent = try service.defineTag(name: "Mathematics", classId: .topic)
    let graphs = try service.defineTag(name: "Graphs", classId: .topic, parentTagId: parent.tagId)
    let networks = try service.defineTag(name: "Networks", classId: .topic, parentTagId: parent.tagId)
    let source = try service.createNote(bodyMarkdown: "Source", tags: [NoteTagInput(name: graphs.name, classId: .topic)])
    let destination = try service.createNote(bodyMarkdown: "Destination", tags: [NoteTagInput(name: networks.name, classId: .topic)])
    let names = try service.driver.withDatabase { db in
      let signals = try relatedSignals(forSourceNoteId: source.noteId, in: db)
      return try enrichRelatedReasons([SearchEngineHit(noteId: destination.noteId, score: 1, highlight: nil,
        reasons: [SearchEngineHitReason(kind: .relatedTag)])], sourceSharedTagIds: signals.sharedTagIds,
        sourceNearTagIds: signals.nearTagIds, sourceAncestorTagIds: signals.ancestorTagIds, in: db)
    }
    XCTAssertEqual(names.first?.reasons.first?.tagNames, ["Networks (via Mathematics)"])
  }

}
