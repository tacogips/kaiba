import Foundation

import AppGraphQL
import AppCore
import XCTest

final class NoteGraphQLSearchPaginationTests: XCTestCase {
  func testDocumentExecutorPaginatesSearchResultsByOffset() async throws {
    let service = try makeNoteGraphQLService()
    _ = try service.service.createNote(bodyMarkdown: "# First\n\nPaged GraphQL search body")
    _ = try service.service.createNote(bodyMarkdown: "# Second\n\nPaged GraphQL search body")
    _ = try service.service.createNote(bodyMarkdown: "# Third\n\nPaged GraphQL search body")
    let expected = try service.service.searchNotes(query: "Paged", limit: 2, offset: 1).map(\.note.noteId)
    let executor = NoteGraphQLDocumentExecutor(service: service)

    let paged = await executor.execute(GraphQLDocumentRequest(
      query: """
      query Search($query: String!, $limit: Int, $offset: Int) {
        searchNotes(query: $query, limit: $limit, offset: $offset) {
          value { note { noteId } }
        }
      }
      """,
      variables: [
        "query": .string("Paged"),
        "limit": .integer(2),
        "offset": .integer(1)
      ],
      operationName: "Search"
    ))

    XCTAssertTrue(paged.handled)
    let payload = try graphQLPayload(paged.body, field: "searchNotes")
    let values = try arrayValue(payload["value"], field: "searchNotes.value")
    XCTAssertEqual(values.count, 2)
    XCTAssertEqual(
      try values.enumerated().map { index, value in
        try noteId(in: value, field: "searchNotes.value[\(index)]")
      },
      expected
    )
  }

  private func makeNoteGraphQLService(function: String = #function) throws -> GraphQLNoteGraphQLService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/NoteGraphQLSearchPaginationTests", isDirectory: true)
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

  private func noteId(in value: JSONValue, field: String) throws -> NoteID {
    let result = try objectValue(value, field: field)
    let note = try objectValue(result["note"], field: "\(field).note")
    return NoteID(try stringValue(note["noteId"], field: "\(field).note.noteId"))
  }
}
