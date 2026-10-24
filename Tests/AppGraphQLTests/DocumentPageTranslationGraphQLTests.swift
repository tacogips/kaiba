import AppCore
import Foundation
import XCTest
@testable import AppGraphQL

private struct GraphQLPageTranslationInvoker: AgentInvoking {
  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    AgentInvocationResult(markdown: "Translated page: " + (request.turns.last?.markdown ?? ""))
  }
}

final class DocumentPageTranslationGraphQLTests: XCTestCase {
  func testScopedTranslationInputAndLinkedVersionQuery() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    let source = try store.createNotebookWithNotes(title: "Source", pages: [
      NotePageDraft(bodyMarkdown: "", searchText: "Native PDF page one"),
      NotePageDraft(bodyMarkdown: "", searchText: "Native PDF page two")
    ])
    let input = try JSONDecoder().decode(GraphQLRequestNotebookTranslationInput.self, from: Data("""
      {"notebookId":"\(source.notebook.notebookId)","targetLanguage":"Japanese","pageStart":2,"pageEnd":2}
      """.utf8))
    XCTAssertEqual(input.pageStart, 2)
    XCTAssertEqual(input.pageEnd, 2)
    let pending = try store.startNotebookTranslation(sourceNotebookId: input.notebookId,
      targetLanguage: input.targetLanguage, pageStart: input.pageStart, pageEnd: input.pageEnd)
    _ = try await AITranslationService(service: store, invoker: GraphQLPageTranslationInvoker()).run(
      translationNotebookId: pending.notebookId)
    let executor = NoteGraphQLDocumentExecutor(service: GraphQLNoteGraphQLService(service: store))
    let response = await executor.execute(GraphQLDocumentRequest(query: """
      query($id:String!){documentPageTranslations(noteId:$id){result{accepted} value{noteId notebookId sourceNoteId targetLanguage text}}}
      """, variables: ["id": .string(source.notes[1].noteId.rawValue)]))
    let payload = try XCTUnwrap(response.body["data"]?.asObject?["documentPageTranslations"]?.asObject)
    XCTAssertEqual(payload["result"]?.asObject?["accepted"], .bool(true))
    let version = try XCTUnwrap(payload["value"]?.asArray?.first?.asObject)
    XCTAssertEqual(version["sourceNoteId"], .string(source.notes[1].noteId.rawValue))
    XCTAssertEqual(version["targetLanguage"], .string("Japanese"))
    XCTAssertTrue(version["text"]?.asString?.contains("Native PDF page two") == true)
  }
}
