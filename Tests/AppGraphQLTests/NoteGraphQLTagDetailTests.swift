import Foundation
@testable import AppCore
@testable import AppGraphQL
import XCTest

final class NoteGraphQLTagDetailTests: XCTestCase {
  func testTagDetailAndTagCommentsDocumentsRoundTrip() async throws {
    let service = try makeNoteGraphQLService()
    let tag = try service.service.defineTag(name: "oda-nobunaga", classId: TagClassID("person"))
    let note = try service.service.createNote(bodyMarkdown: "# Battle\noda-nobunaga fought here")
    _ = try service.service.applyTags(
      noteId: note.noteId,
      tags: [NoteTagInput(name: "oda-nobunaga")],
      provenance: .human,
      assignedBy: "test"
    )
    _ = try service.service.addComment(
      noteId: note.noteId,
      bodyMarkdown: "a memo about the warlord",
      author: "user"
    )
    let executor = NoteGraphQLDocumentExecutor(service: service)

    let detailResponse = await executor.execute(GraphQLDocumentRequest(
      query: """
      query TagDetail($tagId: String!) {
        tagDetail(tagId: $tagId) {
          result { accepted status }
          value {
            tag { tagId name classId }
            tagClass { classId label }
            noteCount
            notebookCount
            memoNotebookId
          }
        }
      }
      """,
      variables: ["tagId": .string(tag.tagId.rawValue)],
      operationName: "TagDetail"
    ))
    let detail = try XCTUnwrap(detailResponse)
    let detailPayload = try graphQLPayload(detail.body, field: "tagDetail")
    XCTAssertEqual(try resultObject(detailPayload)["accepted"], .bool(true))
    let detailValue = try objectValue(detailPayload["value"], field: "tagDetail.value")
    XCTAssertEqual(try objectValue(detailValue["tag"], field: "tag")["name"], .string("oda-nobunaga"))
    XCTAssertEqual(try objectValue(detailValue["tagClass"], field: "tagClass")["classId"], .string("person"))
    XCTAssertEqual(detailValue["noteCount"], .number(1))
    XCTAssertEqual(detailValue["memoNotebookId"], .null)

    let commentsResponse = await executor.execute(GraphQLDocumentRequest(
      query: """
      query TagComments($tagId: String!) {
        tagComments(tagId: $tagId, limit: 10, offset: 0) {
          result { accepted status }
          value {
            comment { commentId bodyMarkdown author }
            noteTitle
            notebookTitle
          }
        }
      }
      """,
      variables: ["tagId": .string(tag.tagId.rawValue)],
      operationName: "TagComments"
    ))
    let comments = try XCTUnwrap(commentsResponse)
    let commentsPayload = try graphQLPayload(comments.body, field: "tagComments")
    XCTAssertEqual(try resultObject(commentsPayload)["accepted"], .bool(true))
    guard case let .array(rows) = try XCTUnwrap(commentsPayload["value"]) else {
      return XCTFail("expected tagComments.value array")
    }
    XCTAssertEqual(rows.count, 1)
    let row = try objectValue(rows.first, field: "tagComments.value[0]")
    XCTAssertEqual(
      try objectValue(row["comment"], field: "comment")["bodyMarkdown"],
      .string("a memo about the warlord")
    )
    XCTAssertEqual(row["noteTitle"], .string("Battle"))
  }

  func testEnsureTagMemoNotebookMutationDocument() async throws {
    let service = try makeNoteGraphQLService()
    let tag = try service.service.defineTag(name: "himiko")
    let executor = NoteGraphQLDocumentExecutor(service: service)

    let query = """
      mutation EnsureTagMemoNotebook($tagId: String!) {
        ensureTagMemoNotebook(tagId: $tagId) {
          result { accepted status }
          notebook { notebookId title metaJSON }
        }
      }
      """
    let ensuredResponse = await executor.execute(GraphQLDocumentRequest(
      query: query,
      variables: ["tagId": .string(tag.tagId.rawValue)],
      operationName: "EnsureTagMemoNotebook"
    ))
    let ensured = try XCTUnwrap(ensuredResponse)
    let payload = try graphQLPayload(ensured.body, field: "ensureTagMemoNotebook")
    XCTAssertEqual(try resultObject(payload)["accepted"], .bool(true))
    let notebook = try objectValue(payload["notebook"], field: "notebook")
    XCTAssertEqual(notebook["title"], .string("Tag: himiko"))

    let againResponse = await executor.execute(GraphQLDocumentRequest(
      query: query,
      variables: ["tagId": .string(tag.tagId.rawValue)],
      operationName: "EnsureTagMemoNotebook"
    ))
    let again = try XCTUnwrap(againResponse)
    let repeated = try objectValue(
      try graphQLPayload(again.body, field: "ensureTagMemoNotebook")["notebook"],
      field: "notebook"
    )
    XCTAssertEqual(repeated["notebookId"], notebook["notebookId"])
  }

