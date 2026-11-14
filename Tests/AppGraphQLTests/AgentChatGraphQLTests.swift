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
  func testAgentModelsQueryProjectsConfiguredFallback() async throws {
    let base = try makeService()
    let service = GraphQLNoteGraphQLService(
      service: base.service,
      agentProvider: "openai",
      agentModel: "configured-model"
    )
    let response = await NoteGraphQLDocumentExecutor(service: service).execute(GraphQLDocumentRequest(
      query: """
      query AgentModels {
        agentModels {
          result { accepted status }
          discoveryAvailable
          configuredModel
          models { modelId displayName }
        }
      }
      """,
      variables: [:],
      operationName: "AgentModels"
    ))
    XCTAssertTrue(response.handled)
    let payload = try graphQLPayload(response.body, field: "agentModels")
    XCTAssertEqual(try resultObject(payload)["accepted"], .bool(true))
    XCTAssertEqual(payload["configuredModel"], .string("configured-model"))
    XCTAssertEqual(try arrayValue(payload["models"], field: "agentModels.models").count, 1)
  }

  func testAgentModelsReturnsConfiguredFallbackAndRejectsUnknownModel() async throws {
    let base = try makeService()
    let subject = try base.service.createNote(bodyMarkdown: "# Subject\nBody.")
    let service = GraphQLNoteGraphQLService(
      service: base.service,
      agentProvider: "openai",
      agentModel: "configured-model"
    )
    let models = await service.agentModels()
    XCTAssertTrue(models.result.accepted)
    XCTAssertFalse(models.discoveryAvailable)
    XCTAssertEqual(models.models.map(\.modelId), ["configured-model"])
    let rejected = await service.sendAgentChatMessage(GraphQLSendAgentChatMessageInput(
      subjectNoteId: subject.noteId, userMarkdown: "Question", model: "unknown-model"
    ))
    XCTAssertFalse(rejected.result.accepted)
  }

  func testAgentModelsUsesSuccessfulCatalogAndKeepsConfiguredModelSelectable() async throws {
    let base = try makeService()
    let service = GraphQLNoteGraphQLService(
      service: base.service,
      agentProvider: "openai",
      agentModel: "configured-model",
      agentModelCatalog: {
        AgentGatewayModelCatalogResult(
          protocolVersion: "1", vendor: "openai",
          models: [AgentGatewayModelInfo(modelId: "catalog-model", name: "Catalog model")]
        )
      }
    )

    let models = await service.agentModels()
    XCTAssertTrue(models.discoveryAvailable)
    XCTAssertEqual(models.result.status, "ok")
    XCTAssertEqual(models.models.map(\.modelId), ["configured-model", "catalog-model"])
    XCTAssertEqual(models.models.last?.displayName, "Catalog model")
  }

  func testAgentModelsReportsFallbackWhenCatalogThrows() async throws {
    struct CatalogFailure: Error {}
    let base = try makeService()
    let service = GraphQLNoteGraphQLService(
      service: base.service,
      agentProvider: "openai",
      agentModel: "configured-model",
      agentModelCatalog: { throw CatalogFailure() }
    )

    let models = await service.agentModels()
    XCTAssertFalse(models.discoveryAvailable)
    XCTAssertEqual(models.result.status, "fallback")
    XCTAssertEqual(models.models.map(\.modelId), ["configured-model"])
  }

  func testSendAgentChatMessageValidatesMode() async throws {
    let service = try makeService()
    let subject = try service.service.createNote(bodyMarkdown: "# Subject\nBody.")

    let editSent = await service.sendAgentChatMessage(GraphQLSendAgentChatMessageInput(
      subjectNoteId: subject.noteId, userMarkdown: "Reword this", mode: "edit"
    ))
    XCTAssertTrue(editSent.result.accepted)
    let editTurnId = try XCTUnwrap(editSent.turnNoteId)
    XCTAssertEqual(
      NoteService.chatTurnState(of: try service.service.getNote(editTurnId))?.mode,
      .edit
    )

    // "memo" is the default and persists identical metadata to omitting mode.
    let memoSent = await service.sendAgentChatMessage(GraphQLSendAgentChatMessageInput(
      subjectNoteId: subject.noteId, userMarkdown: "Just asking", mode: "memo"
    ))
    XCTAssertTrue(memoSent.result.accepted)
    let memoTurnId = try XCTUnwrap(memoSent.turnNoteId)
    XCTAssertNil(NoteService.chatTurnState(of: try service.service.getNote(memoTurnId))?.mode)

    let unsupported = await service.sendAgentChatMessage(GraphQLSendAgentChatMessageInput(
      subjectNoteId: subject.noteId, userMarkdown: "Rewrite", mode: "rewrite"
    ))
    XCTAssertFalse(unsupported.result.accepted)

    let notebookRejected = await service.sendAgentChatMessage(GraphQLSendAgentChatMessageInput(
      subjectNotebookId: subject.notebookId, userMarkdown: "Edit the notebook", mode: "edit"
    ))
    XCTAssertFalse(notebookRejected.result.accepted)
    XCTAssertTrue(
      try service.service.listAgentConversations(subjectNotebookId: subject.notebookId).isEmpty
    )
  }

  func testSendAgentChatMessageRejectsEditModeForReadOnlyNoteBeforeConversationCreation() async throws {
    let service = try makeService()
    let subject = try service.service.createNote(bodyMarkdown: "# Locked\nBody.")
    _ = try service.service.setReadOnly(noteId: subject.noteId, readOnly: true)
    let rejected = await service.sendAgentChatMessage(GraphQLSendAgentChatMessageInput(
      subjectNoteId: subject.noteId, userMarkdown: "Edit a locked note", mode: "edit"
    ))
    XCTAssertFalse(rejected.result.accepted)
    XCTAssertTrue(try service.service.listAgentConversations(subjectNoteId: subject.noteId).isEmpty)
  }

  func testAttachmentInputRejectsBeforeConversationCreation() async throws {
    let service = try makeService()
    let subject = try service.service.createNote(bodyMarkdown: "# Subject\nBody.")
    let sent = await service.sendAgentChatMessage(GraphQLSendAgentChatMessageInput(
      subjectNoteId: subject.noteId,
      userMarkdown: "Question",
      attachments: [GraphQLAgentChatAttachmentInput(
        contentBase64: "not-base64", mediaType: "text/plain", originalFilename: "x.txt"
      )]
    ))
    XCTAssertFalse(sent.result.accepted)
    XCTAssertTrue(try service.service.listAgentConversations(subjectNoteId: subject.noteId).isEmpty)
  }

  func testAttachmentInputRejectsExcessFilesBeforeConversationCreation() async throws {
    let service = try makeService()
    let subject = try service.service.createNote(bodyMarkdown: "# Subject\nBody.")
    let attachments = (0..<5).map { index in
      GraphQLAgentChatAttachmentInput(
        contentBase64: Data("file \(index)".utf8).base64EncodedString(),
        mediaType: "text/plain",
        originalFilename: "\(index).txt"
      )
    }
    let sent = await service.sendAgentChatMessage(GraphQLSendAgentChatMessageInput(
      subjectNoteId: subject.noteId,
      userMarkdown: "Question",
      attachments: attachments
    ))
    XCTAssertFalse(sent.result.accepted)
    XCTAssertTrue(try service.service.listAgentConversations(subjectNoteId: subject.noteId).isEmpty)
  }

  func testAttachmentInputRoundTripsToTurnFile() async throws {
    let service = try makeService()
    let subject = try service.service.createNote(bodyMarkdown: "# Subject\nBody.")
    let sent = await service.sendAgentChatMessage(GraphQLSendAgentChatMessageInput(
      subjectNoteId: subject.noteId,
      userMarkdown: "Question",
      attachments: [GraphQLAgentChatAttachmentInput(
        contentBase64: Data("attached text".utf8).base64EncodedString(),
        mediaType: "text/plain",
        originalFilename: "reference.txt"
      )]
    ))
    XCTAssertTrue(sent.result.accepted)
    let turnNoteId = try XCTUnwrap(sent.turnNoteId)
    let attachment = try XCTUnwrap(try service.service.listFiles(noteId: turnNoteId).first)
    XCTAssertEqual(attachment.file.originalFilename, "reference.txt")
    XCTAssertEqual(try service.service.resolveFileContent(fileId: attachment.file.fileId), Data("attached text".utf8))
  }

  func testAttachmentInputRequiresCanonicalBase64AndUsesFilenameFallbackForGenericMIME() async throws {
    let service = try makeService()
    let subject = try service.service.createNote(bodyMarkdown: "# Subject\nBody.")
    let rejected = await service.sendAgentChatMessage(GraphQLSendAgentChatMessageInput(
      subjectNoteId: subject.noteId,
      userMarkdown: "Question",
      attachments: [GraphQLAgentChatAttachmentInput(
        contentBase64: "YQ", mediaType: "text/plain", originalFilename: "not-canonical.txt"
      )]
    ))
    XCTAssertFalse(rejected.result.accepted)

    let accepted = await service.sendAgentChatMessage(GraphQLSendAgentChatMessageInput(
      subjectNoteId: subject.noteId,
      userMarkdown: "Question",
      attachments: [GraphQLAgentChatAttachmentInput(
        contentBase64: Data("fallback".utf8).base64EncodedString(),
        mediaType: "application/octet-stream",
        originalFilename: "fallback.md"
      )]
    ))
    XCTAssertTrue(accepted.result.accepted)
    let attachment = try XCTUnwrap(try service.service.listFiles(
      noteId: try XCTUnwrap(accepted.turnNoteId)
    ).first)
    XCTAssertEqual(attachment.file.mediaType, "text/markdown")
  }

  func testAttachmentInputRejectsSpoofedOrUnsupportedDeclaredMediaTypesBeforeConversationCreation() async throws {
    let service = try makeService()
    let subject = try service.service.createNote(bodyMarkdown: "# Subject\nBody.")
    for mediaType in ["text/html", "application/pdf"] {
      let sent = await service.sendAgentChatMessage(GraphQLSendAgentChatMessageInput(
        subjectNoteId: subject.noteId,
        userMarkdown: "Question",
        attachments: [GraphQLAgentChatAttachmentInput(
          contentBase64: Data("plain text".utf8).base64EncodedString(),
          mediaType: mediaType,
          originalFilename: "appears-safe.txt"
        )]
      ))
      XCTAssertFalse(sent.result.accepted, mediaType)
    }
    XCTAssertTrue(try service.service.listAgentConversations(subjectNoteId: subject.noteId).isEmpty)
  }

  func testExistingConversationRejectsDifferentSubject() async throws {
    let service = try makeService()
    let first = try service.service.createNote(bodyMarkdown: "# First\nBody.")
    let second = try service.service.createNote(bodyMarkdown: "# Second\nBody.")
    let sent = await service.sendAgentChatMessage(GraphQLSendAgentChatMessageInput(
      subjectNoteId: first.noteId, userMarkdown: "Question"
    ))
    let rejected = await service.sendAgentChatMessage(GraphQLSendAgentChatMessageInput(
      subjectNoteId: second.noteId,
      conversationNotebookId: try XCTUnwrap(sent.conversationNotebookId),
      userMarkdown: "Question"
    ))
    XCTAssertFalse(rejected.result.accepted)
  }

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

  func testRequestNotebookTranslationStatuses() async throws {
    let bare = try makeService()
    let ingest = try bare.service.createNotebookWithNotes(
      title: "Guide",
      pages: [NotePageDraft(bodyMarkdown: "# One\nBody.")]
    )

    // Without a dispatcher: agent-unavailable, nothing created or queued.
    let unavailable = await bare.requestNotebookTranslation(
      GraphQLRequestNotebookTranslationInput(
        notebookId: ingest.notebook.notebookId,
        targetLanguage: "English"
      )
    )
    XCTAssertTrue(unavailable.result.accepted)
    XCTAssertEqual(unavailable.status, "agent-unavailable")
    XCTAssertNil(unavailable.translationNotebookId)
    XCTAssertTrue(try bare.service.listAutoActionDispatchAttempts().isEmpty)

    // Unknown source notebook surfaces as a rejected result.
    let missing = await bare.requestNotebookTranslation(
      GraphQLRequestNotebookTranslationInput(
        notebookId: "notebook-missing",
        targetLanguage: "English"
      )
    )
    XCTAssertFalse(missing.result.accepted)
    XCTAssertEqual(missing.status, "error")

    // With a dispatcher: the pending notebook is returned and the run queued.
    let dispatcher = KaibaAutoActionDispatcher(service: bare.service, invoker: StubInvoker())
    var withDispatcher = bare.service
    withDispatcher.autoActionDispatcher = dispatcher
    let service = GraphQLNoteGraphQLService(service: withDispatcher)
    let queued = await service.requestNotebookTranslation(
      GraphQLRequestNotebookTranslationInput(
        notebookId: ingest.notebook.notebookId,
        targetLanguage: "English"
      )
    )
    XCTAssertEqual(queued.status, "queued")
    let translationNotebookId = try XCTUnwrap(queued.translationNotebookId)
    await withDispatcher.drainAutoActionDispatches()
    let attempts = try withDispatcher.listAutoActionDispatchAttempts()
    XCTAssertEqual(attempts.count, 1)
    XCTAssertEqual(attempts[0].record.action.actionId, NoteService.manualTranslationActionId)
    let finished = try withDispatcher.getNotebook(translationNotebookId)
    XCTAssertEqual(NoteService.translationState(of: finished)?.status, .completed)
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
