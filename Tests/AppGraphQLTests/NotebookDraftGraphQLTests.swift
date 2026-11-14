import AppCore
import Foundation
import XCTest
@testable import AppGraphQL

final class NotebookDraftGraphQLTests: XCTestCase {
  func testSaveDraftMutationReconcilesNotesAndAllowsEmptyNextNote() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    let service = GraphQLNoteGraphQLService(service: store)
    let initial = await service.ingestNotebookPages(GraphQLIngestNotebookPagesInput(
      idempotencyKey: "draft-with-empty-note", title: "F", allowEmptyPages: true,
      pages: [.init(bodyMarkdown: "F", readOnly: false), .init(bodyMarkdown: "", readOnly: false)]))
    XCTAssertTrue(initial.result.accepted)
    let notebook = try XCTUnwrap(initial.notebook)
    let executor = NoteGraphQLDocumentExecutor(service: GraphQLNoteGraphQLService(service: store))
    let response = await executor.execute(GraphQLDocumentRequest(query: """
      mutation($input:SaveNotebookDraftInput!){saveNotebookDraft(input:$input){result{accepted diagnostics} notebook{notebookId title}}}
      """, variables: ["input": .object(["notebookId": .string(notebook.notebookId.rawValue), "title": .string("Field notebook"),
        "bodies": .array([.string("Field notebook"), .string("")])])]))
    let payload = try XCTUnwrap(response.body["data"]?.asObject?["saveNotebookDraft"]?.asObject)
    XCTAssertEqual(payload["result"]?.asObject?["accepted"], .bool(true))
    XCTAssertEqual(try store.listNotes(notebookId: notebook.notebookId).map(\.bodyMarkdown), ["Field notebook", ""])
  }
}