  func testScopedTagCommentsHideInternalLongTermMemoryComments() async throws {
    let service = try makeNoteGraphQLService()
    let topic = try service.service.defineTag(name: "graphql-internal-memory-comments")
    let memory = try XCTUnwrap(try service.service.appendLongTermMemoryNotes(
      [LongTermMemoryEntryInput(
        bodyMarkdown: "Internal GraphQL memory comment source",
        topicTags: [topic.name]
      )],
      idempotencyKey: "graphql-internal-memory-comment-refusal"
    ).notes.first)
    _ = try service.service.addComment(
      noteId: memory.noteId,
      bodyMarkdown: "Internal GraphQL memory note comment"
    )
    _ = try service.service.addNotebookComment(
      notebookId: memory.notebookId,
      bodyMarkdown: "Internal GraphQL memory notebook comment"
    )

    for scopedService in [
      service.service.scoped(to: NoteStoreSchema.defaultUserId),
      service.service.scoped(to: NoteStoreSchema.defaultUserId).unauthenticated(),
      service.service.unauthenticated()
    ] {
      let scoped = GraphQLNoteGraphQLService(service: scopedService)
      let noteComments = await scoped.tagComments(tagId: topic.tagId)
      XCTAssertTrue(noteComments.result.accepted)
      XCTAssertEqual(noteComments.value, [])

      let notebookComments = await scoped.tagComments(
        tagId: NoteStoreSchema.longTermMemoryNotebookKindTagId
      )
      XCTAssertTrue(notebookComments.result.accepted)
      XCTAssertEqual(notebookComments.value, [])

      let topicDetail = await scoped.tagDetail(tagId: topic.tagId)
      XCTAssertTrue(topicDetail.result.accepted)
      XCTAssertEqual(topicDetail.value?.noteCount, 0)

      let memoryDetail = await scoped.tagDetail(
        tagId: NoteStoreSchema.longTermMemoryNotebookKindTagId
      )
      XCTAssertTrue(memoryDetail.result.accepted)
      XCTAssertEqual(memoryDetail.value?.notebookCount, 0)
    }
  }

  func testTagCommentsAndCountsRequireCurrentLibraryReach() async throws {
    let service = try makeNoteGraphQLService()
    let defaultService = service.service.scoped(to: NoteStoreSchema.defaultUserId)
    let tag = try service.service.defineTag(name: "graphql-protected-tag-comment-reach")
    let protectedLibrary = try defaultService.createLibrary(
      name: "graphql-protected-tag-comment-reach",
      authRequired: true
    )
    let protectedService = defaultService.scoped(toLibrary: protectedLibrary.libraryId)
    let note = try protectedService.createNote(
      notebookTitle: "Protected GraphQL comments",
      bodyMarkdown: "# Protected\nGraphQL must not expose this comment."
    )
    _ = try protectedService.applyTags(
      noteId: note.noteId,
      tags: [NoteTagInput(name: tag.name)],
      provenance: .human,
      assignedBy: "test"
    )
    _ = try protectedService.applyNotebookTags(
      notebookId: note.notebookId,
      tags: [tag.name],
      provenance: .human,
      assignedBy: "test"
    )
    _ = try protectedService.addComment(noteId: note.noteId, bodyMarkdown: "protected GraphQL note comment")
    _ = try protectedService.addNotebookComment(
      notebookId: note.notebookId,
      bodyMarkdown: "protected GraphQL notebook comment"
    )

    let unauthenticated = GraphQLNoteGraphQLService(service: defaultService.unauthenticated())
    let unauthenticatedComments = await unauthenticated.tagComments(tagId: tag.tagId)
    XCTAssertTrue(unauthenticatedComments.result.accepted)
    XCTAssertEqual(unauthenticatedComments.value, [])
    let unauthenticatedDetail = await unauthenticated.tagDetail(tagId: tag.tagId)
    XCTAssertEqual(unauthenticatedDetail.value?.noteCount, 0)
    XCTAssertEqual(unauthenticatedDetail.value?.notebookCount, 0)

    let alice = try service.service.createUser(
      email: "graphql-tag-comment-revoked@example.com",
      displayName: "Alice"
    )
    let aliceService = service.service.scoped(to: alice.userId)
    let aliceLibrary = try aliceService.createLibrary(
      name: "graphql-revoked-tag-comment-reach",
      authRequired: true
    )
    let aliceTag = try service.service.defineTag(name: "graphql-revoked-tag-comment-reach")
    let aliceNote = try aliceService.scoped(toLibrary: aliceLibrary.libraryId).createNote(
      notebookTitle: "Alice protected GraphQL comments",
      bodyMarkdown: "# Alice protected\nThis membership is revoked."
    )
    _ = try aliceService.scoped(toLibrary: aliceLibrary.libraryId).applyTags(
      noteId: aliceNote.noteId,
      tags: [NoteTagInput(name: aliceTag.name)],
      provenance: .human,
      assignedBy: "test"
    )
    _ = try aliceService.scoped(toLibrary: aliceLibrary.libraryId).addComment(
      noteId: aliceNote.noteId,
      bodyMarkdown: "revoked GraphQL comment"
    )
    try service.service.revokeLibraryAccess(libraryName: aliceLibrary.name, userId: alice.userId)

    let revoked = GraphQLNoteGraphQLService(service: aliceService)
    let revokedComments = await revoked.tagComments(tagId: aliceTag.tagId)
    XCTAssertTrue(revokedComments.result.accepted)
    XCTAssertEqual(revokedComments.value, [])
    let revokedDetail = await revoked.tagDetail(tagId: aliceTag.tagId)
    XCTAssertEqual(revokedDetail.value?.noteCount, 0)
  }

