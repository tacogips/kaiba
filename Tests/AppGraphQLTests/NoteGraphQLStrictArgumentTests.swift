import Foundation

import AppCore
import XCTest
@testable import AppGraphQL

final class NoteGraphQLStrictArgumentTests: XCTestCase {
  // MARK: - limit / offset: out of range or wrong type

  func testInlineOutOfRangeDoubleLimitReturnsInvalidVariable() async throws {
    let executor = try makeExecutor()
    let response = await executor.execute(GraphQLDocumentRequest(
      query: "query { notes(limit: 1e300) { result { accepted } value { noteId } } }"
    ))
    try assertInvalidVariable(response, field: "notes")
  }

  func testVariableOutOfRangeDoubleLimitReturnsInvalidVariable() async throws {
    let executor = try makeExecutor()
    let response = await executor.execute(GraphQLDocumentRequest(
      query: "query Notes($limit: Int) { notes(limit: $limit) { result { accepted } value { noteId } } }",
      variables: ["limit": .number(1e300)],
      operationName: "Notes"
    ))
    try assertInvalidVariable(response, field: "notes")
  }

  func testInlineMaxIntOffsetIsAcceptedButExceedsOffsetBound() async throws {
    let executor = try makeExecutor()
    // 9223372036854775807 is a valid Int but exceeds the documented offset bound.
    let response = await executor.execute(GraphQLDocumentRequest(
      query: "query { notes(offset: 9223372036854775807) { result { accepted } value { noteId } } }"
    ))
    try assertInvalidVariable(response, field: "notes")
  }

  func testVariableMaxIntOffsetExceedsOffsetBound() async throws {
    let executor = try makeExecutor()
    let response = await executor.execute(GraphQLDocumentRequest(
      query: "query Notes($offset: Int) { notes(offset: $offset) { result { accepted } value { noteId } } }",
      variables: ["offset": .integer(9223372036854775807)],
      operationName: "Notes"
    ))
    try assertInvalidVariable(response, field: "notes")
  }

  func testInlineStringLimitReturnsInvalidVariable() async throws {
    let executor = try makeExecutor()
    let response = await executor.execute(GraphQLDocumentRequest(
      query: "query { notes(limit: \"5\") { result { accepted } value { noteId } } }"
    ))
    try assertInvalidVariable(response, field: "notes")
  }

  func testVariableStringLimitReturnsInvalidVariable() async throws {
    let executor = try makeExecutor()
    let response = await executor.execute(GraphQLDocumentRequest(
      query: "query Notes($limit: Int) { notes(limit: $limit) { result { accepted } value { noteId } } }",
      variables: ["limit": .string("5")],
      operationName: "Notes"
    ))
    try assertInvalidVariable(response, field: "notes")
  }

  func testLimitAboveMaximumReturnsInvalidVariable() async throws {
    let executor = try makeExecutor()
    let response = await executor.execute(GraphQLDocumentRequest(
      query: "query { notes(limit: 201) { result { accepted } value { noteId } } }"
    ))
    try assertInvalidVariable(response, field: "notes")
  }

  func testOffsetAboveMaximumReturnsInvalidVariable() async throws {
    let executor = try makeExecutor()
    let response = await executor.execute(GraphQLDocumentRequest(
      query: "query { notes(offset: 1000001) { result { accepted } value { noteId } } }"
    ))
    try assertInvalidVariable(response, field: "notes")
  }

  func testZeroLimitReturnsEmptyList() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    _ = try service.service.createNote(bodyMarkdown: "# First\n\nBody")
    _ = try service.service.createNote(bodyMarkdown: "# Second\n\nBody")

    let response = await executor.execute(GraphQLDocumentRequest(
      query: "query { notes(limit: 0) { result { accepted } value { noteId } } }"
    ))

