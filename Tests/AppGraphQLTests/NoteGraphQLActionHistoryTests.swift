import Foundation

import AppCore
import XCTest
@testable import AppGraphQL

/// Contract round-trips of the action-history surface: `actionHistory`,
/// `undoState`, `undoAction`, `redoAction`
/// (`design-docs/specs/action-history-undo.md`).
final class NoteGraphQLActionHistoryTests: XCTestCase {
  func testUndoRedoRoundTripThroughExecutor() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let note = try service.service.createNote(bodyMarkdown: "# Doc\n\nversion one")
    _ = try service.service.updateNoteBody(
      noteId: note.noteId,
      bodyMarkdown: "# Doc\n\nversion two"
    )

    let state = await executor.execute(GraphQLDocumentRequest(
      query: "query { undoState { result { accepted } undo { action title } redo { action } } }"
    ))
    XCTAssertTrue(state.handled)
    let statePayload = try graphQLPayload(state.body, field: "undoState")
    let undoTarget = try objectValue(statePayload["undo"], field: "undoState.undo")
    XCTAssertEqual(undoTarget["action"], .string("note-body-updated"))
    XCTAssertEqual(statePayload["redo"], .null)

    let undone = await executor.execute(GraphQLDocumentRequest(
      query: "mutation { undoAction { result { accepted } status target { action } applied { action } } }"
    ))
    XCTAssertTrue(undone.handled)
    let undonePayload = try graphQLPayload(undone.body, field: "undoAction")
    XCTAssertEqual(undonePayload["status"], .string("ok"))
    XCTAssertEqual(
      try objectValue(undonePayload["applied"], field: "undoAction.applied")["action"],
      .string("undone")
    )
    XCTAssertEqual(
      try service.service.getNote(note.noteId).bodyMarkdown,
      "# Doc\n\nversion one"
    )

    let redone = await executor.execute(GraphQLDocumentRequest(
      query: "mutation { redoAction { result { accepted } status } }"
    ))
    XCTAssertTrue(redone.handled)
    XCTAssertEqual(
      try graphQLPayload(redone.body, field: "redoAction")["status"],
      .string("ok")
    )
    XCTAssertEqual(
      try service.service.getNote(note.noteId).bodyMarkdown,
      "# Doc\n\nversion two"
    )
  }

  func testActionHistoryListsEntriesNewestFirst() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let note = try service.service.createNote(bodyMarkdown: "# Doc\n\nfirst")
    _ = try service.service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "# Doc\n\nsecond")

    let history = await executor.execute(GraphQLDocumentRequest(
      query: "query { actionHistory(limit: 10) { result { accepted } entries { seq action entityType undoable } } }"
    ))
    XCTAssertTrue(history.handled)
    let payload = try graphQLPayload(history.body, field: "actionHistory")
    let entries = try arrayValue(payload["entries"], field: "actionHistory.entries")
    XCTAssertEqual(
      entries.map { $0["action"]?.asString },
      ["note-body-updated", "note-created", "notebook-created"]
    )
  }

  func testRedoWithoutUndoReportsNothingToRedo() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let result = await executor.execute(GraphQLDocumentRequest(
      query: "mutation { redoAction { result { accepted } status } }"
    ))
    XCTAssertTrue(result.handled)
    let payload = try graphQLPayload(result.body, field: "redoAction")
    XCTAssertEqual(payload["status"], .string("nothing-to-redo"))
  }

  private func makeNoteGraphQLService(function: String = #function) throws -> GraphQLNoteGraphQLService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp", isDirectory: true)
      .appendingPathComponent("note-graphql-history-\(function)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    return GraphQLNoteGraphQLService(service: service)
  }

  private func graphQLPayload(_ body: JSONObject, field: String) throws -> JSONObject {
    let data = try objectValue(body["data"], field: "data")
    return try objectValue(data[field], field: "data.\(field)")
  }

  private func objectValue(_ value: JSONValue?, field: String) throws -> JSONObject {
    guard case let .object(object) = value else {
      throw NSError(
        domain: "NoteGraphQLActionHistoryTests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "expected object at \(field), got \(String(describing: value))"]
      )
    }
    return object
  }

  private func arrayValue(_ value: JSONValue?, field: String) throws -> [JSONValue] {
    guard case let .array(array) = value else {
      throw NSError(
        domain: "NoteGraphQLActionHistoryTests",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "expected array at \(field), got \(String(describing: value))"]
      )
    }
    return array
  }
}
