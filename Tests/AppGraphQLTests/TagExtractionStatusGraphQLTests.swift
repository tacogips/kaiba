import AppCore
import Foundation
import XCTest
@testable import AppGraphQL

final class TagExtractionStatusGraphQLTests: XCTestCase {
  func testCompletedEmptyProposalAndForeignNoteStatus() async throws {
    let (service, note) = try fixture(reply: "[]")
    XCTAssertEqual(service.tagExtractionStatus(noteId: note.noteId).status, "none")
    _ = await service.requestTagExtraction(.init(noteId: note.noteId))
    await service.service.drainAutoActionDispatches()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let query = GraphQLDocumentRequest(query: """
      query($id:String!){tagExtractionStatus(noteId:$id){result{accepted status} status}}
      """, variables: ["id": .id(note.noteId)])
    let result = await executor.execute(query)
    let payload = result.body["data"]?.asObject?["tagExtractionStatus"]?.asObject
    XCTAssertEqual(payload?["result"]?.asObject?["accepted"], .bool(true))
    XCTAssertEqual(payload?["status"], .string("completed"))
    XCTAssertTrue(try service.service.getNote(note.noteId).tags.isEmpty)
    let other = try service.service.createUser(email: "status-other@example.com", displayName: "Other")
    var foreign = query
    foreign.actingUserId = other.userId
    let rejected = await executor.execute(foreign)
    XCTAssertEqual(rejected.body["data"]?.asObject?["tagExtractionStatus"]?.asObject?["result"]?.asObject?["status"], .string("not_found"))
  }

  func testProviderFailureIsRetryingWithoutExposingItsReply() async throws {
    let (service, note) = try fixture(reply: "private provider detail")
    _ = await service.requestTagExtraction(.init(noteId: note.noteId))
    await service.service.drainAutoActionDispatches()
    let status = service.tagExtractionStatus(noteId: note.noteId)
    XCTAssertEqual(status.status, "retrying")
    XCTAssertTrue(status.result.diagnostics.isEmpty)
  }

  private func fixture(reply: String) throws -> (GraphQLNoteGraphQLService, Note) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kaiba-tag-status-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    var store = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    let note = try store.createNote(bodyMarkdown: "Ada Lovelace in London.")
    store.autoActionDispatcher = KaibaAutoActionDispatcher(service: store, invoker: TagStatusInvoker(reply: reply))
    return (GraphQLNoteGraphQLService(service: store), note)
  }
}

private struct TagStatusInvoker: AgentInvoking {
  var reply: String
  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult { .init(markdown: reply) }
}
