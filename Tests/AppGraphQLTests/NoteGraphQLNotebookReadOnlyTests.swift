import Foundation

import AppCore
import XCTest
@testable import AppGraphQL

final class NoteGraphQLNotebookReadOnlyTests: XCTestCase {
  func testDocumentExecutorProjectsAndPersistsNotebookLockAndUnlock() async throws {
    let service = try makeNoteGraphQLService()
    let notebook = try service.service.createNotebook(title: "Lockable notebook")
    let executor = NoteGraphQLDocumentExecutor(service: service)

    let initial = try await queriedNotebook(executor: executor, notebookId: notebook.notebookId)
    XCTAssertEqual(initial["notebookId"], .string(notebook.notebookId.rawValue))
    XCTAssertEqual(initial["readOnly"], .bool(false))

    let locked = try await setNotebookReadOnly(
      executor: executor,
      notebookId: notebook.notebookId,
      readOnly: true
    )
    XCTAssertEqual(try resultObject(locked)["accepted"], .bool(true))
    XCTAssertEqual(try resultObject(locked)["status"], .string("ok"))
    let lockedNotebook = try objectValue(locked["notebook"], field: "setNotebookReadOnly.notebook")
    XCTAssertEqual(lockedNotebook["notebookId"], .string(notebook.notebookId.rawValue))
    XCTAssertEqual(lockedNotebook["readOnly"], .bool(true))
    XCTAssertEqual(try service.service.getNotebook(notebook.notebookId).readOnly, true)
    XCTAssertEqual(
      lockedNotebook["updatedAt"],
      .string(try service.service.getNotebook(notebook.notebookId).updatedAt)
    )

    let unlocked = try await setNotebookReadOnly(
      executor: executor,
      notebookId: notebook.notebookId,
      readOnly: false
    )
    XCTAssertEqual(try resultObject(unlocked)["accepted"], .bool(true))
    let unlockedNotebook = try objectValue(unlocked["notebook"], field: "setNotebookReadOnly.notebook")
    XCTAssertEqual(unlockedNotebook["readOnly"], .bool(false))
    XCTAssertEqual(try service.service.getNotebook(notebook.notebookId).readOnly, false)
    let queriedAfterUnlock = try await queriedNotebook(
      executor: executor,
      notebookId: notebook.notebookId
    )
    XCTAssertEqual(queriedAfterUnlock["readOnly"], .bool(false))
  }

