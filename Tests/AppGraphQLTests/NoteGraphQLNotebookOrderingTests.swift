import Foundation

import AppGraphQL
import AppCore
import XCTest

final class NoteGraphQLNotebookOrderingTests: XCTestCase {
  func testNotesQueryReturnsBulkIngestedPagesInNoteNumberOrder() async throws {
    let noteService = try makeNoteService()
    // Explicit descending note numbers so a created_at-based ordering would shuffle
    // the pages; the notebook-scoped ordering must return them by note_number.
    let ingest = try noteService.createNotebookWithNotes(
      title: "Ingested",
      pages: (1...4).map { NotePageDraft(bodyMarkdown: "# Page \($0)\nbody \($0)", noteNumber: 5 - $0) }
    )
    let service = GraphQLNoteGraphQLService(service: noteService)
    let executor = NoteGraphQLDocumentExecutor(service: service)

    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      query Notes($notebookId: String!) {
        notes(notebookId: $notebookId) { value { noteNumber title } }
      }
      """,
      variables: ["notebookId": .string(ingest.notebook.notebookId.rawValue)],
      operationName: "Notes"
    ))

    XCTAssertTrue(response.handled)
    let payload = try graphQLPayload(response.body, field: "notes")
    guard case let .array(values)? = payload["value"] else {
      return XCTFail("expected notes.value array")
    }
    let noteNumbers: [Int64] = values.compactMap { value in
      guard case let .object(object) = value, case let .integer(number)? = object["noteNumber"] else {
        return nil
      }
      return number
    }
    XCTAssertEqual(noteNumbers, [1, 2, 3, 4])
    let titles: [String] = values.compactMap { value in
      guard case let .object(object) = value, case let .string(title)? = object["title"] else {
        return nil
      }
      return title
    }
    XCTAssertEqual(titles, ["Page 4", "Page 3", "Page 2", "Page 1"])
  }

  private func makeNoteService(function: String = #function) throws -> NoteService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/NoteGraphQLNotebookOrderingTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
  }

  private func graphQLPayload(_ body: JSONObject, field: String) throws -> JSONObject {
    guard case let .object(data)? = body["data"], case let .object(object)? = data[field] else {
      XCTFail("expected \(field) object")
      return [:]
    }
    return object
  }
}
