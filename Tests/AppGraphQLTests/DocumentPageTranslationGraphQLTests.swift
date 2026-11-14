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
  func testScopedTranslationRequestJobAndVersionQueries() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let driver = try SQLiteNoteDatabaseDriver(noteRoot: root.path)
    let dispatcher = KaibaAutoActionDispatcher(
      service: try NoteService(driver: driver),
      invoker: GraphQLPageTranslationInvoker()
    )
    let store = try NoteService(driver: driver, autoActionDispatcher: dispatcher)
    let source = try store.createNotebookWithNotes(title: "Source", pages: [
      NotePageDraft(bodyMarkdown: "Page one"),
      NotePageDraft(bodyMarkdown: "Page two")
    ])
    let executor = NoteGraphQLDocumentExecutor(service: GraphQLNoteGraphQLService(service: store))

    let request = await executor.execute(GraphQLDocumentRequest(query: """
      mutation($input: RequestNotebookTranslationInput!) {
        requestNotebookTranslation(input: $input) { result { accepted } translationJobId status }
      }
      """, variables: ["input": .object([
        "notebookId": .string(source.notebook.notebookId.rawValue),
        "targetLanguage": .string("Japanese"),
        "pageStart": .integer(2),
        "pageEnd": .integer(2)
      ])]))
    let requested = try XCTUnwrap(request.body["data"]?.asObject?["requestNotebookTranslation"]?.asObject)
    XCTAssertEqual(requested["status"], .string("queued"))
    let jobId = try XCTUnwrap(requested["translationJobId"]?.asString)
    await store.drainAutoActionDispatches()

    let jobs = await executor.execute(GraphQLDocumentRequest(query: """
      query($id:String!){translationJobs(notebookId:$id){result{accepted} value{jobId targetLanguage pageStart pageEnd status errorMessage}}}
      """, variables: ["id": .string(source.notebook.notebookId.rawValue)]))
    let job = try XCTUnwrap(
      jobs.body["data"]?.asObject?["translationJobs"]?.asObject?["value"]?.asArray?.first?.asObject
    )
    XCTAssertEqual(job["jobId"], .string(jobId))
    XCTAssertEqual(job["targetLanguage"], .string("Japanese"))
    XCTAssertEqual(job["pageStart"], .integer(2))
    XCTAssertEqual(job["pageEnd"], .integer(2))
    XCTAssertEqual(job["status"], .string("completed"))

    let first = await executor.execute(GraphQLDocumentRequest(query: """
      query($id:String!){noteTranslations(noteId:$id){result{accepted} value{language}}}
      """, variables: ["id": .string(source.notes[0].noteId.rawValue)]))
    XCTAssertEqual(
      first.body["data"]?.asObject?["noteTranslations"]?.asObject?["value"]?.asArray,
      []
    )
    let response = await executor.execute(GraphQLDocumentRequest(query: """
      query($id:String!){noteTranslations(noteId:$id){result{accepted} value{noteId language body isCurrent updatedAt}}}
      """, variables: ["id": .string(source.notes[1].noteId.rawValue)]))
    let payload = try XCTUnwrap(response.body["data"]?.asObject?["noteTranslations"]?.asObject)
    XCTAssertEqual(payload["result"]?.asObject?["accepted"], .bool(true))
    let version = try XCTUnwrap(payload["value"]?.asArray?.first?.asObject)
    XCTAssertEqual(version["noteId"], .string(source.notes[1].noteId.rawValue))
    XCTAssertEqual(version["language"], .string("Japanese"))
    XCTAssertEqual(version["body"], .string("Translated page: Page two"))
    XCTAssertEqual(version["isCurrent"], .bool(true))
  }
}
