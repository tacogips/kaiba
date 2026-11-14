import Foundation
import AppCore
import KaibaClient
import XCTest
@testable import AppServer

final class KaibaClientServerIntegrationTests: XCTestCase {
  func testTypedClientAndSchemaDiscoveryUseTheLiveHTTPBoundary() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/live-kaiba-client-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let inspectionService = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    for trigger in [
      NoteAutoActionTrigger.noteCreated,
      .noteUpdated,
      .notebookCreated
    ] {
      _ = try inspectionService.configureAutoAction(
        actionId: AutoActionID("live-sdk-\(trigger.rawValue)"),
        trigger: trigger,
        workflowId: WorkflowID("live-sdk-workflow")
      )
    }
    let runtime = KaibaServerRuntime(KaibaServeConfiguration(
      host: "127.0.0.1",
      noteRoot: root.path,
      allowUnauthenticated: true
    ))
    try await withRunningServer(runtime) { server in
      let client = try KaibaClient(
        endpoint: try XCTUnwrap(URL(string: server.endpoint)),
        authentication: .unauthenticated
      )
      let created = try await client.createNote(bodyMarkdown: "# Live SDK\nHTTP boundary")
      XCTAssertTrue(created.result.accepted)
      XCTAssertEqual(created.note?.bodyMarkdown, "# Live SDK\nHTTP boundary")
      let comment = try await client.addNoteComment(
        try XCTUnwrap(created.note?.noteId),
        bodyMarkdown: "Attributed comment",
        author: "riela-comment-author"
      )
      XCTAssertTrue(comment.result.accepted)
      XCTAssertEqual(comment.comment?.author, "riela-comment-author")

      let listed = try await client.listNotes(limit: 10)
      XCTAssertTrue(listed.result.accepted)
      XCTAssertEqual(listed.value?.map(\.noteId), [created.note?.noteId].compactMap { $0 })

      let tagged: KaibaValuePayload<[KaibaNote]>
      do {
        tagged = try await client.listNotes(tagFilter: ["missing-tag"], limit: 10)
      } catch let KaibaClientError.graphqlFailed(errors, _) {
        XCTFail("live listNotes filter failed: \(errors)")
        throw KaibaClientError.graphqlFailed(errors, partialData: nil)
      }
      XCTAssertTrue(tagged.result.accepted)
      XCTAssertEqual(tagged.value, [])
      let searched: KaibaValuePayload<[KaibaNoteSearchResult]>
      do {
        searched = try await client.searchNotes(
          query: "HTTP",
          tagFilter: ["missing-tag"],
          classFilter: ["topic"],
          includeLinked: true,
          depth: 2,
          limit: 10
        )
      } catch let KaibaClientError.graphqlFailed(errors, _) {
        XCTFail("live searchNotes filters failed: \(errors)")
        throw KaibaClientError.graphqlFailed(errors, partialData: nil)
      }
      XCTAssertTrue(searched.result.accepted)
      XCTAssertEqual(searched.value, [])

      let missing: KaibaValuePayload<KaibaNote>
      do {
        missing = try await client.getNote(KaibaNoteID(rawValue: "missing-note"))
      } catch let KaibaClientError.graphqlFailed(errors, _) {
        XCTFail("live not_found status failed: \(errors)")
        throw KaibaClientError.graphqlFailed(errors, partialData: nil)
      }
      XCTAssertFalse(missing.result.accepted)
      XCTAssertEqual(missing.result.status, .notFound)

      let invalid: KaibaOperationPayload
      do {
        invalid = try await client.ingestNotebookPages(
          idempotencyKey: "invalid-ingest",
          title: "Invalid ingest",
          pages: []
        )
      } catch let KaibaClientError.graphqlFailed(errors, _) {
        XCTFail("live invalid_request status failed: \(errors)")
        throw KaibaClientError.graphqlFailed(errors, partialData: nil)
      }
      XCTAssertFalse(invalid.result.accepted)
      XCTAssertEqual(invalid.result.status, .invalidRequest)

      let attachment: KaibaOperationPayload
      do {
        attachment = try await client.attachNoteFile(
          try XCTUnwrap(created.note?.noteId),
          bytes: Data("live file".utf8),
          mediaType: "text/plain",
          originalFilename: "live.txt"
        )
      } catch let KaibaClientError.graphqlFailed(errors, _) {
        XCTFail("live file attribute parity failed: \(errors)")
        throw KaibaClientError.graphqlFailed(errors, partialData: nil)
      }
      let file = try XCTUnwrap(attachment.file)
      XCTAssertEqual(Set(rielaFileRecordPayload(file).keys), [
        "fileId", "storageKind", "localPath", "s3Profile", "s3Bucket", "s3Key", "s3URL",
        "mediaType", "byteSize", "sha256", "originalFilename", "createdAt", "migratedAt"
      ])
      XCTAssertEqual(file.storageKind, "local")
      XCTAssertNotNil(file.localPath)
      XCTAssertNil(file.s3Profile)
      XCTAssertNil(file.s3Bucket)
      XCTAssertNil(file.s3Key)
      XCTAssertNil(file.s3URL)
      XCTAssertNil(file.migratedAt)

      let dispatchCount = try inspectionService.listAutoActionDispatchAttempts().count
      XCTAssertGreaterThan(dispatchCount, 0)
      let originatingActionId = KaibaAutoActionID(rawValue: "live-workflow-action")
      let causalNote = try await client.createNote(
        bodyMarkdown: "# Causal note",
        originatingActionId: originatingActionId
      )
      XCTAssertTrue(causalNote.result.accepted)
      let causalNoteId = try XCTUnwrap(causalNote.note?.noteId)
      let causalUpdate = try await client.updateNote(
        causalNoteId,
        bodyMarkdown: "# Causal note\nUpdated",
        originatingActionId: originatingActionId
      )
      XCTAssertTrue(causalUpdate.result.accepted)
      let causalNotebook = try await client.createNotebook(
        title: "Causal notebook",
        originatingActionId: originatingActionId
      )
      XCTAssertTrue(causalNotebook.result.accepted)
      let forgedPendingNotebook = try await client.createNotebook(
        title: "Forged pending notebook",
        metaJSON: #"{"_kaibaNotebookIngest":{"state":"pending","scopeKey":"forged"}}"#
      )
      XCTAssertFalse(forgedPendingNotebook.result.accepted)
      XCTAssertEqual(forgedPendingNotebook.result.status, .invalidRequest)
      XCTAssertNil(forgedPendingNotebook.notebook)
      XCTAssertFalse(try inspectionService.listNotebooks(limit: 100).contains {
        $0.title == "Forged pending notebook"
      })
      let causalPages = [
        KaibaIngestPage(
          bodyMarkdown: "# Causal page",
          readOnly: false,
          tags: [KaibaTagInput(name: "riela-page-tag")],
          metaJSON: #"{"source":"riela"}"#,
          noteNumber: 9,
          pageImage: KaibaInlineAttachment(
            bytes: Data("numbered page image".utf8),
            mediaType: "image/png",
            originalFilename: "page-9.png"
          )
        ),
        KaibaIngestPage(
          bodyMarkdown: "# Indexed page",
          pageImage: KaibaInlineAttachment(
            bytes: Data("indexed page image".utf8),
            mediaType: "image/png",
            originalFilename: "page-2.png"
          )
        )
      ]
      let causalIngest = try await client.ingestNotebookPages(
        idempotencyKey: "causal-ingest",
        title: "Causal ingest",
        pages: causalPages,
        originatingActionId: originatingActionId
      )
      XCTAssertTrue(causalIngest.result.accepted)
      let ingestedPage = try XCTUnwrap(causalIngest.notes?.first)
      XCTAssertFalse(ingestedPage.readOnly)
      XCTAssertEqual(ingestedPage.tags.map(\.tag.name), ["riela-page-tag"])
      XCTAssertEqual(ingestedPage.metaJSON, #"{"source":"riela"}"#)
      XCTAssertEqual(causalIngest.noteFiles?.map(\.position), [9, 2])
      let replayedCausalIngest = try await client.ingestNotebookPages(
        idempotencyKey: "causal-ingest",
        title: "Causal ingest",
        pages: causalPages,
        originatingActionId: originatingActionId
      )
      XCTAssertEqual(replayedCausalIngest, causalIngest)
      let visibleNotebooks = try inspectionService.listNotebooks(limit: 100)
      XCTAssertEqual(visibleNotebooks.filter { $0.title == "Causal ingest" }.count, 1)
      let causalConversation = try await client.saveConversation(
        title: "Causal conversation",
        transcript: [KaibaConversationTurn(
          userMarkdown: "Question",
          assistantMarkdown: "Answer",
          sourceNoteIds: [causalNoteId]
        )],
        originatingActionId: originatingActionId
      )
      XCTAssertTrue(causalConversation.result.accepted)
      XCTAssertEqual(try inspectionService.listAutoActionDispatchAttempts().count, dispatchCount)

      let schema = try await client.fetchSchema()
      XCTAssertTrue(schema.queryFields.contains { $0.name == "notes" })
      XCTAssertTrue(schema.mutationFields.contains { $0.name == "createNote" })
    }
  }

