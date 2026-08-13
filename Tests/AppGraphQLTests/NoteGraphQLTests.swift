import Foundation

import AppCore
import XCTest
@testable import AppGraphQL

// swiftlint:disable type_body_length
final class NoteGraphQLTests: XCTestCase {
  func testNoteGraphNeighborsDocumentAndSearchDepthUseSharedService() async throws {
    let service = try makeNoteGraphQLService()
    let seed = try service.service.createNote(bodyMarkdown: "# Seed\nprojectalpha")
    let first = try service.service.createNote(bodyMarkdown: "# B\nx")
    let second = try service.service.createNote(bodyMarkdown: "# C\ny")
    _ = try service.service.linkNotes(from: seed.noteId, to: first.noteId)
    _ = try service.service.linkNotes(from: first.noteId, to: second.noteId)
    let executor = NoteGraphQLDocumentExecutor(service: service)

    let response = await executor.execute(GraphQLDocumentRequest(query: """
      query {
        noteGraphNeighbors(noteIds: ["\(seed.noteId)"], depth: 2, limit: 5) {
          result { accepted }
          value { seedNoteId note { noteId } edgeKind weight hopCount pathNoteIds }
        }
      }
      """))
    let payload = try graphQLPayload(response.body, field: "noteGraphNeighbors")
    let values = try arrayValue(payload["value"], field: "noteGraphNeighbors.value")
    XCTAssertEqual(values.count, 2)
    let secondResult = try objectValue(values[1], field: "noteGraphNeighbors.value[1]")
    XCTAssertEqual(secondResult["hopCount"], .integer(2))
    XCTAssertEqual(secondResult["pathNoteIds"], .array([
      .string(seed.noteId),
      .string(first.noteId),
      .string(second.noteId)
    ]))

    let search = await service.searchNotes(
      query: "projectalpha",
      includeLinked: true,
      depth: 2
    )
    XCTAssertEqual(search.value?.map(\.note.noteId), [seed.noteId, first.noteId, second.noteId])
  }

  func testNoteGraphQLServiceCreatesSearchesTagsAndRejectsReadOnlyUpdate() async throws {
    let service = try makeNoteGraphQLService()
    let create = await service.createNote(GraphQLCreateNoteInput(
      title: "GraphQL Note",
      bodyMarkdown: "# GraphQL Note\n\nAlpha graphql body.",
      tags: [GraphQLNoteTagInput(name: "research", classId: "topic")]
    ))

    XCTAssertTrue(create.result.accepted)
    let noteId = try XCTUnwrap(create.note?.noteId)
    XCTAssertEqual(create.note?.title, "GraphQL Note")
    XCTAssertEqual(create.note?.bodyMarkdown, "# GraphQL Note\n\nAlpha graphql body.")

    let search = await service.searchNotes(query: "Alpha", tagFilter: ["research"])
    XCTAssertEqual(search.result.status, "ok")
    XCTAssertEqual(search.value?.map(\.note.noteId), [noteId])

    let tagged = await service.applyTags(
      noteId: noteId,
      tags: [GraphQLNoteTagInput(name: "reviewed")],
      provenance: "ai",
      assignedBy: "graphql-test"
    )
    XCTAssertEqual(tagged.note?.tags.map(\.tag.name).sorted(), ["research", "reviewed"])

    let readOnly = await service.setReadOnly(noteId: noteId, readOnly: true)
    XCTAssertEqual(readOnly.note?.readOnly, true)
    let rejected = await service.updateNote(noteId: noteId, bodyMarkdown: "# Changed")
    XCTAssertFalse(rejected.result.accepted)
    XCTAssertEqual(rejected.result.status, "rejected")
  }

  func testNoteGraphQLServiceSupportsAttachmentsConversationAndAutoActions() async throws {
    let service = try makeNoteGraphQLService()
    let cited = await service.createNote(GraphQLCreateNoteInput(bodyMarkdown: "# Cited\n\nSource"))
    let citedNoteId = try XCTUnwrap(cited.note?.noteId)

    let attachment = await service.attachFile(
      noteId: citedNoteId,
      contentBase64: Data("hello graphql".utf8).base64EncodedString(),
      mediaType: "text/plain",
      originalFilename: "hello.txt"
    )
    XCTAssertTrue(attachment.result.accepted)
    XCTAssertEqual(attachment.file?.mediaType, "text/plain")
    let fileId = try XCTUnwrap(attachment.file?.fileId)
    let roundTripFile = await service.noteFile(fileId: fileId)
    XCTAssertEqual(roundTripFile.value, attachment.file)
    XCTAssertEqual(try service.service.listFiles(noteId: citedNoteId).first?.file.fileId, fileId)

    let oversizedBase64Length = (((8 * 1024 * 1024) + 3) / 3) * 4 + 4
    let oversizedAttachment = await service.attachFile(
      noteId: citedNoteId,
      contentBase64: String(repeating: "A", count: oversizedBase64Length),
      mediaType: "application/octet-stream",
      originalFilename: "oversized.bin"
    )
    XCTAssertFalse(oversizedAttachment.result.accepted)
    XCTAssertTrue(
      oversizedAttachment.result.diagnostics.joined(separator: "\n").contains("decoded payload exceeds"),
      oversizedAttachment.result.diagnostics.joined(separator: "\n")
    )

    let saved = await service.saveConversation(
      title: "GraphQL Conversation",
      transcript: [
        NoteConversationTurn(
          userMarkdown: "What matters?",
          assistantMarkdown: "The cited source.",
          sourceNoteIds: [citedNoteId]
        )
      ],
      assignedBy: "graphql-test"
    )
    XCTAssertEqual(saved.notebook?.title, "GraphQL Conversation")
    XCTAssertEqual(saved.notes.count, 1)

    let configured = await service.configureAutoAction(
      actionId: "graphql-auto-tag",
      trigger: "note-created",
      workflowId: "note-auto-tagging",
      filterJSON: "{\"noteTags\":[\"research\"]}",
      enabled: true,
      position: 4
    )
    XCTAssertEqual(configured.autoAction?.actionId, "graphql-auto-tag")

    let actions = await service.autoActions()
    XCTAssertTrue(actions.value?.contains(where: { $0.actionId == "graphql-auto-tag" }) == true)

    let deleted = await service.deleteAutoAction(actionId: "graphql-auto-tag")
    XCTAssertTrue(deleted.accepted)
    let remainingActions = await service.autoActions()
    XCTAssertFalse(remainingActions.value?.contains(where: { $0.actionId == "graphql-auto-tag" }) == true)
  }

