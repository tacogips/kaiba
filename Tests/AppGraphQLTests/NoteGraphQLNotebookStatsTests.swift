import Foundation

import AppGraphQL
import AppCore
import XCTest

final class NoteGraphQLNotebookStatsTests: XCTestCase {
  func testNotebookDTOAndDocumentExecutorExposeNoteCount() async throws {
    let service = try makeNoteGraphQLService()
    let created = await service.saveConversation(
      title: "Stats Conversation",
      transcript: [
        NoteConversationTurn(userMarkdown: "One", assistantMarkdown: "First"),
        NoteConversationTurn(userMarkdown: "Two", assistantMarkdown: "Second")
      ]
    )
    let notebookId = try XCTUnwrap(created.notebook?.notebookId)

    let fetched = await service.notebook(notebookId: notebookId)
    XCTAssertEqual(fetched.value?.noteCount, 2)

    let executor = NoteGraphQLDocumentExecutor(service: service)
    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      query Notebook($notebookId: String!) {
        notebook(notebookId: $notebookId) { value { notebookId noteCount } }
      }
      """,
      variables: ["notebookId": .string(notebookId.rawValue)],
      operationName: "Notebook"
    ))

    XCTAssertTrue(response.handled)
    XCTAssertEqual(response.status, 200)
    let payload = try graphQLPayload(response.body, field: "notebook")
    let value = try objectValue(payload["value"], field: "notebook.value")
    XCTAssertEqual(value["notebookId"], .string(notebookId.rawValue))
    XCTAssertEqual(value["noteCount"], .integer(2))
  }

  func testPublishedNoteSchemaIncludesNotebookNoteCount() throws {
    XCTAssertTrue(GraphQLContractProjector.schemaContract.contains("noteCount: Int"))
    XCTAssertTrue(try schemaFieldNames("Notebook").contains("noteCount"))
  }

  private func makeNoteGraphQLService(function: String = #function) throws -> GraphQLNoteGraphQLService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/NoteGraphQLNotebookStatsTests", isDirectory: true)
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

  private func objectValue(_ value: JSONValue?, field: String) throws -> JSONObject {
    guard case let .object(object)? = value else {
      XCTFail("expected \(field) object")
      return [:]
    }
    return object
  }

  private func schemaFieldNames(_ typeName: String) throws -> Set<String> {
    let schema = GraphQLContractProjector.schemaContract
    let pattern = #"(?:type|input)\s+\#(typeName)\s*\{([^}]*)\}"#
    let expression = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
    let range = NSRange(schema.startIndex..<schema.endIndex, in: schema)
    guard let match = expression.firstMatch(in: schema, range: range),
      let bodyRange = Range(match.range(at: 1), in: schema) else {
      XCTFail("missing schema type \(typeName)")
      return []
    }
    return try parseSchemaFieldNames(String(schema[bodyRange]))
  }

  private func parseSchemaFieldNames(_ body: String) throws -> Set<String> {
    let expression = try NSRegularExpression(
      pattern: #"\b([A-Za-z_][A-Za-z0-9_]*)\s*(?:\([^)]*\))?\s*:"#,
      options: []
    )
    let range = NSRange(body.startIndex..<body.endIndex, in: body)
    return Set(expression.matches(in: body, range: range).compactMap { match in
      guard let fieldRange = Range(match.range(at: 1), in: body) else {
        return nil
      }
      return String(body[fieldRange])
    })
  }
}
