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

extension NotebookDraftGraphQLTests {
  func testLargeInitialNotebookAndMiddleSplitRetainExistingNotesThroughGraphQL() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    let service = GraphQLNoteGraphQLService(service: store)
    let bodies = (1...1001).map { "Section \($0)" }
    let initial = await service.ingestNotebookPages(GraphQLIngestNotebookPagesInput(
      idempotencyKey: "large-draft-1001-sections", title: "Large notebook", allowEmptyPages: true,
      pages: bodies.map { .init(bodyMarkdown: $0, readOnly: false) }))
    XCTAssertTrue(initial.result.accepted, initial.result.diagnostics.joined(separator: "; "))
    let notebook = try XCTUnwrap(initial.notebook)
    let originals = try store.listNotes(notebookId: notebook.notebookId, limit: 2000)
    XCTAssertEqual(originals.count, 1001)
    var changed = bodies
    changed[499] = "Edited section 500"
    changed.insert("Split continuation", at: 500)
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let response = await executor.execute(GraphQLDocumentRequest(query: """
      mutation($input:SaveNotebookDraftInput!){saveNotebookDraft(input:$input){result{accepted diagnostics} notebook{notebookId}}}
      """, variables: ["input": .object([
        "notebookId": .string(notebook.notebookId.rawValue), "title": .string("Large notebook"),
        "bodies": .array(changed.map(JSONValue.string))
      ])]))
    let payload = try XCTUnwrap(response.body["data"]?.asObject?["saveNotebookDraft"]?.asObject)
    XCTAssertEqual(payload["result"]?.asObject?["accepted"], .bool(true))
    let saved = try store.listNotes(notebookId: notebook.notebookId, limit: 2000)
    XCTAssertEqual(saved.count, 1002)
    XCTAssertEqual(saved[499].noteId, originals[499].noteId)
    XCTAssertEqual(saved[501].noteId, originals[500].noteId)
    XCTAssertEqual(saved.last?.noteId, originals.last?.noteId)
  }
}