  func testLongTermMemoryHTTPAuthorizationAndAttributionMatrix() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/live-kaiba-memory-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    let admin = try service.createUser(
      email: "memory-admin@example.com",
      displayName: "Memory Admin",
      isAdmin: true
    )
    let member = try service.createUser(email: "memory-member@example.com", displayName: "Memory Member")
    let disabledAdmin = try service.createUser(
      email: "disabled-memory-admin@example.com",
      displayName: "Disabled Memory Admin",
      isAdmin: true
    )
    let adminToken = "memory-admin-token"
    let memberToken = "memory-member-token"
    let revokedToken = "memory-revoked-token"
    let disabledToken = "memory-disabled-token"
    let adminClientRecord = try service.registerAPIClient(
      displayName: "Memory admin client",
      bearerToken: adminToken,
      userId: admin.userId
    )
    _ = try service.registerAPIClient(
      displayName: "Memory member client",
      bearerToken: memberToken,
      userId: member.userId
    )
    let revokedClient = try service.registerAPIClient(
      displayName: "Revoked memory client",
      bearerToken: revokedToken,
      userId: admin.userId
    )
    _ = try service.registerAPIClient(
      displayName: "Disabled memory client",
      bearerToken: disabledToken,
      userId: disabledAdmin.userId
    )
    _ = try service.revokeAPIClient(clientId: revokedClient.clientId)
    _ = try service.setUserDisabled(userId: disabledAdmin.userId, disabled: true)