  func testDocumentExecutorMapsMissingNotebookLockMutationToNotFound() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)

    let missing = try await setNotebookReadOnly(
      executor: executor,
      notebookId: NotebookID("missing-notebook"),
      readOnly: false
    )

    let result = try resultObject(missing)
    XCTAssertEqual(result["accepted"], .bool(false))
    XCTAssertEqual(result["status"], .string("not_found"))
    XCTAssertEqual(
      result["diagnostics"],
      .array([.string("requested note resource was not found")])
    )
    XCTAssertEqual(missing["notebook"], .null)
  }

  func testDocumentExecutorRejectsSecondLongTermMemoryIdentityAcrossPublicMutations() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let canonical = try service.service.longTermMemoryNotebook()
    let ordinary = try service.service.createNotebook(title: "Ordinary notebook")
    let reservedTag = NoteStoreSchema.longTermMemoryNotebookKindTag

    let createNotebook = try await executeMutation(
      executor: executor,
      field: "createNotebook",
      operationName: "CreateReservedNotebook",
      query: """
      mutation CreateReservedNotebook($input: CreateNotebookInput!) {
        createNotebook(input: $input) {
          result { accepted status diagnostics }
          notebook { notebookId }
        }
      }
      """,
      variables: ["input": .object([
        "title": .string("Blocked GraphQL notebook"),
        "kindTagName": .string(reservedTag)
      ])]
    )
    try assertReservedLongTermMemoryRejection(createNotebook)

    let applyTag = try await executeMutation(
      executor: executor,
      field: "applyNotebookTags",
      operationName: "ApplyReservedNotebookTag",
      query: """
      mutation ApplyReservedNotebookTag($input: ApplyNotebookTagsInput!) {
        applyNotebookTags(input: $input) {
          result { accepted status diagnostics }
          notebook { notebookId }
        }
      }
      """,
      variables: ["input": .object([
        "notebookId": .string(ordinary.notebookId.rawValue),
        "tags": .array([.string(reservedTag)]),
        "provenance": .string("human")
      ])]
    )
    try assertReservedLongTermMemoryRejection(applyTag)

    let reservedTagId = try XCTUnwrap(
      service.service.listTags().first { $0.name == reservedTag }?.tagId
    )
    let applyTagId = try await executeMutation(
      executor: executor,
      field: "applyNotebookTagIds",
      operationName: "ApplyReservedNotebookTagId",
      query: """
      mutation ApplyReservedNotebookTagId($input: ApplyNotebookTagIdsInput!) {
        applyNotebookTagIds(input: $input) {
          result { accepted status diagnostics }
          notebook { notebookId }
        }
      }
      """,
      variables: ["input": .object([
        "notebookId": .string(ordinary.notebookId.rawValue),
        "tagIds": .array([.string(reservedTagId.rawValue)]),
        "provenance": .string("human")
      ])]
    )
    try assertReservedLongTermMemoryRejection(applyTagId)

    XCTAssertEqual(
      try service.service.listNotebooks(tagFilterIdGroups: [[reservedTagId]]).map(\.notebookId),
      [canonical.notebookId]
    )
    let reopened = try NoteService(driver: service.service.driver)
    XCTAssertEqual(try reopened.longTermMemoryNotebook().notebookId, canonical.notebookId)
  }

  private func setNotebookReadOnly(
    executor: NoteGraphQLDocumentExecutor,
    notebookId: NotebookID,
    readOnly: Bool
  ) async throws -> JSONObject {
    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation SetNotebookReadOnly($notebookId: String!, $readOnly: Boolean!) {
        setNotebookReadOnly(notebookId: $notebookId, readOnly: $readOnly) {
          result { accepted status diagnostics }
          notebook { notebookId title readOnly updatedAt }
        }
      }
      """,
      variables: [
        "notebookId": .string(notebookId.rawValue),
        "readOnly": .bool(readOnly)
      ],
      operationName: "SetNotebookReadOnly"
    ))
    XCTAssertTrue(response.handled)
    XCTAssertEqual(response.status, 200)
    return try graphQLPayload(response.body, field: "setNotebookReadOnly")
  }

  private func queriedNotebook(
    executor: NoteGraphQLDocumentExecutor,
    notebookId: NotebookID
  ) async throws -> JSONObject {
    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      query Notebook($notebookId: String!) {
        notebook(notebookId: $notebookId) {
          result { accepted status diagnostics }
          value { notebookId title readOnly updatedAt }
        }
      }
      """,
      variables: ["notebookId": .string(notebookId.rawValue)],
      operationName: "Notebook"
    ))
    XCTAssertTrue(response.handled)
    let payload = try graphQLPayload(response.body, field: "notebook")
    XCTAssertEqual(try resultObject(payload)["accepted"], .bool(true))
    return try objectValue(payload["value"], field: "notebook.value")
  }

  private func executeMutation(
    executor: NoteGraphQLDocumentExecutor,
    field: String,
    operationName: String,
    query: String,
    variables: JSONObject
  ) async throws -> JSONObject {
    let response = await executor.execute(GraphQLDocumentRequest(
      query: query,
      variables: variables,
      operationName: operationName
    ))
    XCTAssertTrue(response.handled)
    XCTAssertEqual(response.status, 200)
    return try graphQLPayload(response.body, field: field)
  }

  private func assertReservedLongTermMemoryRejection(
    _ payload: JSONObject,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let result = try resultObject(payload)
    XCTAssertEqual(result["accepted"], .bool(false), file: file, line: line)
    XCTAssertEqual(result["status"], .string("invalid_request"), file: file, line: line)
    guard case let .array(diagnostics)? = result["diagnostics"],
          case let .string(diagnostic)? = diagnostics.first else {
      return XCTFail("expected invalid_request diagnostic", file: file, line: line)
    }
    XCTAssertTrue(diagnostic.contains(NoteStoreSchema.longTermMemoryNotebookKindTag), file: file, line: line)
    XCTAssertTrue(diagnostic.contains("canonical long-term-memory notebook"), file: file, line: line)
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
    guard case let .object(object)? = value else {
      XCTFail("expected \(field) object")
      return [:]
    }
    return object
  }
}