  func testNoteGraphQLServiceFiltersNotebooksByTag() async throws {
    let service = try makeNoteGraphQLService()
    let imported = await service.createNotebook(GraphQLCreateNotebookInput(
      title: "Imported Packet",
      kindTagName: "notebook-kind:imported-material"
    ))
    let memo = await service.createNotebook(GraphQLCreateNotebookInput(
      title: "Daily Memo",
      kindTagName: "notebook-kind:user-memo"
    ))

    let importedId = try XCTUnwrap(imported.notebook?.notebookId)
    let memoId = try XCTUnwrap(memo.notebook?.notebookId)

    let importedList = await service.notebooks(tagFilter: ["notebook-kind:imported-material"])
    XCTAssertEqual(importedList.value?.map(\.notebookId), [importedId])

    let memoList = await service.notebooks(tagFilter: ["notebook-kind:user-memo"])
    XCTAssertEqual(memoList.value?.map(\.notebookId), [memoId])

    let tagged = await service.applyNotebookTags(GraphQLApplyNotebookTagsInput(
      notebookId: memoId,
      tags: ["active-project"],
      provenance: "human",
      assignedBy: "graphql-test"
    ))
    XCTAssertEqual(tagged.notebook?.tags.map(\.tag.name).sorted(), ["active-project", "notebook-kind:user-memo"])

    let activeList = await service.notebooks(tagFilter: ["active-project"])
    XCTAssertEqual(activeList.value?.map(\.notebookId), [memoId])

    let untagged = await service.removeNotebookTag(
      notebookId: memoId,
      tagName: "active-project",
      provenance: "human"
    )
    XCTAssertEqual(untagged.notebook?.tags.map(\.tag.name), ["notebook-kind:user-memo"])
  }