    XCTAssertTrue(response.handled)
    XCTAssertNil(response.body["errors"])
    let payload = try graphQLPayload(response.body, field: "notes")
    XCTAssertEqual(try resultObject(payload)["accepted"], .bool(true))
    let values = try arrayValue(payload["value"], field: "notes.value")
    XCTAssertTrue(values.isEmpty)
  }

  // MARK: - empty string arguments

  func testInlineEmptyNotebookIdReturnsInvalidVariable() async throws {
    let executor = try makeExecutor()
    let response = await executor.execute(GraphQLDocumentRequest(
      query: "query { notes(notebookId: \"\") { result { accepted } value { noteId } } }"
    ))
    try assertInvalidVariable(response, field: "notes")
  }

  func testVariableEmptyNotebookIdReturnsInvalidVariable() async throws {
    let executor = try makeExecutor()
    let response = await executor.execute(GraphQLDocumentRequest(
      query: "query Notes($notebookId: String) { notes(notebookId: $notebookId) { result { accepted } value { noteId } } }",
      variables: ["notebookId": .string("")],
      operationName: "Notes"
    ))
    try assertInvalidVariable(response, field: "notes")
  }

  // MARK: - multi-root execution

  func testMultipleRootSelectionsReturnBothFields() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    _ = try service.service.defineTagClass(classId: TagClassID("custom-topic"), label: "Topic")
    _ = try service.service.defineTag(name: "swift", classId: TagClassID("custom-topic"))

    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      query {
        tags { result { accepted } value { name } }
        tagClasses { result { accepted } value { classId } }
      }
      """
    ))

    XCTAssertTrue(response.handled)
    XCTAssertNil(response.body["errors"])
    let data = try objectValue(response.body["data"], field: "data")
    XCTAssertNotNil(data["tags"])
    XCTAssertNotNil(data["tagClasses"])
    let tagsPayload = try objectValue(data["tags"], field: "data.tags")
    XCTAssertEqual(try resultObject(tagsPayload)["accepted"], .bool(true))
    let classesPayload = try objectValue(data["tagClasses"], field: "data.tagClasses")
    XCTAssertEqual(try resultObject(classesPayload)["accepted"], .bool(true))
  }

  // MARK: - directive rejection

  func testRootDirectiveReturnsUnsupportedError() async throws {
    let executor = try makeExecutor()
    let response = await executor.execute(GraphQLDocumentRequest(
      query: "query { tags @skip(if: true) { result { accepted } value { name } } }"
    ))
    try assertErrorMessage(response, contains: "directives are not supported")
  }

  func testNestedDirectiveReturnsUnsupportedError() async throws {
    let executor = try makeExecutor()
    let response = await executor.execute(GraphQLDocumentRequest(
      query: "query { tags { result @include(if: false) { accepted } value { name } } }"
    ))
    try assertErrorMessage(response, contains: "directives are not supported")
  }

  // MARK: - helpers

  private func makeExecutor(function: String = #function) throws -> NoteGraphQLDocumentExecutor {
    NoteGraphQLDocumentExecutor(service: try makeNoteGraphQLService(function: function))
  }

  private func assertInvalidVariable(
    _ response: GraphQLDocumentExecutionResponse,
    field: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    try assertErrorMessage(response, contains: "invalidVariable", file: file, line: line)
  }

  private func assertErrorMessage(
    _ response: GraphQLDocumentExecutionResponse,
    contains substring: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    XCTAssertTrue(response.handled, "expected handled response", file: file, line: line)
    guard case let .array(errors)? = response.body["errors"], let first = errors.first,
          case let .object(errorObject) = first, case let .string(message)? = errorObject["message"] else {
      XCTFail("expected an error message, got \(String(describing: response.body))", file: file, line: line)
      return
    }
    XCTAssertTrue(
      message.contains(substring),
      "expected error containing '\(substring)', got '\(message)'",
      file: file,
      line: line
    )
  }

  private func makeNoteGraphQLService(function: String = #function) throws -> GraphQLNoteGraphQLService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp", isDirectory: true)
      .appendingPathComponent("note-graphql-strict-\(function)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    return GraphQLNoteGraphQLService(service: service)
  }

  private func graphQLPayload(_ body: JSONObject, field: String) throws -> JSONObject {
    let data = try objectValue(body["data"], field: "data")
    return try objectValue(data[field], field: "data.\(field)")
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

  private func arrayValue(_ value: JSONValue?, field: String) throws -> [JSONValue] {
    guard case let .array(array) = value else {
      throw XCTSkip("Expected array at \(field), got \(String(describing: value))")
    }
    return array
  }

  private func stringValue(_ value: JSONValue?, field: String) throws -> String {
    guard case let .string(string) = value else {
      throw XCTSkip("Expected string at \(field), got \(String(describing: value))")
    }
    return string
  }
}
