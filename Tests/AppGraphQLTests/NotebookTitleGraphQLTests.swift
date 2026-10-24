import AppCore
import Foundation
import XCTest
@testable import AppGraphQL

final class NotebookTitleGraphQLTests: XCTestCase {
  func testRenameDocumentThroughGraphQLAndRejectInvalidTitle() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    let notebook = try store.createNotebook(title: "source.pdf")
    _ = try store.setNotebookReadOnly(notebookId: notebook.notebookId, readOnly: true)
    let executor = NoteGraphQLDocumentExecutor(service: GraphQLNoteGraphQLService(service: store))
    for title in ["My document", "   "] {
      let response = await executor.execute(GraphQLDocumentRequest(query: """
        mutation($notebookId:String!,$title:String!){renameNotebook(notebookId:$notebookId,title:$title){result{accepted status} notebook{title readOnly}}}
        """, variables: ["notebookId": .string(notebook.notebookId.rawValue), "title": .string(title)]))
      let payload = try XCTUnwrap(response.body["data"]?.asObject?["renameNotebook"]?.asObject)
      XCTAssertEqual(payload["result"]?.asObject?["accepted"], .bool(title == "My document"))
    }
    XCTAssertEqual(try store.getNotebook(notebook.notebookId).title, "My document")
  }
}