  func testNoteGraphQLDocumentExecutorRunsCreateAndSearchDocuments() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let create = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation CreateNote($input: CreateNoteInput!) {
        createNote(input: $input) { result { accepted status } note { noteId title } }
      }
      """,
      variables: [
        "input": .object([
          "bodyMarkdown": .string("# Document Note\n\nExecutor body"),
          "tags": .array([.object(["name": .string("doc-test")])])
        ])
      ],
      operationName: "CreateNote"
    ))

    XCTAssertTrue(create.handled)
    XCTAssertEqual(create.status, 200)
    let created = try graphQLPayload(create.body, field: "createNote")
    XCTAssertEqual(try resultObject(created)["accepted"], .bool(true))
    let note = try objectValue(created["note"], field: "createNote.note")
    let noteId = try stringValue(note["noteId"], field: "note.noteId")

    let search = await executor.execute(GraphQLDocumentRequest(
      query: """
      query SearchNotes($query: String!, $tagFilter: [String!]) {
        searchNotes(query: $query, tagFilter: $tagFilter) {
          result { accepted }
          value { note { noteId } }
        }
      }
      """,
      variables: [
        "query": .string("Executor"),
        "tagFilter": .array([.string("doc-test")])
      ],
      operationName: "SearchNotes"
    ))

    XCTAssertTrue(search.handled)
    let result = try graphQLPayload(search.body, field: "searchNotes")
    XCTAssertEqual(try resultObject(result)["accepted"], .bool(true))
    let values = try arrayValue(result["value"], field: "searchNotes.value")
    guard !values.isEmpty else {
      return XCTFail("expected at least one search result")
    }
    let firstNote = try objectValue(try objectValue(values[0], field: "search result")["note"], field: "search result.note")
    XCTAssertEqual(firstNote["noteId"], .string(noteId))

    let notes = await executor.execute(GraphQLDocumentRequest(
      query: """
      query Notes($tagFilter: [String!]) {
        notes(tagFilter: $tagFilter) { value { noteId } result { accepted } }
      }
      """,
      variables: ["tagFilter": .array([.string("doc-test")])],
      operationName: "Notes"
    ))
    let noteList = try graphQLPayload(notes.body, field: "notes")
    XCTAssertEqual(try resultObject(noteList)["accepted"], .bool(true))
    XCTAssertEqual(
      try objectValue(try arrayValue(noteList["value"], field: "notes.value")[0], field: "notes.value[0]")["noteId"],
      .string(noteId)
    )

    let defineClass = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation DefineNoteTagClass($input: DefineNoteTagClassInput!) {
        defineNoteTagClass(input: $input) { result { accepted } tagClass { classId label } }
      }
      """,
      variables: ["input": .object([
        "classId": .string("document-test"),
        "label": .string("Document Test")
      ])],
      operationName: "DefineNoteTagClass"
    ))
    let classPayload = try graphQLPayload(defineClass.body, field: "defineNoteTagClass")
    XCTAssertEqual(try resultObject(classPayload)["accepted"], .bool(true))
    XCTAssertEqual(
      try objectValue(classPayload["tagClass"], field: "defineNoteTagClass.tagClass")["classId"],
      .string("document-test")
    )

    let createNotebook = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation CreateNotebook($input: CreateNotebookInput!) {
        createNotebook(input: $input) { result { accepted } notebook { notebookId title } }
      }
      """,
      variables: ["input": .object([
        "title": .string("Document Notebook"),
        "kindTagName": .string("notebook-kind:document-test")
      ])],
      operationName: "CreateNotebook"
    ))
    let notebookPayload = try graphQLPayload(createNotebook.body, field: "createNotebook")
    let notebook = try objectValue(notebookPayload["notebook"], field: "createNotebook.notebook")
    let notebookId = try stringValue(notebook["notebookId"], field: "notebook.notebookId")

    let filteredNotebooks = await executor.execute(GraphQLDocumentRequest(
      query: """
      query Notebooks($tagFilter: [String!]) {
        notebooks(tagFilter: $tagFilter) { result { accepted } value { notebookId title } }
      }
      """,
      variables: ["tagFilter": .array([.string("notebook-kind:document-test")])],
      operationName: "Notebooks"
    ))
    let notebookList = try graphQLPayload(filteredNotebooks.body, field: "notebooks")
    XCTAssertEqual(try resultObject(notebookList)["accepted"], .bool(true))
    XCTAssertEqual(
      try objectValue(
        try arrayValue(notebookList["value"], field: "notebooks.value")[0],
        field: "notebooks.value[0]"
      )["notebookId"],
      .string(notebookId)
    )

    try await assertDocumentNotebookTagsAndAutoActionDeletion(
      executor: executor,
      notebookId: notebookId
    )

    let deleteNotebook = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation DeleteNotebook($notebookId: String!) {
        deleteNotebook(notebookId: $notebookId) { accepted status }
      }
      """,
      variables: ["notebookId": .string(notebookId)],
      operationName: "DeleteNotebook"
    ))
    let deleteNotebookPayload = try graphQLPayload(deleteNotebook.body, field: "deleteNotebook")
    XCTAssertEqual(deleteNotebookPayload["accepted"], .bool(true))

    let s3Client = InMemoryNoteGraphQLS3HTTPClient()
    let migrationExecutor = NoteGraphQLDocumentExecutor(
      service: service,
      s3HTTPClient: s3Client,
      s3Profiles: [testGraphQLS3Profile()]
    )
    let attachment = try service.service.attachFile(
      noteId: noteId,
      data: Data("document attachment".utf8),
      mediaType: "text/plain"
    )
    let migrated = await migrationExecutor.execute(GraphQLDocumentRequest(
      query: """
      mutation MigrateFile($input: MigrateNoteFileStorageInput!) {
        migrateNoteFileStorage(input: $input) {
          result { accepted status }
          migrated { storageKind s3Key }
          failures { fileId message }
        }
      }
      """,
      variables: [
        "input": .object([
          "fileId": .string(attachment.file.fileId),
          "s3ProfileName": .string("graphql-s3")
        ])
      ],
      operationName: "MigrateFile"
    ))

    let migration = try graphQLPayload(migrated.body, field: "migrateNoteFileStorage")
    XCTAssertEqual(try resultObject(migration)["accepted"], .bool(true))
    let migratedFiles = try arrayValue(migration["migrated"], field: "migrateNoteFileStorage.migrated")
    guard !migratedFiles.isEmpty else {
      return XCTFail("expected migrated file")
    }
    let migratedFile = try objectValue(migratedFiles[0], field: "migrated file")
    XCTAssertEqual(migratedFile["storageKind"], .string("s3"))
    XCTAssertEqual(migratedFile["s3Key"], .string("graphql/\(attachment.file.fileId)"))
    XCTAssertEqual(s3Client.methods(), ["PUT"])

    let saved = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation SaveConversation($input: SaveNoteConversationInput!) {
        saveNoteConversation(input: $input) { result { accepted status } notebook { title } notes { noteId } }
      }
      """,
      variables: [
        "input": .object([
          "title": .string("Document Conversation"),
          "transcript": .array([
            .object([
              "userMarkdown": .string("What did the document say?"),
              "assistantMarkdown": .string("It cited the source."),
              "sourceNoteIds": .array([.string(noteId)])
            ])
          ])
        ])
      ],
      operationName: "SaveConversation"
    ))

    XCTAssertTrue(saved.handled)
    let conversation = try graphQLPayload(saved.body, field: "saveNoteConversation")
    XCTAssertEqual(try resultObject(conversation)["accepted"], .bool(true))
    XCTAssertEqual(
      try objectValue(conversation["notebook"], field: "saveNoteConversation.notebook")["title"],
      .string("Document Conversation")
    )
    XCTAssertEqual(try arrayValue(conversation["notes"], field: "saveNoteConversation.notes").count, 1)
  }

  func testNoteGraphQLDocumentExecutorRejectsOutOfRangeLimitAndOffset() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    _ = try service.service.createNote(bodyMarkdown: "# Bounds\n\nBody")

    // Out-of-range limit/offset are rejected with invalidVariable rather than
    // being silently clamped, so pagination contracts are honored (F22).
    let overLimit = await executor.execute(GraphQLDocumentRequest(
      query: "query Notes($limit: Int) { notes(limit: $limit) { value { noteId } result { accepted } } }",
      variables: ["limit": .integer(500)],
      operationName: "Notes"
    ))
    XCTAssertTrue(overLimit.handled)
    let overLimitError = try firstErrorMessage(overLimit)
    XCTAssertTrue(overLimitError.contains("invalidVariable"), overLimitError)

    let negativeOffset = await executor.execute(GraphQLDocumentRequest(
      query: "query Notes($offset: Int) { notes(offset: $offset) { value { noteId } result { accepted } } }",
      variables: ["offset": .integer(-10)],
      operationName: "Notes"
    ))
    XCTAssertTrue(negativeOffset.handled)
    let negativeOffsetError = try firstErrorMessage(negativeOffset)
    XCTAssertTrue(negativeOffsetError.contains("invalidVariable"), negativeOffsetError)

    // Graph fields can return at most NoteGraphPolicy.maximumLimit rows, so a
    // limit the general 0...200 rule would accept is rejected here instead of
    // being silently truncated by the bounded traversal.
    let note = try service.service.createNote(bodyMarkdown: "# Graph Bounds\n\nBody")
    let overGraphLimit = await executor.execute(GraphQLDocumentRequest(
      query: "query Graph($ids: [String!]!, $limit: Int) { noteGraphNeighbors(noteIds: $ids, limit: $limit) { value { note { noteId } } result { accepted } } }",
      variables: [
        "ids": .array([.string(note.noteId)]),
        "limit": .integer(Int64(NoteGraphPolicy.maximumLimit + 1))
      ],
      operationName: "Graph"
    ))
    XCTAssertTrue(overGraphLimit.handled)
    let overGraphLimitError = try firstErrorMessage(overGraphLimit)
    XCTAssertTrue(overGraphLimitError.contains("invalidVariable"), overGraphLimitError)

    let overProposalLimit = await executor.execute(GraphQLDocumentRequest(
      query: "query Proposals($noteId: String!, $limit: Int) { proposeNoteLinks(noteId: $noteId, limit: $limit) { value { targetNote { noteId } } result { accepted } } }",
      variables: [
        "noteId": .string(note.noteId),
        "limit": .integer(Int64(NoteGraphPolicy.maximumLimit + 1))
      ],
      operationName: "Proposals"
    ))
    XCTAssertTrue(overProposalLimit.handled)
    let overProposalLimitError = try firstErrorMessage(overProposalLimit)
    XCTAssertTrue(overProposalLimitError.contains("invalidVariable"), overProposalLimitError)
  }

  private func firstErrorMessage(_ response: GraphQLDocumentExecutionResponse) throws -> String {
    let errors = try arrayValue(response.body["errors"], field: "errors")
    let firstError = try objectValue(errors.first, field: "errors[0]")
    return try stringValue(firstError["message"], field: "errors[0].message")
  }

  func testNoteGraphQLDocumentExecutorRejectsMutationFieldInQueryOperation() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let note = try service.service.createNote(bodyMarkdown: "# Keep Me\n\nBody")

    let rejected = await executor.execute(GraphQLDocumentRequest(
      query: """
      query DeleteAsQuery($noteId: String!) {
        deleteNote(noteId: $noteId) { accepted status }
      }
      """,
      variables: ["noteId": .string(note.noteId)],
      operationName: "DeleteAsQuery"
    ))

    XCTAssertTrue(rejected.handled)
    let data = try objectValue(rejected.body["data"], field: "data")
    XCTAssertEqual(data["deleteNote"], .null)
    let errors = try arrayValue(rejected.body["errors"], field: "errors")
    let firstError = try objectValue(errors.first, field: "errors[0]")
    XCTAssertTrue(
      try stringValue(firstError["message"], field: "errors[0].message")
        .contains("operationFieldMismatch")
    )
    XCTAssertEqual(try service.service.getNote(note.noteId).noteId, note.noteId)
  }

  func testNoteGraphQLDocumentExecutorParsesCommentsAliasesAndInlineArguments() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let note = try service.service.createNote(
      bodyMarkdown: "# Parsed GraphQL\n\nBody",
      tags: [NoteTagInput(name: "parser")]
    )

    let listed = await executor.execute(GraphQLDocumentRequest(
      query: """
      # A leading comment with { must not become the root selection.
      query ParserList($limit: Int) {
        parsedNotes: notes(limit: $limit, tagFilter: ["parser"]) {
          value { noteId }
          result { accepted }
        }
      }
      """,
      variables: ["limit": .integer(5)],
      operationName: "ParserList"
    ))

    XCTAssertTrue(listed.handled)
    let data = try objectValue(listed.body["data"], field: "data")
    XCTAssertNil(data["notes"])
    let payload = try objectValue(data["parsedNotes"], field: "data.parsedNotes")
    XCTAssertEqual(try resultObject(payload)["accepted"], .bool(true))
    let values = try arrayValue(payload["value"], field: "parsedNotes.value")
    XCTAssertEqual(
      try objectValue(values.first, field: "parsedNotes.value[0]")["noteId"],
      .string(note.noteId)
    )

    let deleted = await executor.execute(GraphQLDocumentRequest(
      query: """
      # Another comment with { before the mutation.
      mutation {
        removed: deleteNote(noteId: "\(note.noteId)") { accepted status }
      }
      """
    ))

    XCTAssertTrue(deleted.handled)
    let deleteData = try objectValue(deleted.body["data"], field: "data")
    XCTAssertNil(deleteData["deleteNote"])
    let removed = try objectValue(deleteData["removed"], field: "data.removed")
    XCTAssertEqual(removed["accepted"], .bool(true))
    XCTAssertThrowsError(try service.service.getNote(note.noteId))
  }

  func testNoteGraphQLDocumentExecutorRejectsUnsupportedSelections() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    _ = try service.service.createNote(bodyMarkdown: "# Selection Guard\n\nBody")

    let invalidQuery = await executor.execute(GraphQLDocumentRequest(
      query: """
      query {
        notes { value { missingField } result { accepted } }
      }
      """
    ))

    XCTAssertTrue(invalidQuery.handled)
    let queryData = try objectValue(invalidQuery.body["data"], field: "data")
    XCTAssertEqual(queryData["notes"], .null)
    let queryErrors = try arrayValue(invalidQuery.body["errors"], field: "errors")
    let firstQueryError = try objectValue(queryErrors.first, field: "errors[0]")
    let queryErrorMessage = try stringValue(firstQueryError["message"], field: "errors[0].message")
    XCTAssertTrue(queryErrorMessage.contains("invalidSelection"))
    XCTAssertTrue(queryErrorMessage.contains("missingField"))

    let invalidMutation = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation CreateNote($input: CreateNoteInput!) {
        createNote(input: $input) { note { noteId missingField } result { accepted } }
      }
      """,
      variables: [
        "input": .object(["bodyMarkdown": .string("# Must Not Exist\n\nBody")])
      ],
      operationName: "CreateNote"
    ))

    XCTAssertTrue(invalidMutation.handled)
    let mutationData = try objectValue(invalidMutation.body["data"], field: "data")
    XCTAssertEqual(mutationData["createNote"], .null)
    let mutationErrors = try arrayValue(invalidMutation.body["errors"], field: "errors")
    let firstMutationError = try objectValue(mutationErrors.first, field: "mutation.errors[0]")
    let mutationErrorMessage = try stringValue(firstMutationError["message"], field: "mutation.errors[0].message")
    XCTAssertTrue(mutationErrorMessage.contains("invalidSelection"))
    XCTAssertTrue(mutationErrorMessage.contains("missingField"))
    XCTAssertFalse(try service.service.listNotes(limit: 10).contains { $0.title == "Must Not Exist" })
  }

  func testNoteGraphQLDocumentExecutorRejectsRawS3ProfileInputByDefault() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service, s3HTTPClient: InMemoryNoteGraphQLS3HTTPClient())
    let created = await service.createNote(GraphQLCreateNoteInput(bodyMarkdown: "# Raw S3\n\nBody"))
    let noteId = try XCTUnwrap(created.note?.noteId)
    let attachment = try service.service.attachFile(
      noteId: noteId,
      data: Data("raw migration".utf8),
      mediaType: "text/plain"
    )

    let migrated = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation MigrateFile($input: MigrateNoteFileStorageInput!) {
        migrateNoteFileStorage(input: $input) {
          result { accepted status }
          migrated { storageKind s3Key }
          failures { fileId message }
        }
      }
      """,
      variables: [
        "input": .object([
          "fileId": .string(attachment.file.fileId),
          "s3Endpoint": .string("https://attacker.example.test"),
          "s3Region": .string("ap-northeast-1"),
          "s3Bucket": .string("notes"),
          "s3AccessKeyIdEnv": .string("GITHUB_TOKEN"),
          "s3SecretAccessKeyEnv": .string("GITHUB_TOKEN")
        ])
      ],
      operationName: "MigrateFile",
      environment: ["GITHUB_TOKEN": "secret"]
    ))

    XCTAssertNil(migrated.body["errors"])
    let payload = try graphQLPayload(migrated.body, field: "migrateNoteFileStorage")
    let result = try resultObject(payload)
    XCTAssertEqual(result["accepted"], .bool(false))
    XCTAssertEqual(result["status"], .string("failed"))
    let failures = try arrayValue(payload["failures"], field: "migrateNoteFileStorage.failures")
    let firstFailure = try objectValue(failures.first, field: "migrateNoteFileStorage.failures[0]")
    XCTAssertEqual(firstFailure["fileId"], .string(attachment.file.fileId))
    XCTAssertTrue(
      try stringValue(firstFailure["message"], field: "failures[0].message")
        .contains("s3ProfileName is required")
    )
  }

  func testNoteGraphQLDocumentExecutorRejectsRawS3FieldsWithNamedProfileByDefault() async throws {
    let service = try makeNoteGraphQLService()
    let s3Client = InMemoryNoteGraphQLS3HTTPClient()
    let executor = NoteGraphQLDocumentExecutor(
      service: service,
      s3HTTPClient: s3Client,
      s3Profiles: [testGraphQLS3Profile()]
    )
    let created = await service.createNote(GraphQLCreateNoteInput(bodyMarkdown: "# Mixed S3\n\nBody"))
    let noteId = try XCTUnwrap(created.note?.noteId)
    let attachment = try service.service.attachFile(
      noteId: noteId,
      data: Data("mixed migration".utf8),
      mediaType: "text/plain"
    )

    let migrated = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation MigrateFile($input: MigrateNoteFileStorageInput!) {
        migrateNoteFileStorage(input: $input) { result { accepted status } failures { fileId message } }
      }
      """,
      variables: [
        "input": .object([
          "fileId": .string(attachment.file.fileId),
          "s3ProfileName": .string("graphql-s3"),
          "s3Endpoint": .string("https://attacker.example.test"),
          "s3AccessKeyIdEnv": .string("GITHUB_TOKEN")
        ])
      ],
      operationName: "MigrateFile",
      environment: ["GITHUB_TOKEN": "secret"]
    ))

    XCTAssertNil(migrated.body["errors"])
    let payload = try graphQLPayload(migrated.body, field: "migrateNoteFileStorage")
    XCTAssertEqual(try resultObject(payload)["accepted"], .bool(false))
    let failures = try arrayValue(payload["failures"], field: "migrateNoteFileStorage.failures")
    let firstFailure = try objectValue(failures.first, field: "migrateNoteFileStorage.failures[0]")
    XCTAssertEqual(firstFailure["fileId"], .string(attachment.file.fileId))
    XCTAssertTrue(
      try stringValue(firstFailure["message"], field: "failures[0].message")
        .contains("raw S3 fields are not allowed with s3ProfileName")
    )
    XCTAssertTrue(s3Client.methods().isEmpty)
  }

  func testNoteGraphQLDocumentExecutorReportsBulkMigrationPartialFailureInPayload() async throws {
    let service = try makeNoteGraphQLService()
    let first = try service.service.createNote(bodyMarkdown: "# First Bulk\n\nBody")
    let second = try service.service.createNote(bodyMarkdown: "# Second Bulk\n\nBody")
    let firstFile = try service.service.attachFile(
      noteId: first.noteId,
      data: Data("first bulk".utf8),
      mediaType: "text/plain"
    )
    let secondFile = try service.service.attachFile(
      noteId: second.noteId,
      data: Data("second bulk".utf8),
      mediaType: "text/plain"
    )
    let s3Client = InMemoryNoteGraphQLS3HTTPClient(
      failingPutPaths: ["/notes/graphql/\(secondFile.file.fileId)"]
    )
    let executor = NoteGraphQLDocumentExecutor(
      service: service,
      s3HTTPClient: s3Client,
      s3Profiles: [testGraphQLS3Profile()]
    )

    let migrated = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation MigrateAll($input: MigrateAllNoteFilesInput!) {
        migrateAllNoteFiles(input: $input) {
          result { accepted status diagnostics }
          migrated { fileId storageKind s3Key }
          failures { fileId message }
        }
      }
      """,
      variables: [
        "input": .object([
          "s3ProfileName": .string("graphql-s3")
        ])
      ],
      operationName: "MigrateAll"
    ))

    XCTAssertNil(migrated.body["errors"])
    let payload = try graphQLPayload(migrated.body, field: "migrateAllNoteFiles")
    let result = try resultObject(payload)
    XCTAssertEqual(result["accepted"], .bool(false))
    XCTAssertEqual(result["status"], .string("partial"))
    let diagnostics = try arrayValue(result["diagnostics"], field: "migrateAllNoteFiles.result.diagnostics")
    let diagnosticMessages = diagnostics.compactMap { value -> String? in
      guard case let .string(message) = value else {
        return nil
      }
      return message
    }
    XCTAssertTrue(diagnosticMessages.contains { $0.contains(secondFile.file.fileId) })
    let migratedFiles = try arrayValue(payload["migrated"], field: "migrateAllNoteFiles.migrated")
    XCTAssertEqual(
      try objectValue(migratedFiles.first, field: "migrateAllNoteFiles.migrated[0]")["fileId"],
      .string(firstFile.file.fileId)
    )
    let failures = try arrayValue(payload["failures"], field: "migrateAllNoteFiles.failures")
    let failure = try objectValue(failures.first, field: "migrateAllNoteFiles.failures[0]")
    XCTAssertEqual(failure["fileId"], .string(secondFile.file.fileId))
    XCTAssertEqual(try service.service.getFileRecord(fileId: firstFile.file.fileId).storageKind, .s3)
    XCTAssertEqual(try service.service.getFileRecord(fileId: secondFile.file.fileId).storageKind, .local)
  }

  func testSchemaContractExposesNoteDomain() {
    let schema = GraphQLContractProjector.schemaContract
    let normalizedSchema = schema.split(whereSeparator: \.isWhitespace).joined(separator: " ")

    XCTAssertTrue(schema.contains("type Note "))
    XCTAssertTrue(schema.contains("enum NoteListSort { createdAtDesc createdAtAsc updatedAtDesc title }"))
    XCTAssertTrue(normalizedSchema.contains(
      """
      notebooks( limit: Int, offset: Int, tagFilter: [String!], \
      tagFilterGroups: [[String!]!], tagFilterIdGroups: [[String!]!], \
      sort: NoteListSort, createdAfter: String, \
      createdBefore: String ): NotebooksQueryPayload!
      """
    ))
    XCTAssertTrue(schema.contains("notes(limit: Int, offset: Int, notebookId: String, tagFilter: [String!]): NotesQueryPayload!"))
    XCTAssertTrue(schema.contains("tags: NoteTagsQueryPayload!"))
    XCTAssertTrue(schema.contains("tagClasses: NoteTagClassesQueryPayload!"))
    XCTAssertTrue(schema.contains("autoActions: NoteAutoActionsQueryPayload!"))
    XCTAssertTrue(schema.contains("input CreateNoteInput {\n  notebookId: String\n  notebookTitle: String\n  title: String"))
    XCTAssertTrue(schema.contains("createNote(input: CreateNoteInput!)"))
    XCTAssertTrue(schema.contains("createNotebook(input: CreateNotebookInput!)"))
    XCTAssertTrue(schema.contains("defineNoteTagClass(input: DefineNoteTagClassInput!)"))
    XCTAssertTrue(schema.contains("deleteNotebook(notebookId: String!)"))
    XCTAssertTrue(schema.contains("input ApplyNotebookTagsInput"))
    XCTAssertTrue(schema.contains("applyNotebookTags(input: ApplyNotebookTagsInput!)"))
    XCTAssertTrue(schema.contains("removeNotebookTag(notebookId: String!, tagName: String!, provenance: String)"))
    XCTAssertTrue(schema.contains("searchNotes("))
    XCTAssertTrue(schema.contains("includeLinked: Boolean, depth: Int"))
    XCTAssertTrue(schema.contains("noteGraphNeighbors(noteIds: [String!]!, depth: Int, limit: Int)"))
    XCTAssertTrue(schema.contains("proposeNoteLinks(noteId: String!, limit: Int)"))
    XCTAssertTrue(schema.contains("configureNoteAutoAction(input: ConfigureNoteAutoActionInput!)"))
    XCTAssertTrue(schema.contains("deleteNoteAutoAction(actionId: String!)"))
    XCTAssertTrue(schema.contains("saveNoteConversation(input: SaveNoteConversationInput!)"))
    XCTAssertTrue(schema.contains("noteConversations(noteId: String!, limit: Int): AgentConversationsQueryPayload!"))
    XCTAssertTrue(schema.contains("noteComments(noteId: String!): NoteCommentsQueryPayload!"))
    XCTAssertTrue(schema.contains("noteFiles(noteId: String!): NoteFilesQueryPayload!"))
    XCTAssertTrue(schema.contains("type NoteFilesQueryPayload { result: ControlPlaneResult!, value: [NoteFileAttachment!] }"))
    XCTAssertTrue(schema.contains("sendAgentChatMessage(input: SendAgentChatMessageInput!): AgentChatMessagePayload!"))
    XCTAssertTrue(schema.contains("requestTagExtraction(input: RequestTagExtractionInput!): TagExtractionRequestPayload!"))
    XCTAssertTrue(schema.contains("requestNotebookTranslation(input: RequestNotebookTranslationInput!): NotebookTranslationRequestPayload!"))
    XCTAssertTrue(schema.contains("input MigrateNoteFileStorageInput {\n  fileId: String!\n  s3ProfileName: String!\n}"))
    XCTAssertFalse(schema.contains("s3Endpoint:"))
    XCTAssertFalse(schema.contains("s3AccessKeyIdEnv"))
    XCTAssertFalse(schema.contains("Kanban"))
    XCTAssertFalse(schema.contains("setNotebookProgress"))
  }

  func testPublishedNoteSchemaRootFieldsAreRoutableByExecutor() {
    let queryFields: Set<String> = [
      "note",
      "notebook",
      "notebooks",
      "notes",
      "searchNotes",
      "noteGraphNeighbors",
      "proposeNoteLinks",
      "tags",
      "tagClasses",
      "noteFile",
      "noteFiles",
      "autoActions",
      "noteConversations",
      "notebookConversations",
      "noteComments",
      "notebookComments",
      "tagDetail",
      "tagComments",
      "agentModels",
      "agenticSearch",
      "appSetting"
    ]
    let mutationFields: Set<String> = [
      "createNote",
      "createNotebook",
      "defineNoteTagClass",
      "defineNoteTag",
      "updateNote",
      "deleteNote",
      "deleteNotebook",
      "applyNotebookTags",
      "applyNotebookTagIds",
      "removeNotebookTag",
      "removeNotebookTagById",
      "setNotebookReadOnly",
      "setNoteReadOnly",
      "applyNoteTags",
      "removeNoteTag",
      "addNoteComment",
      "addNotebookComment",
      "setAppSetting",
      "linkNotes",
      "attachNoteFile",
      "configureNoteAutoAction",
      "deleteNoteAutoAction",
      "saveNoteConversation",
      "sendAgentChatMessage",
      "ensureTagMemoNotebook",
      "requestTagExtraction",
      "requestNotebookTranslation",
      "migrateNoteFileStorage",
      "migrateAllNoteFiles",
      "reclaimNoteFileStorage"
    ]

    XCTAssertEqual(supportedNoteGraphQLFields, queryFields.union(mutationFields))
    for field in queryFields {
      XCTAssertEqual(noteGraphQLRootFieldName(in: "query Test { \(field) { result { accepted } } }"), field)
    }
    for field in mutationFields {
      XCTAssertEqual(noteGraphQLRootFieldName(in: "mutation Test { \(field) { result { accepted } } }"), field)
    }
    XCTAssertFalse(GraphQLContractProjector.schemaContract.contains("noteTags:"))
    XCTAssertFalse(GraphQLContractProjector.schemaContract.contains("noteTagClasses:"))
    XCTAssertFalse(GraphQLContractProjector.schemaContract.contains("noteAutoActions:"))
  }

  private func makeNoteGraphQLService(function: String = #function) throws -> GraphQLNoteGraphQLService {
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
      XCTFail("expected \(field) object")
      return [:]
    }
    return object
  }

  private func arrayValue(_ value: JSONValue?, field: String) throws -> [JSONValue] {
    guard case let .array(array)? = value else {
      XCTFail("expected \(field) array")
      return []
    }
    return array
  }

  private func stringValue(_ value: JSONValue?, field: String) throws -> String {
    guard case let .string(string)? = value else {
      XCTFail("expected \(field) string")
      return ""
    }
    return string
  }

  private func tagNames(in assignments: [JSONValue], field: String) throws -> [String] {
    try assignments.enumerated().map { index, value in
      let assignment = try objectValue(value, field: "\(field)[\(index)]")
      let tag = try objectValue(assignment["tag"], field: "\(field)[\(index)].tag")
      return try stringValue(tag["name"], field: "\(field)[\(index)].tag.name")
    }
  }

  private func assertDocumentNotebookTagsAndAutoActionDeletion(
    executor: NoteGraphQLDocumentExecutor,
    notebookId: String
  ) async throws {
    let taggedNotebook = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation ApplyNotebookTags($input: ApplyNotebookTagsInput!) {
        applyNotebookTags(input: $input) {
          result { accepted status }
          notebook { notebookId tags { tag { name } } }
        }
      }
      """,
      variables: ["input": .object([
        "notebookId": .string(notebookId),
        "tags": .array([.string("document-active")]),
        "provenance": .string("human")
      ])],
      operationName: "ApplyNotebookTags"
    ))
    let taggedNotebookPayload = try graphQLPayload(taggedNotebook.body, field: "applyNotebookTags")
    XCTAssertEqual(try resultObject(taggedNotebookPayload)["accepted"], .bool(true))
    let taggedNotebookTags = try arrayValue(
      try objectValue(taggedNotebookPayload["notebook"], field: "applyNotebookTags.notebook")["tags"],
      field: "applyNotebookTags.notebook.tags"
    )
    XCTAssertTrue(try tagNames(in: taggedNotebookTags, field: "applyNotebookTags.notebook.tags")
      .contains("document-active"))

    let untaggedNotebook = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation RemoveNotebookTag($notebookId: String!, $tagName: String!) {
        removeNotebookTag(notebookId: $notebookId, tagName: $tagName) {
          result { accepted status }
          notebook { notebookId tags { tag { name } } }
        }
      }
      """,
      variables: [
        "notebookId": .string(notebookId),
        "tagName": .string("document-active")
      ],
      operationName: "RemoveNotebookTag"
    ))
    let untaggedNotebookPayload = try graphQLPayload(untaggedNotebook.body, field: "removeNotebookTag")
    XCTAssertEqual(try resultObject(untaggedNotebookPayload)["accepted"], .bool(true))
    let untaggedNotebookTags = try arrayValue(
      try objectValue(untaggedNotebookPayload["notebook"], field: "removeNotebookTag.notebook")["tags"],
      field: "removeNotebookTag.notebook.tags"
    )
    XCTAssertFalse(try tagNames(in: untaggedNotebookTags, field: "removeNotebookTag.notebook.tags")
      .contains("document-active"))

    let configuredAction = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation ConfigureAutoAction($input: ConfigureNoteAutoActionInput!) {
        configureNoteAutoAction(input: $input) { result { accepted status } autoAction { actionId } }
      }
      """,
      variables: ["input": .object([
        "actionId": .string("document-auto-action"),
        "trigger": .string("note-created"),
        "workflowId": .string("document-workflow")
      ])],
      operationName: "ConfigureAutoAction"
    ))
    let actionPayload = try graphQLPayload(configuredAction.body, field: "configureNoteAutoAction")
    XCTAssertEqual(try resultObject(actionPayload)["accepted"], .bool(true))

    let deletedAction = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation DeleteAutoAction($actionId: String!) {
        deleteNoteAutoAction(actionId: $actionId) { accepted status }
      }
      """,
      variables: ["actionId": .string("document-auto-action")],
      operationName: "DeleteAutoAction"
    ))
    let deleteActionPayload = try graphQLPayload(deletedAction.body, field: "deleteNoteAutoAction")
    XCTAssertEqual(deleteActionPayload["accepted"], .bool(true))
  }
}

// swiftlint:enable type_body_length

private func testGraphQLS3Profile() -> S3StorageProfile {
  S3StorageProfile(
    name: "graphql-s3",
    endpoint: URL(string: "https://graphql-s3.test")!,
    region: "ap-northeast-1",
    bucket: "notes",
    accessKeyId: "access-key",
    secretAccessKey: "secret-key",
    keyPrefix: "graphql"
  )
}

private final class InMemoryNoteGraphQLS3HTTPClient: S3HTTPClient, @unchecked Sendable {
  private let lock = NSLock()
  private var objects: [String: Data] = [:]
  private var recordedMethods: [String] = []
  private let failingPutPaths: Set<String>

  init(failingPutPaths: Set<String> = []) {
    self.failingPutPaths = failingPutPaths
  }

  func send(_ request: S3HTTPRequest) throws -> S3HTTPResponse {
    lock.lock()
    defer { lock.unlock() }
    recordedMethods.append(request.method)
    switch request.method {
    case "PUT":
      if failingPutPaths.contains(request.url.path) {
        return S3HTTPResponse(statusCode: 503, body: Data("unavailable".utf8))
      }
      objects[request.url.path] = request.body
      return S3HTTPResponse(statusCode: 200)
    case "GET":
      guard let data = objects[request.url.path] else {
        return S3HTTPResponse(statusCode: 404)
      }
      return S3HTTPResponse(statusCode: 200, body: data)
    default:
      return S3HTTPResponse(statusCode: 405)
    }
  }

  func methods() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return recordedMethods
  }
}
