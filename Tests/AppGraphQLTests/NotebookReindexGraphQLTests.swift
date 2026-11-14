import AppCore
import Foundation
import XCTest
@testable import AppGraphQL

final class NotebookReindexGraphQLTests: XCTestCase {
  func testNotebookRebuildMutationUsesScopedServiceAndReportsQueuedOrLocalState() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    let note = try store.createNote(bodyMarkdown: "Index this notebook")
    let executor = NoteGraphQLDocumentExecutor(service: GraphQLNoteGraphQLService(service: store))
    let response = await executor.execute(GraphQLDocumentRequest(query: """
      mutation($id:String!){rebuildNotebookSearchIndex(notebookId:$id){result{accepted status diagnostics}}}
      """, variables: ["id": .string(note.notebookId.rawValue)]))
    let payload = try XCTUnwrap(response.body["data"]?.asObject?["rebuildNotebookSearchIndex"]?.asObject)
    XCTAssertEqual(payload["result"]?.asObject?["accepted"], .bool(true))
    XCTAssertEqual(payload["result"]?.asObject?["status"], .string("local-only"))
  }
}