  func testEnsureTagMemoPreservesProtectedLibraryAfterFinalSourceTagRemoval() async throws {
    let root = try makeNoteGraphQLService()
    let defaultService = root.service.scoped(to: NoteStoreSchema.defaultUserId)
    let protectedLibrary = try defaultService.createLibrary(
      name: "graphql-removed-tag-memo-source",
      authRequired: true
    )
    let protectedService = defaultService.scoped(toLibrary: protectedLibrary.libraryId)
    let tag = try root.service.defineTag(name: "graphql-removed-tag-memo-source")
    let source = try protectedService.createNote(
      notebookTitle: "Protected GraphQL tagged source",
      bodyMarkdown: "# Protected\nThe final source tag will be removed."
    )
    _ = try protectedService.applyTags(
      noteId: source.noteId,
      tags: [NoteTagInput(name: tag.name)],
      provenance: .human,
      assignedBy: "test"
    )
    let protectedGraphQL = GraphQLNoteGraphQLService(service: protectedService)
    let originalResult = await protectedGraphQL.ensureTagMemoNotebook(tagId: tag.tagId)
    let original = try XCTUnwrap(originalResult.notebook)

    _ = try protectedService.removeTag(
      noteId: source.noteId,
      tagName: tag.name,
      removedBy: .human
    )
    let ordinaryGraphQL = GraphQLNoteGraphQLService(service: defaultService)
    let retainedResult = await ordinaryGraphQL.ensureTagMemoNotebook(tagId: tag.tagId)
    XCTAssertTrue(retainedResult.result.accepted)
    let retained = try XCTUnwrap(retainedResult.notebook)
    XCTAssertEqual(retained.notebookId, original.notebookId)
    XCTAssertEqual(retained.libraryId, protectedLibrary.libraryId)

    let unauthenticated = GraphQLNoteGraphQLService(service: defaultService.unauthenticated())
    let hidden = await unauthenticated.notebook(notebookId: retained.notebookId)
    XCTAssertFalse(hidden.result.accepted)
    XCTAssertNil(hidden.value)
  }

  private func makeNoteGraphQLService(function: String = #function) throws -> GraphQLNoteGraphQLService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/AppGraphQLTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return try GraphQLNoteGraphQLService(
      service: NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    )
  }

  private func graphQLPayload(_ body: JSONObject, field: String) throws -> JSONObject {
    let data = try objectValue(body["data"], field: "data")
    return try objectValue(data[field], field: field)
  }

  private func resultObject(_ payload: JSONObject) throws -> JSONObject {
    try objectValue(payload["result"], field: "result")
  }

  private func objectValue(_ value: JSONValue?, field: String) throws -> JSONObject {
    guard case let .object(object) = value else {
      throw XCTSkip("Expected object at \(field), got \(String(describing: value))")
    }
    return object
  }
}
