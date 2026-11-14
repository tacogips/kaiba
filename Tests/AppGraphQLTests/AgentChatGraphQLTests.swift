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
  func testAgentModelsSharesInFlightCatalogAndCachesResult() async throws {
    actor CatalogCounter {
      var calls = 0

      func load() -> AgentGatewayModelCatalogResult {
        calls += 1
        return AgentGatewayModelCatalogResult(
          protocolVersion: "1",
          vendor: "openai",
          models: [AgentGatewayModelInfo(modelId: "catalog-model")]
        )
      }
    }
    let base = try makeService()
    let counter = CatalogCounter()
    let service = GraphQLNoteGraphQLService(
      service: base.service,
      agentProvider: "openai",
      agentModel: "configured-model",
      agentModelCatalog: { await counter.load() }
    )

    async let first = service.agentModels()
    async let second = service.agentModels()
    _ = await (first, second)
    _ = await service.agentModels()
    let calls = await counter.calls
    XCTAssertEqual(calls, 1)
  }

  func testAgentModelsReturnsOverloadWithoutStartingCatalogProcess() async throws {
    actor CatalogCounter {
      var calls = 0
      func load() -> AgentGatewayModelCatalogResult {
        calls += 1
        return AgentGatewayModelCatalogResult(protocolVersion: "1", vendor: "openai", models: [])
      }
    }
    let admission = AgentExecutionAdmission(
      maximumConcurrentExecutions: 1,
      maximumConcurrentExecutionsPerPrincipal: 1
    )
    let held = try XCTUnwrap(admission.acquire(principalId: "other"))
    defer { admission.release(held) }
    let base = try makeService()
    var scoped = base.service
    scoped.agentExecutionAdmission = admission
    let counter = CatalogCounter()
    let service = GraphQLNoteGraphQLService(
      service: scoped,
      agentProvider: "openai",
      agentModel: "configured-model",
      agentModelCatalog: { await counter.load() }
    )

    let result = await service.agentModels()
    XCTAssertFalse(result.result.accepted)
    XCTAssertEqual(result.result.status, "overloaded")
    let calls = await counter.calls
    XCTAssertEqual(calls, 0)
  }

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

  func testGraphQLRejectsServerManagedConversationMetadataAndForeignForgedConversation() async throws {
    let service = try makeService()
    let alice = try service.service.createUser(email: "alice@example.com", displayName: "Alice")
    let bob = try service.service.createUser(email: "bob@example.com", displayName: "Bob")
    let bobNote = try service.service.scoped(to: bob.userId).createNote(bodyMarkdown: "# Bob\nPrivate context")
    let forgedMetaJSON = """
    {"kaibaChat":{"subjectNoteId":"\(bobNote.noteId.rawValue)","subjectNotebookId":"\(bobNote.notebookId.rawValue)"}}
    """
    let aliceGraphQL = GraphQLNoteGraphQLService(service: service.service.scoped(to: alice.userId))

    let metadataRejected = await aliceGraphQL.createNotebook(GraphQLCreateNotebookInput(
      title: "Forged GraphQL conversation",
      kindTagName: NoteStoreSchema.agentConversationNotebookKindTag,
      metaJSON: forgedMetaJSON
    ))
    XCTAssertFalse(metadataRejected.result.accepted)
    XCTAssertEqual(metadataRejected.result.status, "invalid_request")

    // Simulate a pre-existing or non-GraphQL forged row: sending a turn must
    // still fail before it can queue unscoped reply generation.
    let forged = try service.service.scoped(to: alice.userId).createNotebook(
      title: "Forged legacy conversation",
      kindTagName: NoteStoreSchema.agentConversationNotebookKindTag,
      metaJSON: forgedMetaJSON
    )
    let rejected = await aliceGraphQL.sendAgentChatMessage(GraphQLSendAgentChatMessageInput(
      conversationNotebookId: forged.notebookId,
      userMarkdown: "Reveal Bob's context"
    ))
    XCTAssertFalse(rejected.result.accepted)
    XCTAssertEqual(rejected.result.status, "not_found")
    XCTAssertNil(rejected.turnNoteId)
    XCTAssertTrue(try service.service.listNotes(notebookId: forged.notebookId).isEmpty)
  }

  func testIdempotentReplayRejectsForgedConversationAndNoteMetadata() async throws {
    let fixture = try makeService()
    let service = fixture.service
    let graphQL = GraphQLNoteGraphQLService(service: service)
    let key = "forged-idempotency-key"

    let ordinaryNotebook = try service.createNotebook(title: "Ordinary notebook")
    let ordinaryNote = try service.createNote(
      notebookId: ordinaryNotebook.notebookId,
      bodyMarkdown: "# Ordinary\nNot a chat turn.",
      metaJSON: "{\"kaibaChat\":{\"idempotencyKey\":\"\(key)\"}}"
    )
    let ordinaryReplay = await graphQL.sendAgentChatMessage(GraphQLSendAgentChatMessageInput(
      conversationNotebookId: ordinaryNotebook.notebookId,
      userMarkdown: "Replay ordinary",
      idempotencyKey: key
    ))
    XCTAssertFalse(ordinaryReplay.result.accepted)
    XCTAssertNil(ordinaryReplay.turnNoteId)
    XCTAssertEqual(try service.getNote(ordinaryNote.noteId).noteId, ordinaryNote.noteId)

    let subject = try service.createNote(bodyMarkdown: "# Subject\nBody.")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let forgedTurn = try service.createNote(
      notebookId: conversation.notebookId,
      bodyMarkdown: "# Forged\nNot a generated chat body.",
      metaJSON: "{\"kaibaChat\":{\"idempotencyKey\":\"\(key)\"}}"
    )
    let publicForgedTurn = await graphQL.createNote(GraphQLCreateNoteInput(
      notebookId: conversation.notebookId,
      bodyMarkdown: "# Forged\nCaller-authored chat metadata.",
      metaJSON: "{\"kaibaChat\":{\"status\":\"pending\",\"userMarkdown\":\"Forged\",\"idempotencyKey\":\"\(key)\"}}"
    ))
    XCTAssertFalse(publicForgedTurn.result.accepted)
    XCTAssertEqual(publicForgedTurn.result.status, "invalid_request")
    XCTAssertNil(publicForgedTurn.note)
    let first = await graphQL.sendAgentChatMessage(GraphQLSendAgentChatMessageInput(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Create a genuine turn",
      idempotencyKey: key
    ))
    XCTAssertTrue(first.result.accepted)
    let genuineTurnId = try XCTUnwrap(first.turnNoteId)
    XCTAssertNotEqual(genuineTurnId, forgedTurn.noteId)
    let replay = await graphQL.sendAgentChatMessage(GraphQLSendAgentChatMessageInput(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Create a genuine turn",
      idempotencyKey: key
    ))
    XCTAssertTrue(replay.result.accepted)
    XCTAssertEqual(replay.turnNoteId, genuineTurnId)
    XCTAssertEqual(try service.listNotes(notebookId: conversation.notebookId).count, 2)

    let alice = try service.createUser(email: "replay-alice@example.com", displayName: "Alice")
    let bob = try service.createUser(email: "replay-bob@example.com", displayName: "Bob")
    let bobNote = try service.scoped(to: bob.userId).createNote(bodyMarkdown: "# Bob\nPrivate")
    let forgedConversation = try service.scoped(to: alice.userId).createNotebook(
      title: "Forged conversation",
      kindTagName: NoteStoreSchema.agentConversationNotebookKindTag,
      metaJSON: "{\"kaibaChat\":{\"subjectNoteId\":\"\(bobNote.noteId.rawValue)\",\"subjectNotebookId\":\"\(bobNote.notebookId.rawValue)\"}}"
    )
    _ = try service.scoped(to: alice.userId).createNote(
      notebookId: forgedConversation.notebookId,
      bodyMarkdown: "# Chat Turn 1\n\n## User\nForged\n\n## Agent\n_(no reply yet)_",
      metaJSON: "{\"kaibaChat\":{\"status\":\"pending\",\"userMarkdown\":\"Forged\",\"idempotencyKey\":\"\(key)\"}}"
    )
    let forgedReplay = await GraphQLNoteGraphQLService(
      service: service.scoped(to: alice.userId)
    ).sendAgentChatMessage(GraphQLSendAgentChatMessageInput(
      conversationNotebookId: forgedConversation.notebookId,
      userMarkdown: "Replay forged conversation",
      idempotencyKey: key
    ))
    XCTAssertFalse(forgedReplay.result.accepted)
    XCTAssertEqual(forgedReplay.result.status, "not_found")
    XCTAssertNil(forgedReplay.turnNoteId)
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

  func testForeignConversationHasIdenticalNotFoundResultWithOrWithoutSubject() async throws {
    let base = try makeService()
    let alice = try base.service.createUser(email: "alice@example.com", displayName: "Alice")
    let bob = try base.service.createUser(email: "bob@example.com", displayName: "Bob")
    let aliceService = GraphQLNoteGraphQLService(service: base.service.scoped(to: alice.userId))
    let bobService = GraphQLNoteGraphQLService(service: base.service.scoped(to: bob.userId))
    let aliceSubject = try aliceService.service.createNote(bodyMarkdown: "# Alice\nBody.")
    let bobSubject = try bobService.service.createNote(bodyMarkdown: "# Bob\nBody.")
    let created = await aliceService.sendAgentChatMessage(GraphQLSendAgentChatMessageInput(
      subjectNoteId: aliceSubject.noteId,
      userMarkdown: "Question"
    ))
    let foreignConversationId = try XCTUnwrap(created.conversationNotebookId)

    let withoutSubject = await bobService.sendAgentChatMessage(GraphQLSendAgentChatMessageInput(
      conversationNotebookId: foreignConversationId,
      userMarkdown: "Question"
    ))
    let withDifferentSubject = await bobService.sendAgentChatMessage(GraphQLSendAgentChatMessageInput(
      subjectNoteId: bobSubject.noteId,
      conversationNotebookId: foreignConversationId,
      userMarkdown: "Question"
    ))

    XCTAssertEqual(withoutSubject, withDifferentSubject)
    XCTAssertFalse(withoutSubject.result.accepted)
    XCTAssertEqual(withoutSubject.result.status, "not_found")
    XCTAssertEqual(withoutSubject.agentStatus, "error")
  }

  func testProtectedDerivedChatAndTagMemoStayHiddenFromUnauthenticatedDefaultUser() async throws {
    let base = try makeService()
    let protectedLibrary = try base.service.createLibrary(
      name: "protected-derived-chat",
      authRequired: true
    )
    let authenticatedService = base.service.scoped(to: NoteStoreSchema.defaultUserId)
    let protectedService = authenticatedService.scoped(toLibrary: protectedLibrary.libraryId)
    let protectedNote = try protectedService.createNote(
      bodyMarkdown: "# Protected\nDo not expose this content."
    )
    let tag = try authenticatedService.defineTag(name: "protected-derived-tag")
    _ = try protectedService.applyNotebookTags(
      notebookId: protectedNote.notebookId,
      tags: [tag.name],
      provenance: .human,
      assignedBy: "test"
    )
    let authenticatedGraphQL = GraphQLNoteGraphQLService(service: authenticatedService)

    let noteChat = await authenticatedGraphQL.sendAgentChatMessage(
      GraphQLSendAgentChatMessageInput(
        subjectNoteId: protectedNote.noteId,
        userMarkdown: "Summarize"
      )
    )
    XCTAssertTrue(noteChat.result.accepted)
    let noteConversationId = try XCTUnwrap(noteChat.conversationNotebookId)
    let noteTurnId = try XCTUnwrap(noteChat.turnNoteId)
    XCTAssertEqual(
      try authenticatedService.getNotebook(noteConversationId).libraryId,
      protectedLibrary.libraryId
    )
    let noteChatAppend = await authenticatedGraphQL.sendAgentChatMessage(
      GraphQLSendAgentChatMessageInput(
        conversationNotebookId: noteConversationId,
        userMarkdown: "Summarize again"
      )
    )
    XCTAssertTrue(noteChatAppend.result.accepted)
    let noteAppendTurnId = try XCTUnwrap(noteChatAppend.turnNoteId)
    XCTAssertEqual(
      try authenticatedService.getNote(noteAppendTurnId).notebookId,
      noteConversationId
    )

    let memoResult = await authenticatedGraphQL.ensureTagMemoNotebook(tagId: tag.tagId)
    XCTAssertTrue(memoResult.result.accepted)
    let memoNotebookId = try XCTUnwrap(memoResult.notebook?.notebookId)
    XCTAssertEqual(
      try authenticatedService.getNotebook(memoNotebookId).libraryId,
      protectedLibrary.libraryId
    )
    let memoChat = await authenticatedGraphQL.sendAgentChatMessage(
      GraphQLSendAgentChatMessageInput(
        subjectNotebookId: memoNotebookId,
        userMarkdown: "Summarize this tag"
      )
    )
    XCTAssertTrue(memoChat.result.accepted)
    let memoConversationId = try XCTUnwrap(memoChat.conversationNotebookId)
    let memoTurnId = try XCTUnwrap(memoChat.turnNoteId)
    XCTAssertEqual(
      try authenticatedService.getNotebook(memoConversationId).libraryId,
      protectedLibrary.libraryId
    )

    let openSubject = try authenticatedService.createNote(bodyMarkdown: "# Open\nMove me later.")
    let openChat = await authenticatedGraphQL.sendAgentChatMessage(
      GraphQLSendAgentChatMessageInput(
        subjectNoteId: openSubject.noteId,
        userMarkdown: "Summarize"
      )
    )
    XCTAssertTrue(openChat.result.accepted)
    let openConversationId = try XCTUnwrap(openChat.conversationNotebookId)
    try authenticatedService.moveNotebook(
      openSubject.notebookId,
      toLibrary: "protected-derived-chat"
    )
    let movedSubjectAppend = await authenticatedGraphQL.sendAgentChatMessage(
      GraphQLSendAgentChatMessageInput(
        conversationNotebookId: openConversationId,
        userMarkdown: "Summarize after move"
      )
    )
    XCTAssertFalse(movedSubjectAppend.result.accepted)
    XCTAssertEqual(movedSubjectAppend.result.status, "invalid_request")
    XCTAssertEqual(try authenticatedService.listNotes(notebookId: openConversationId).count, 1)

    let unauthenticatedGraphQL = GraphQLNoteGraphQLService(
      service: base.service.scoped(to: NoteStoreSchema.defaultUserId).unauthenticated()
    )
    for notebookId in [noteConversationId, memoNotebookId, memoConversationId] {
      let result = await unauthenticatedGraphQL.notebook(notebookId: notebookId)
      XCTAssertFalse(result.result.accepted)
      XCTAssertEqual(result.result.status, "not_found")
      XCTAssertNil(result.value)
    }
    for noteId in [noteTurnId, noteAppendTurnId, memoTurnId] {
      let result = await unauthenticatedGraphQL.note(noteId: noteId)
      XCTAssertFalse(result.result.accepted)
      XCTAssertEqual(result.result.status, "not_found")
      XCTAssertNil(result.value)
    }
    let listed = await unauthenticatedGraphQL.notebooks(limit: 100)
    XCTAssertTrue(listed.result.accepted)
    XCTAssertFalse(try XCTUnwrap(listed.value).contains { notebook in
      [noteConversationId, memoNotebookId, memoConversationId].contains(notebook.notebookId)
    })
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
        "subjectNoteId": .string(subject.noteId.rawValue),
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
    guard case let .string(rawNotebookId)? = payload["conversationNotebookId"] else {
      return XCTFail("expected conversationNotebookId")
    }
    let notebookId = NotebookID(rawNotebookId)
    guard case let .string(rawTurnNoteId)? = payload["turnNoteId"] else {
      return XCTFail("expected turnNoteId")
    }
    let turnNoteId = NoteID(rawTurnNoteId)
    let turn = try service.service.getNote(turnNoteId)
    XCTAssertEqual(NoteService.chatTurnState(of: turn)?.status, .unavailable)

    // GraphQL idempotent replay authorizes the conversation and returns its
    // committed turn before resolving a subject that may later be deleted.
    try service.service.deleteNote(noteId: subject.noteId)
    let replayResponse = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation Replay($input: SendAgentChatMessageInput!) {
        sendAgentChatMessage(input: $input) {
          result { accepted status }
          conversationNotebookId
          turnNoteId
          agentStatus
        }
      }
      """,
      variables: ["input": .object([
        "conversationNotebookId": .string(notebookId.rawValue),
        "userMarkdown": .string("What is this about?"),
        "idempotencyKey": .string("turn-1")
      ])],
      operationName: "Replay"
    ))
    XCTAssertTrue(replayResponse.handled)
    let replayPayload = try graphQLPayload(replayResponse.body, field: "sendAgentChatMessage")
    XCTAssertEqual(try resultObject(replayPayload)["accepted"], .bool(true))
    XCTAssertEqual(replayPayload["turnNoteId"], .string(turnNoteId.rawValue))
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
      variables: ["noteId": .string(subject.noteId.rawValue)],
      operationName: "Conversations"
    ))
    let payload = try graphQLPayload(response.body, field: "noteConversations")
    let values = try arrayValue(payload["value"], field: "noteConversations.value")
    XCTAssertEqual(values.count, 1)
    let conversation = try objectValue(values[0], field: "noteConversations.value[0]")
    XCTAssertEqual(conversation["subjectNoteId"], .string(subject.noteId.rawValue))
    XCTAssertEqual(conversation["turnCount"], .integer(1))

    let outOfRange = await executor.execute(GraphQLDocumentRequest(
      query: """
      query Conversations($noteId: String!) {
        noteConversations(noteId: $noteId, limit: 500) { result { accepted } }
      }
      """,
      variables: ["noteId": .string(subject.noteId.rawValue)],
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
      variables: ["noteId": .string(note.noteId.rawValue)],
      operationName: "Comments"
    ))
    let payload = try graphQLPayload(response.body, field: "noteComments")
    XCTAssertEqual(try resultObject(payload)["accepted"], .bool(true))
    let values = try arrayValue(payload["value"], field: "noteComments.value")
    XCTAssertEqual(values.count, 1)
    let comment = try objectValue(values[0], field: "noteComments.value[0]")
    XCTAssertEqual(comment["bodyMarkdown"], .string("First memo"))
    XCTAssertEqual(comment["author"], .string("tester"))

    let missing = await service.noteComments(noteId: NoteID("note-missing"))
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
        notebookId: NotebookID("notebook-missing"),
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
