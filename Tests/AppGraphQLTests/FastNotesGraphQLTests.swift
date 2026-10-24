import AppCore
import Foundation
import XCTest
@testable import AppGraphQL

final class FastNotesGraphQLTests: XCTestCase {
  func testFeedQueryHasBoundedSearchablePagination() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    let note = try store.captureQuickMemo(bodyMarkdown: "FastFeedMarker")
    let executor = NoteGraphQLDocumentExecutor(service: GraphQLNoteGraphQLService(service: store))
    let response = await executor.execute(GraphQLDocumentRequest(query: """
      query($q:String){fastNotes(query:$q,limit:1,offset:0){result{accepted} value{noteId bodyMarkdown createdAt}}}
      """, variables: ["q": .string("fastfeedmarker")]))
    let payload = try XCTUnwrap(response.body["data"]?.asObject?["fastNotes"]?.asObject)
    XCTAssertEqual(payload["result"]?.asObject?["accepted"], .bool(true))
    XCTAssertEqual(payload["value"]?.asArray?.first?.asObject?["noteId"], .string(note.noteId.rawValue))
  }
}
