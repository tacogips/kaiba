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
