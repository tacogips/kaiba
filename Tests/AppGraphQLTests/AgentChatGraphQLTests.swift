import Foundation

import AppCore
import XCTest
@testable import AppGraphQL

private struct StubInvoker: AgentInvoking {
  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    AgentInvocationResult(markdown: "stub reply")
  }
}

final class AgentChatGraphQLTests: XCTestCase {
  func testSendAgentChatMessageCreatesConversationAndReportsUnavailable() async throws {
    let service = try makeService()
    let subject = try service.service.createNote(bodyMarkdown: "# Subject\nBody.")
    let executor = NoteGraphQLDocumentExecutor(service: service)

    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation Send($input: SendAgentChatMessageInput!) {
        sendAgentChatMessage(input: $input) {
          result { accepted status }
          conversationNotebookId
          turnNoteId
          agentStatus
        }
      }
      """,
      variables: ["input": .object([
        "subjectNoteId": .string(subject.noteId),
        "userMarkdown": .string("What is this about?"),
        "idempotencyKey": .string("turn-1")
      ])],
      operationName: "Send"
    ))
    XCTAssertTrue(response.handled)
    let payload = try graphQLPayload(response.body, field: "sendAgentChatMessage")
    XCTAssertEqual(try resultObject(payload)["accepted"], .bool(true))
    // No dispatcher installed on a bare service: agent-unavailable, but the
    // turn is persisted.
    XCTAssertEqual(payload["agentStatus"], .string("agent-unavailable"))
    guard case let .string(notebookId)? = payload["conversationNotebookId"] else {
      return XCTFail("expected conversationNotebookId")
    }
    guard case let .string(turnNoteId)? = payload["turnNoteId"] else {
      return XCTFail("expected turnNoteId")
    }
    let turn = try service.service.getNote(turnNoteId)
    XCTAssertEqual(NoteService.chatTurnState(of: turn)?.status, .unavailable)

    // Idempotent resend reuses the existing turn and conversation.
    let resend = await service.sendAgentChatMessage(GraphQLSendAgentChatMessageInput(
      subjectNoteId: subject.noteId,
      conversationNotebookId: notebookId,
      userMarkdown: "What is this about?",
      idempotencyKey: "turn-1"
    ))
    XCTAssertEqual(resend.turnNoteId, turnNoteId)
    XCTAssertEqual(try service.service.listNotes(notebookId: notebookId).count, 1)
  }

  func testSendAgentChatMessagePendingWhenDispatcherInstalled() async throws {
    let bare = try makeService()
    let subject = try bare.service.createNote(bodyMarkdown: "# Subject\nBody.")
    let dispatcher = KaibaAutoActionDispatcher(service: bare.service, invoker: StubInvoker())
    var withDispatcher = bare.service
    withDispatcher.autoActionDispatcher = dispatcher
    let service = GraphQLNoteGraphQLService(service: withDispatcher)

    let sent = await service.sendAgentChatMessage(GraphQLSendAgentChatMessageInput(
      subjectNoteId: subject.noteId,
      userMarkdown: "Ping"
    ))
    XCTAssertTrue(sent.result.accepted)
    XCTAssertEqual(sent.agentStatus, "pending")
    await withDispatcher.drainAutoActionDispatches()
  }

  func testSendAgentChatMessageRejectsNonConversationNotebook() async throws {
    let service = try makeService()
    let subject = try service.service.createNote(bodyMarkdown: "# Subject\nBody.")
    let sent = await service.sendAgentChatMessage(GraphQLSendAgentChatMessageInput(
      subjectNoteId: subject.noteId,
      conversationNotebookId: subject.notebookId,
      userMarkdown: "Hello"
    ))
    XCTAssertFalse(sent.result.accepted)
    XCTAssertEqual(sent.result.status, "invalid_request")
    XCTAssertEqual(sent.agentStatus, "error")
  }

  func testNoteConversationsQueryListsAndValidatesLimit() async throws {
    let service = try makeService()
    let subject = try service.service.createNote(bodyMarkdown: "# Subject\nBody.")
    _ = await service.sendAgentChatMessage(GraphQLSendAgentChatMessageInput(
      subjectNoteId: subject.noteId,
      userMarkdown: "Q1"
    ))
    let executor = NoteGraphQLDocumentExecutor(service: service)

    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      query Conversations($noteId: String!) {
        noteConversations(noteId: $noteId) {
          result { accepted }
          value { notebookId title updatedAt turnCount subjectNoteId }
        }
      }
      """,
      variables: ["noteId": .string(subject.noteId)],
      operationName: "Conversations"
    ))
    let payload = try graphQLPayload(response.body, field: "noteConversations")
    let values = try arrayValue(payload["value"], field: "noteConversations.value")
    XCTAssertEqual(values.count, 1)
    let conversation = try objectValue(values[0], field: "noteConversations.value[0]")
    XCTAssertEqual(conversation["subjectNoteId"], .string(subject.noteId))
    XCTAssertEqual(conversation["turnCount"], .integer(1))

    let outOfRange = await executor.execute(GraphQLDocumentRequest(
      query: """
      query Conversations($noteId: String!) {
        noteConversations(noteId: $noteId, limit: 500) { result { accepted } }
      }
      """,
      variables: ["noteId": .string(subject.noteId)],
      operationName: "Conversations"
    ))
    let errorBody = outOfRange.body
    XCTAssertNotNil(errorBody["errors"], "limit above 200 must be rejected, not clamped")
  }

  func testNoteCommentsQueryListsStoredComments() async throws {
    let service = try makeService()
    let note = try service.service.createNote(bodyMarkdown: "# Commented\nBody.")
    _ = try service.service.addComment(
      noteId: note.noteId,
      bodyMarkdown: "First memo",
      author: "tester"
    )
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      query Comments($noteId: String!) {
        noteComments(noteId: $noteId) {
          result { accepted }
          value { commentId noteId bodyMarkdown author createdAt }
        }
      }
      """,
      variables: ["noteId": .string(note.noteId)],
      operationName: "Comments"
    ))
    let payload = try graphQLPayload(response.body, field: "noteComments")
    XCTAssertEqual(try resultObject(payload)["accepted"], .bool(true))
    let values = try arrayValue(payload["value"], field: "noteComments.value")
    XCTAssertEqual(values.count, 1)
    let comment = try objectValue(values[0], field: "noteComments.value[0]")
    XCTAssertEqual(comment["bodyMarkdown"], .string("First memo"))
    XCTAssertEqual(comment["author"], .string("tester"))

    let missing = await service.noteComments(noteId: "note-missing")
    XCTAssertEqual(missing.result.status, "not_found")
  }

  func testRequestTagExtractionStatuses() async throws {
    let bare = try makeService()
    let note = try bare.service.createNote(bodyMarkdown: "# Doc\nBody.")

    // Without a dispatcher: agent-unavailable, nothing queued.
    let unavailable = await bare.requestTagExtraction(
      GraphQLRequestTagExtractionInput(noteId: note.noteId)
    )
    XCTAssertTrue(unavailable.result.accepted)
    XCTAssertEqual(unavailable.status, "agent-unavailable")
    XCTAssertTrue(try bare.service.listAutoActionDispatchAttempts().isEmpty)

    // Exactly-one-subject validation.
    let both = await bare.requestTagExtraction(GraphQLRequestTagExtractionInput(
      noteId: note.noteId,
      notebookId: note.notebookId
    ))
    XCTAssertFalse(both.result.accepted)
    XCTAssertEqual(both.status, "error")

    // With a dispatcher: queued and eventually dispatched.
    let dispatcher = KaibaAutoActionDispatcher(service: bare.service, invoker: StubInvoker())
    var withDispatcher = bare.service
    withDispatcher.autoActionDispatcher = dispatcher
    let service = GraphQLNoteGraphQLService(service: withDispatcher)
    let queued = await service.requestTagExtraction(
      GraphQLRequestTagExtractionInput(noteId: note.noteId)
    )
    XCTAssertEqual(queued.status, "queued")
    await withDispatcher.drainAutoActionDispatches()
    let attempts = try withDispatcher.listAutoActionDispatchAttempts()
    XCTAssertEqual(attempts.count, 1)
    XCTAssertEqual(attempts[0].record.action.actionId, NoteService.manualTagExtractionActionId)
  }

  // MARK: - Helpers

  private func makeService(function: String = #function) throws -> GraphQLNoteGraphQLService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/AppGraphQLTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let noteService = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    return GraphQLNoteGraphQLService(service: noteService)
  }

  private func graphQLPayload(_ body: JSONObject, field: String) throws -> JSONObject {
    let data = try objectValue(body["data"], field: "data")
    return try objectValue(data[field], field: field)
  }

  private func resultObject(_ payload: JSONObject) throws -> JSONObject {
    try objectValue(payload["result"], field: "result")
  }

  private func objectValue(_ value: JSONValue?, field: String) throws -> JSONObject {
    guard case let .object(object)? = value else {
      throw NSError(domain: "AgentChatGraphQLTests", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "expected object at \(field)"
      ])
    }
    return object
  }

  private func arrayValue(_ value: JSONValue?, field: String) throws -> [JSONValue] {
    guard case let .array(values)? = value else {
      throw NSError(domain: "AgentChatGraphQLTests", code: 2, userInfo: [
        NSLocalizedDescriptionKey: "expected array at \(field)"
      ])
    }
    return values
  }
}
