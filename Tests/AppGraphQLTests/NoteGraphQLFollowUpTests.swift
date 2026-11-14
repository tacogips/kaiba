import Foundation

import AppCore
import XCTest
@testable import AppGraphQL

final class NoteGraphQLFollowUpTests: XCTestCase {
  func testDocumentExecutorRunsNoteSearchOptionsAndProposals() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let subject = try service.service.createNote(bodyMarkdown: "# Alpha Plan\n\nProject planning alpha.")
    let linked = try service.service.createNote(bodyMarkdown: "# Linked Context\n\nNeighbor context.")
    _ = try service.service.linkNotes(from: subject.noteId, to: linked.noteId, provenance: .human)

    let search = await executor.execute(GraphQLDocumentRequest(
      query: """
      query SearchOptions(
        $query: String!,
        $sort: NoteListSort,
        $createdAfter: String,
        $includeLinked: Boolean
      ) {
        searchNotes(query: $query, sort: $sort, createdAfter: $createdAfter, includeLinked: $includeLinked) {
          result { accepted status diagnostics }
          value { note { noteId } isLinkedNeighbor }
        }
      }
      """,
      variables: [
        "query": .string("alpha"),
        "sort": .string("title"),
        "createdAfter": .string("2000-01-01"),
        "includeLinked": .bool(true)
      ],
      operationName: "SearchOptions"
    ))

    XCTAssertTrue(search.handled)
    let payload = try graphQLPayload(search.body, field: "searchNotes")
    XCTAssertEqual(try resultObject(payload)["accepted"], .bool(true))
    let values = try arrayValue(payload["value"], field: "searchNotes.value")
    XCTAssertEqual(try noteId(in: values[0], field: "search result 0"), subject.noteId)
    XCTAssertEqual(try noteId(in: values[1], field: "search result 1"), linked.noteId)
    XCTAssertEqual(try objectValue(values[1], field: "search result 1")["isLinkedNeighbor"], .bool(true))

    try await assertNotebookSort(executor: executor, service: service)
    try await assertProposeNoteLinks(executor: executor, service: service, subjectNoteId: subject.noteId)
  }

  func testDocumentExecutorRejectsInvalidSort() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    _ = try service.service.createNote(bodyMarkdown: "# Invalid Sort\n\nBody")

    let rejected = await executor.execute(GraphQLDocumentRequest(
      query: """
      query InvalidSort($query: String!, $sort: NoteListSort) {
        searchNotes(query: $query, sort: $sort) {
          result { accepted status diagnostics }
          value { note { noteId } }
        }
      }
      """,
      variables: [
        "query": .string("Invalid"),
        "sort": .string("notASort")
      ],
      operationName: "InvalidSort"
    ))

    let payload = try graphQLPayload(rejected.body, field: "searchNotes")
    let result = try resultObject(payload)
    XCTAssertEqual(result["accepted"], .bool(false))
    let diagnostics = try arrayValue(result["diagnostics"], field: "searchNotes.result.diagnostics")
    XCTAssertTrue(diagnostics.contains { diagnostic in
      guard case let .string(message) = diagnostic else {
        return false
      }
      return message.contains("unsupported note sort: notASort")
    })
  }

  func testPublishedSchemaHasSingleRootTypeDefinitions() {
    let schema = GraphQLContractProjector.schemaContract

    XCTAssertEqual(schema.kaibaOccurrences(of: "type Query {"), 1)
    XCTAssertEqual(schema.kaibaOccurrences(of: "type Mutation {"), 1)
  }

  private func assertNotebookSort(
    executor: NoteGraphQLDocumentExecutor,
    service: GraphQLNoteGraphQLService
  ) async throws {
    let notebookA = await service.createNotebook(GraphQLCreateNotebookInput(title: "A Notebook"))
    let notebookB = await service.createNotebook(GraphQLCreateNotebookInput(title: "B Notebook"))
    let notebooks = await executor.execute(GraphQLDocumentRequest(
      query: """
      query NotebookSort($sort: NoteListSort) {
        notebooks(sort: $sort) { result { accepted } value { notebookId title } }
      }
      """,
      variables: ["sort": .string("title")],
      operationName: "NotebookSort"
    ))
    let notebookValues = try arrayValue(
      try graphQLPayload(notebooks.body, field: "notebooks")["value"],
      field: "notebooks.value"
    )
    let notebookIds = try notebookValues.map { value in
      NotebookID(
        try stringValue(try objectValue(value, field: "notebook")["notebookId"], field: "notebook.notebookId")
      )
    }
    XCTAssertLessThan(
      try XCTUnwrap(notebookIds.firstIndex(of: try XCTUnwrap(notebookA.notebook?.notebookId))),
      try XCTUnwrap(notebookIds.firstIndex(of: try XCTUnwrap(notebookB.notebook?.notebookId)))
    )
  }

  private func assertProposeNoteLinks(
    executor: NoteGraphQLDocumentExecutor,
    service: GraphQLNoteGraphQLService,
    subjectNoteId: NoteID
  ) async throws {
    _ = try service.service.createNote(bodyMarkdown: "# Planning Reference\n\nProject planning alpha reference.")
    let proposals = await executor.execute(GraphQLDocumentRequest(
      query: """
      query Propose($noteId: String!, $limit: Int) {
        proposeNoteLinks(noteId: $noteId, limit: $limit) {
          result { accepted }
          value { targetNoteId linkKind source reason }
        }
      }
      """,
      variables: [
        "noteId": .string(subjectNoteId.rawValue),
        "limit": .integer(4)
      ],
      operationName: "Propose"
    ))
    let proposalValues = try arrayValue(
      try graphQLPayload(proposals.body, field: "proposeNoteLinks")["value"],
      field: "proposeNoteLinks.value"
    )
    XCTAssertFalse(proposalValues.isEmpty)
    XCTAssertTrue(proposalValues.allSatisfy { value in
      (try? objectValue(value, field: "proposal")["source"]) == .string("deterministic")
    })
  }

  private func makeNoteGraphQLService(function: String = #function) throws -> GraphQLNoteGraphQLService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/AppGraphQLFollowUpTests", isDirectory: true)
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

  private func noteId(in value: JSONValue, field: String) throws -> NoteID {
    let note = try objectValue(try objectValue(value, field: field)["note"], field: "\(field).note")
    return NoteID(try stringValue(note["noteId"], field: "\(field).note.noteId"))
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
}

private extension String {
  func kaibaOccurrences(of needle: String) -> Int {
    guard !needle.isEmpty else {
      return 0
    }
    var count = 0
    var searchRange = startIndex..<endIndex
    while let range = range(of: needle, range: searchRange) {
      count += 1
      searchRange = range.upperBound..<endIndex
    }
    return count
  }
}
