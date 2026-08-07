import Foundation

import AppCore
import XCTest
@testable import AppGraphQL

final class NoteGraphQLParsingRegressionTests: XCTestCase {
  func testHandlesBlockStringsUnicodeEscapesAndVariableDefaults() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let created = await executor.execute(GraphQLDocumentRequest(
      query: ##"""
      mutation CreateWithDefaults(
        $input: CreateNoteInput! = {
          title: "Unicode \u263A"
          bodyMarkdown: """# Block Body

      Line two with no escape processing."""
        }
      ) {
        createNote(input: $input) { result { accepted status } note { noteId title bodyMarkdown } }
      }
      """##,
      operationName: "CreateWithDefaults"
    ))

    XCTAssertTrue(created.handled)
    let payload = try graphQLPayload(created.body, field: "createNote")
    XCTAssertEqual(try resultObject(payload)["accepted"], .bool(true))
    let note = try objectValue(payload["note"], field: "createNote.note")
    XCTAssertEqual(note["title"], .string("Unicode \u{263A}"))
    XCTAssertEqual(
      note["bodyMarkdown"],
      .string("# Block Body\n\nLine two with no escape processing.")
    )
  }

  func testBlockStringsNormalizeCRLFLineEndings() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let bodyMarkdown = "\"\"\"\r\n  # CRLF Body\r\n\r\n  Line two\r\n\"\"\""
    let query = """
    mutation {
      createNote(input: { bodyMarkdown: \(bodyMarkdown) }) {
        result { accepted }
        note { bodyMarkdown }
      }
    }
    """

    let created = await executor.execute(GraphQLDocumentRequest(query: query))

    XCTAssertTrue(created.handled)
    let payload = try graphQLPayload(created.body, field: "createNote")
    XCTAssertEqual(try resultObject(payload)["accepted"], .bool(true))
    let note = try objectValue(payload["note"], field: "createNote.note")
    XCTAssertEqual(note["bodyMarkdown"], .string("# CRLF Body\n\nLine two"))
  }

  func testHandlesFixedWidthUnicodeSurrogatePairs() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)

    let created = await executor.execute(GraphQLDocumentRequest(
      query: #"""
      mutation {
        createNote(input: { title: "Emoji \uD83D\uDE00", bodyMarkdown: "# Surrogate" }) {
          result { accepted }
          note { title }
        }
      }
      """#
    ))

    XCTAssertTrue(created.handled)
    let payload = try graphQLPayload(created.body, field: "createNote")
    XCTAssertEqual(try resultObject(payload)["accepted"], .bool(true))
    let note = try objectValue(payload["note"], field: "createNote.note")
    XCTAssertEqual(note["title"], .string("Emoji \u{1F600}"))
  }

  func testRejectsInvalidUnicodeSurrogatesAndFractionalIntegerArguments() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)

    let invalidSurrogate = await executor.execute(GraphQLDocumentRequest(
      query: #"""
      mutation {
        createNote(input: { title: "Bad \uD83D", bodyMarkdown: "# Bad" }) {
          result { accepted }
          note { noteId }
        }
      }
      """#
    ))

    XCTAssertTrue(invalidSurrogate.handled)
    let surrogateErrors = try arrayValue(invalidSurrogate.body["errors"], field: "surrogate errors")
    let surrogateError = try objectValue(surrogateErrors.first, field: "surrogate errors[0]")
    XCTAssertTrue(
      try stringValue(surrogateError["message"], field: "surrogate errors[0].message")
        .contains("high surrogate")
    )

    let fractionalLimit = await executor.execute(GraphQLDocumentRequest(
      query: "query { notes(limit: 2.9) { result { accepted } value { noteId } } }"
    ))

    XCTAssertTrue(fractionalLimit.handled)
    let limitErrors = try arrayValue(fractionalLimit.body["errors"], field: "limit errors")
    let limitError = try objectValue(limitErrors.first, field: "limit errors[0]")
    XCTAssertTrue(
      try stringValue(limitError["message"], field: "limit errors[0].message")
        .contains("limit must be an integer")
    )
  }

  func testReportsEmptyRequiredStringsAsInvalidVariables() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)

    let response = await executor.execute(GraphQLDocumentRequest(
      query: #"query { note(noteId: "") { result { accepted } value { noteId } } }"#
    ))

    XCTAssertTrue(response.handled)
    let errors = try arrayValue(response.body["errors"], field: "empty note id errors")
    let error = try objectValue(errors.first, field: "empty note id errors[0]")
    XCTAssertTrue(
      try stringValue(error["message"], field: "empty note id errors[0].message")
        .contains("noteId must not be empty")
    )
  }

  func testRejectsInvalidOptionalStringInputsInsteadOfDroppingFilters() async throws {
    let service = try makeNoteGraphQLService()
    _ = try service.service.createNote(bodyMarkdown: "# Filtered\n\nVisible only when filter is dropped")
    let executor = NoteGraphQLDocumentExecutor(service: service)

    let invalidTagFilter = await executor.execute(GraphQLDocumentRequest(
      query: """
      query Search($tagFilter: [String!]) {
        searchNotes(query: "Visible", tagFilter: $tagFilter) { result { accepted } value { note { noteId } } }
      }
      """,
      variables: ["tagFilter": .array([.integer(123)])],
      operationName: "Search"
    ))

    XCTAssertTrue(invalidTagFilter.handled)
    let errors = try arrayValue(invalidTagFilter.body["errors"], field: "invalid tagFilter errors")
    let error = try objectValue(errors.first, field: "invalid tagFilter errors[0]")
    XCTAssertTrue(
      try stringValue(error["message"], field: "invalid tagFilter errors[0].message")
        .contains("tagFilter must be an array of strings")
    )
    let data = try objectValue(invalidTagFilter.body["data"], field: "invalid tagFilter data")
    XCTAssertEqual(data["searchNotes"], .null)

    let invalidNotebookId = await executor.execute(GraphQLDocumentRequest(
      query: "query Notes($notebookId: String) { notes(notebookId: $notebookId) { result { accepted } value { noteId } } }",
      variables: ["notebookId": .integer(123)],
      operationName: "Notes"
    ))

    XCTAssertTrue(invalidNotebookId.handled)
    let notebookErrors = try arrayValue(invalidNotebookId.body["errors"], field: "invalid notebookId errors")
    let notebookError = try objectValue(notebookErrors.first, field: "invalid notebookId errors[0]")
    XCTAssertTrue(
      try stringValue(notebookError["message"], field: "invalid notebookId errors[0].message")
        .contains("notebookId must be a string")
    )
  }

  func testRejectsUnknownEscapes() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    _ = try service.service.createNote(bodyMarkdown: "# Existing\n\nBody")

    let unknownEscape = await executor.execute(GraphQLDocumentRequest(
      query: #"""
      mutation {
        createNote(input: { bodyMarkdown: "bad \q escape" }) { result { accepted } note { noteId } }
      }
      """#
    ))

    XCTAssertTrue(unknownEscape.handled)
    let escapeErrors = try arrayValue(unknownEscape.body["errors"], field: "unknown escape errors")
    let escapeError = try objectValue(escapeErrors.first, field: "unknown escape errors[0]")
    XCTAssertTrue(
      try stringValue(escapeError["message"], field: "unknown escape errors[0].message")
        .contains("unsupported GraphQL string escape")
    )
  }

  func testRejectsDeepSelectionAndInputValueNesting() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let deepSelections = String(repeating: "result { ", count: 25) + "accepted" + String(repeating: " }", count: 25)
    let deepSelectionResponse = await executor.execute(GraphQLDocumentRequest(
      query: "mutation { createNote(input: { bodyMarkdown: \"# Deep\" }) { \(deepSelections) } }"
    ))

    XCTAssertTrue(deepSelectionResponse.handled)
    let selectionErrors = try arrayValue(deepSelectionResponse.body["errors"], field: "deep selection errors")
    let selectionError = try objectValue(selectionErrors.first, field: "deep selection errors[0]")
    XCTAssertTrue(
      try stringValue(selectionError["message"], field: "deep selection errors[0].message")
        .contains("selection depth limit exceeded")
    )

    let deepInput = String(repeating: "a: { ", count: 12) + "leaf: \"value\"" + String(repeating: " }", count: 12)
    let deepValueResponse = await executor.execute(GraphQLDocumentRequest(
      query: "mutation { createNote(input: { bodyMarkdown: \"# Deep\", metaJSON: { \(deepInput) } }) { result { accepted } } }"
    ))

    XCTAssertTrue(deepValueResponse.handled)
    let valueErrors = try arrayValue(deepValueResponse.body["errors"], field: "deep value errors")
    let valueError = try objectValue(valueErrors.first, field: "deep value errors[0]")
    XCTAssertTrue(
      try stringValue(valueError["message"], field: "deep value errors[0].message")
        .contains("value depth limit exceeded")
    )
  }

  func testResolvesOmittedNullableVariableInsideInputObjectToNull() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let query = """
    mutation Create($title: String) {
      createNote(input: { title: $title, bodyMarkdown: "# Nullable Variable\\n\\nBody" }) {
        result { accepted }
        note { noteId }
      }
    }
    """
    let parsedFields = try XCTUnwrap(parseNoteGraphQLRootFields(
      in: query,
      operationName: "Create",
      variables: [:],
      parseArguments: true
    ))
    XCTAssertEqual(
      parsedFields.first?.arguments["input"],
      .object([
        "title": .null,
        "bodyMarkdown": .string("# Nullable Variable\n\nBody")
      ])
    )

    let response = await executor.execute(GraphQLDocumentRequest(
      query: query,
      operationName: "Create"
    ))

    XCTAssertTrue(response.handled)
    XCTAssertNil(response.body["errors"])
    let payload = try graphQLPayload(response.body, field: "createNote")
    XCTAssertEqual(try resultObject(payload)["accepted"], .bool(true))
    XCTAssertEqual(try service.service.listNotes(limit: 10).count, 1)
  }

  func testRejectsOmittedNonNullVariableInsideInputObject() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation Create($title: String!) {
        createNote(input: { title: $title, bodyMarkdown: "# Missing Variable\\n\\nBody" }) {
          result { accepted }
          note { noteId }
        }
      }
      """,
      operationName: "Create"
    ))