    let runtime = KaibaServerRuntime(KaibaServeConfiguration(
      host: "127.0.0.1",
      noteRoot: root.path
    ))
    try await withRunningServer(runtime) { server in
      let endpoint = try XCTUnwrap(URL(string: server.endpoint))

      let adminClient = try authenticatedClient(endpoint: endpoint, token: adminToken)
      let source = try await adminClient.createNote(
        bodyMarkdown: "# Source\nRelated context",
        tags: [KaibaTagInput(name: "source-topic")],
        assignedBy: "riela-note-create"
      )
      XCTAssertTrue(source.result.accepted)
      XCTAssertEqual(source.note?.createdBy, admin.userId.rawValue)
      XCTAssertEqual(
        source.note?.tags.first(where: { $0.tag.name == "source-topic" })?.assignedBy,
        "riela-note-create"
      )
      let sourceNoteId = try XCTUnwrap(source.note?.noteId)
      let comment = try await adminClient.addNoteComment(
        sourceNoteId,
        bodyMarkdown: "Authenticated attributed comment",
        author: "riela-comment-author"
      )
      XCTAssertTrue(comment.result.accepted)
      XCTAssertEqual(comment.comment?.author, "riela-comment-author")
      let tagged = try await adminClient.applyNoteTags(
        noteId: sourceNoteId,
        tags: [KaibaTagInput(name: "assigned-topic")],
        assignedBy: "riela-tag-assignment"
      )
      XCTAssertTrue(tagged.result.accepted)
      XCTAssertEqual(
        tagged.note?.tags.first(where: { $0.tag.name == "assigned-topic" })?.assignedBy,
        "riela-tag-assignment"
      )
      let conversation = try await adminClient.saveConversation(
        title: "Authenticated attributed conversation",
        transcript: [KaibaConversationTurn(
          userMarkdown: "Question",
          assistantMarkdown: "Answer",
          sourceNoteIds: [sourceNoteId]
        )],
        assignedBy: "riela-conversation"
      )
      XCTAssertTrue(conversation.result.accepted)
      XCTAssertEqual(conversation.notebook?.createdBy, admin.userId.rawValue)
      XCTAssertTrue(
        conversation.notebook?.tags.contains { $0.assignedBy == "riela-conversation" } == true
      )
      let related = try await adminClient.createNote(bodyMarkdown: "# Related\nAdditional context")
      let relatedNoteId = try XCTUnwrap(related.note?.noteId)
      let depthTwo = try await adminClient.createNote(bodyMarkdown: "# AssociationBoundaryZeta")
      let depthTwoNoteId = try XCTUnwrap(depthTwo.note?.noteId)
      _ = try service.linkNotes(
        from: NoteID(sourceNoteId.rawValue),
        to: NoteID(depthTwoNoteId.rawValue)
      )
      let append = try await adminClient.appendLongTermMemory(
        entries: [KaibaLongTermMemoryEntry(
          bodyMarkdown: "# Remote memory",
          topicTags: ["remote-topic"],
          sourceNoteIds: [sourceNoteId],
          relatedNoteIds: [relatedNoteId],
          periodStart: "2026-09-01T00:00:00.125Z",
          periodEnd: "2026-09-02T00:00:00Z",
          metaJSON: #"{"source":"http-matrix"}"#
        )],
        idempotencyKey: "remote-memory-attribution"
      )
      XCTAssertTrue(append.result.accepted)
      let note = try XCTUnwrap(append.notes.first)
      XCTAssertEqual(note.createdBy, admin.userId.rawValue)
      XCTAssertEqual(note.updatedBy, admin.userId.rawValue)
      XCTAssertEqual(
        note.tags.first { $0.tag.name == "remote-topic" }?.assignedBy,
        "client:\(adminClientRecord.clientId.rawValue)"
      )
      XCTAssertTrue(note.metaJSON?.contains("http-matrix") == true)
      XCTAssertTrue(note.metaJSON?.contains(sourceNoteId.rawValue) == true)
      let memoryMetadata = try XCTUnwrap(JSONValue(parsing: try XCTUnwrap(note.metaJSON)).asObject)
      XCTAssertEqual(memoryMetadata["periodStart"]?.asString, "2026-09-01T00:00:00.125Z")
      XCTAssertEqual(memoryMetadata["periodEnd"]?.asString, "2026-09-02T00:00:00.000Z")

      try await assertAssociationDepthBoundaries(
        client: adminClient,
        memoryNoteId: note.noteId,
        sourceNoteId: sourceNoteId,
        depthTwoNoteId: depthTwoNoteId
      )

      let memoryCount = try service.listLongTermMemoryNotes(limit: 50).count
      for (index, periods) in [
        ("not-a-timestamp", "2026-09-02T00:00:00Z"),
        ("2026-09-01T00:00:00Z", "still-not-a-timestamp")
      ].enumerated() {
        let malformed = try await adminClient.appendLongTermMemory(
          entries: [KaibaLongTermMemoryEntry(
            bodyMarkdown: "# Malformed memory \(index)",
            periodStart: periods.0,
            periodEnd: periods.1
          )],
          idempotencyKey: "malformed-memory-\(index)"
        )
        XCTAssertFalse(malformed.result.accepted)
        XCTAssertEqual(malformed.result.status, .invalidRequest)
        XCTAssertTrue(malformed.notes.isEmpty)
      }
      XCTAssertEqual(try service.listLongTermMemoryNotes(limit: 50).count, memoryCount)

      let malformedRecall = try await adminClient.recallLongTermMemory(
        query: "Remote memory",
        recencyWeight: -1
      )
      XCTAssertFalse(malformedRecall.result.accepted)
      XCTAssertEqual(malformedRecall.result.status, .invalidRequest)
      XCTAssertEqual(malformedRecall.value, [])

      let replay = try await adminClient.appendLongTermMemory(
        entries: [KaibaLongTermMemoryEntry(
          bodyMarkdown: "# Remote memory",
          topicTags: ["remote-topic"],
          sourceNoteIds: [sourceNoteId],
          relatedNoteIds: [relatedNoteId],
          periodStart: "2026-09-01T00:00:00.125Z",
          periodEnd: "2026-09-02T00:00:00Z",
          metaJSON: #"{"source":"http-matrix"}"#
        )],
        idempotencyKey: "remote-memory-attribution"
      )
      XCTAssertTrue(replay.idempotentReplay)
      XCTAssertEqual(replay.notes.map(\.noteId), [note.noteId])

      let conflict = try await adminClient.appendLongTermMemory(
        entries: [KaibaLongTermMemoryEntry(bodyMarkdown: "# Changed remote memory")],
        idempotencyKey: "remote-memory-attribution"
      )
      XCTAssertFalse(conflict.result.accepted)
      XCTAssertEqual(conflict.result.status, .invalidRequest)
      XCTAssertFalse(conflict.idempotentReplay)
      XCTAssertTrue(conflict.notes.isEmpty)

      let recall = try await adminClient.recallLongTermMemory(
        query: "Remote memory",
        limit: 10,
        includeAssociations: true
      )
      XCTAssertTrue(recall.result.accepted)
      XCTAssertTrue(recall.value?.contains { hit in
        hit.note.noteId == sourceNoteId && hit.isAssociation
          && hit.pathNoteIds.first == note.noteId && hit.pathNoteIds.last == sourceNoteId
      } == true)
      try await assertLongTermMemoryAuthorizationFailures(
        endpoint: endpoint,
        memberToken: memberToken,
        rejectedTokens: [revokedToken, disabledToken]
      )
    }
  }

  private func assertAssociationDepthBoundaries(
    client: KaibaClient,
    memoryNoteId: KaibaNoteID,
    sourceNoteId: KaibaNoteID,
    depthTwoNoteId: KaibaNoteID
  ) async throws {
    let negativeDepth = try await client.recallLongTermMemory(
      query: "Remote memory",
      limit: 10,
      includeAssociations: true,
      associationDepth: -1
    )
    XCTAssertFalse(negativeDepth.result.accepted)
    XCTAssertEqual(negativeDepth.result.status, .invalidRequest)
    let zeroDepth = try await client.recallLongTermMemory(
      query: "Remote memory",
      limit: 10,
      includeAssociations: true,
      associationDepth: 0
    )
    XCTAssertEqual(zeroDepth.value?.map(\.note.noteId), [memoryNoteId])
    let oneDepth = try await client.recallLongTermMemory(
      query: "Remote memory",
      limit: 10,
      includeAssociations: true,
      associationDepth: 1
    )
    XCTAssertTrue(oneDepth.value?.contains { $0.note.noteId == sourceNoteId && $0.hopCount == 1 } == true)
    XCTAssertFalse(oneDepth.value?.contains { $0.note.noteId == depthTwoNoteId } == true)
    let maximumDepth = try await client.recallLongTermMemory(
      query: "Remote memory",
      limit: 10,
      includeAssociations: true,
      associationDepth: NoteGraphPolicy.maximumDepth
    )
    let overMaximumDepth = try await client.recallLongTermMemory(
      query: "Remote memory",
      limit: 10,
      includeAssociations: true,
      associationDepth: NoteGraphPolicy.maximumDepth + 100
    )
    XCTAssertTrue(maximumDepth.value?.contains {
      $0.note.noteId == depthTwoNoteId && $0.hopCount == 2
    } == true)
    XCTAssertEqual(overMaximumDepth.value, maximumDepth.value)
  }

  private func assertLongTermMemoryAuthorizationFailures(
    endpoint: URL,
    memberToken: String,
    rejectedTokens: [String]
  ) async throws {
    let memberResult = try await authenticatedClient(endpoint: endpoint, token: memberToken)
      .longTermMemoryNotebook()
    XCTAssertFalse(memberResult.result.accepted)
    XCTAssertNil(memberResult.value)
    for token in rejectedTokens {
      await assertAuthFailure(endpoint: endpoint, token: token)
    }
    do {
      _ = try await KaibaClient(endpoint: endpoint, authentication: .unauthenticated)
        .longTermMemoryNotebook()
      XCTFail("missing bearer must fail")
    } catch let error as KaibaClientError {
      XCTAssertEqual(error.code, "auth_failed")
    }
  }

  private func withRunningServer(
    _ runtime: KaibaServerRuntime,
    operation: (KaibaServerStartInfo) async throws -> Void
  ) async throws {
    let server = try await runtime.startForTesting()
    do {
      try await operation(server)
      await runtime.stop()
    } catch {
      await runtime.stop()
      throw error
    }
  }

  private func authenticatedClient(endpoint: URL, token: String) throws -> KaibaClient {
    try KaibaClient(
      endpoint: endpoint,
      authentication: .bearer(try KaibaBearerToken(token))
    )
  }

  private func assertAuthFailure(endpoint: URL, token: String) async {
    do {
      _ = try await authenticatedClient(endpoint: endpoint, token: token).longTermMemoryNotebook()
      XCTFail("invalid bearer must fail")
    } catch let error as KaibaClientError {
      XCTAssertEqual(error.code, "auth_failed")
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  private func rielaFileRecordPayload(_ file: KaibaFile) -> [String: KaibaJSONValue] {
    [
      "fileId": .string(file.fileId.rawValue),
      "storageKind": .string(file.storageKind),
      "localPath": file.localPath.map(KaibaJSONValue.string) ?? .null,
      "s3Profile": file.s3Profile.map(KaibaJSONValue.string) ?? .null,
      "s3Bucket": file.s3Bucket.map(KaibaJSONValue.string) ?? .null,
      "s3Key": file.s3Key.map(KaibaJSONValue.string) ?? .null,
      "s3URL": file.s3URL.map(KaibaJSONValue.string) ?? .null,
      "mediaType": .string(file.mediaType),
      "byteSize": .integer(file.byteSize),
      "sha256": .string(file.sha256),
      "originalFilename": file.originalFilename.map(KaibaJSONValue.string) ?? .null,
      "createdAt": .string(file.createdAt),
      "migratedAt": file.migratedAt.map(KaibaJSONValue.string) ?? .null
    ]
  }
}