    XCTAssertTrue(response.handled)
    let objectErrors = try arrayValue(response.body["errors"], field: "object missing variable errors")
    let objectError = try objectValue(objectErrors.first, field: "object missing variable errors[0]")
    XCTAssertTrue(
      try stringValue(objectError["message"], field: "object missing variable errors[0].message")
        .contains("missingVariable: title")
    )
    XCTAssertEqual(try service.service.listNotes(limit: 10).count, 0)
  }

  private func makeNoteGraphQLService(function: String = #function) throws -> GraphQLNoteGraphQLService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp", isDirectory: true)
      .appendingPathComponent("note-graphql-parsing-\(function)-\(UUID().uuidString)", isDirectory: true)
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
      throw unexpectedShapeError(expected: "object", value: value, field: field)
    }
    return object
  }

  private func arrayValue(_ value: JSONValue?, field: String) throws -> [JSONValue] {
    guard case let .array(array) = value else {
      throw unexpectedShapeError(expected: "array", value: value, field: field)
    }
    return array
  }

  private func stringValue(_ value: JSONValue?, field: String) throws -> String {
    guard case let .string(string) = value else {
      throw unexpectedShapeError(expected: "string", value: value, field: field)
    }
    return string
  }

  private func unexpectedShapeError(
    expected: String,
    value: JSONValue?,
    field: String
  ) -> NSError {
    NSError(
      domain: "NoteGraphQLDocumentParsingRegressionTests",
      code: 1,
      userInfo: [
        NSLocalizedDescriptionKey:
          "Expected \(expected) at \(field), got \(String(describing: value))"
      ]
    )
  }
}
