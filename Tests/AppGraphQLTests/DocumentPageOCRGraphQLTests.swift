import Foundation
import AppCore
import XCTest
@testable import AppGraphQL

final class DocumentPageOCRGraphQLTests: XCTestCase {
  func testMutationRecognizesStoredOriginalAndRejectsRepeat() async throws {
    let fixture = try makeFixture()
    let first = await fixture.executor.execute(request(noteId: fixture.note.noteId))
    let payload = try XCTUnwrap(first.body["data"]?.asObject?["recognizeDocumentPage"]?.asObject)
    XCTAssertEqual(payload["result"]?.asObject?["accepted"], .bool(true))
    XCTAssertEqual(payload["note"]?.asObject?["bodyMarkdown"], .string(""))
    XCTAssertEqual(
      try fixture.executor.service.service.driver.withDatabase {
        try $0.query("SELECT search_text FROM notes WHERE note_id = ?", bindings: [.id(fixture.note.noteId)]).first?["search_text"]
      },
      "# Page recognized"
    )
    let json = try XCTUnwrap(payload["note"]?.asObject?["metaJSON"]?.asString)
    XCTAssertEqual(try JSONValue(parsing: json).asObject?["documentPage"]?.asObject?["ocrState"], .string("complete"))
    let second = await fixture.executor.execute(request(noteId: fixture.note.noteId))
    XCTAssertEqual(second.body["data"]?.asObject?["recognizeDocumentPage"]?.asObject?["result"]?.asObject?["status"], .string("conflict"))
  }

  func testForeignUserCannotRecognizeAnotherUsersPage() async throws {
    let fixture = try makeFixture()
    let other = try fixture.executor.service.service.createUser(email: "other@example.com", displayName: "Other")
    var query = request(noteId: fixture.note.noteId)
    query.actingUserId = other.userId
    let response = await fixture.executor.execute(query)
    let result = response.body["data"]?.asObject?["recognizeDocumentPage"]?.asObject?["result"]?.asObject
    XCTAssertEqual(result?["accepted"], .bool(false))
    XCTAssertEqual(result?["status"], .string("not_found"))
    XCTAssertEqual(try fixture.executor.service.service.getNote(fixture.note.noteId).bodyMarkdown, "")
  }

  private func request(noteId: NoteID) -> GraphQLDocumentRequest {
    GraphQLDocumentRequest(query: """
      mutation OCR($noteId: String!) {
        recognizeDocumentPage(noteId: $noteId) {
          result { accepted status diagnostics }
          note { noteId bodyMarkdown metaJSON }
        }
      }
      """, variables: ["noteId": .id(noteId)])
  }

  private func makeFixture() throws -> (executor: NoteGraphQLDocumentExecutor, note: Note) {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/AppGraphQLTests/DocumentPageOCR-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("image.png")
    try Data("original image".utf8).write(to: source)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    let recognizer = GraphQLPageRecognizer()
    let imported = try service.importDocumentPages(at: source.path, processor: DocumentPageProcessor(recognizer: recognizer), maximumOCRPages: 0)
    return (NoteGraphQLDocumentExecutor(service: GraphQLNoteGraphQLService(service: service, documentPageRecognizer: recognizer)), try XCTUnwrap(imported.notes.first))
  }
}

private struct GraphQLPageRecognizer: DocumentPageRecognizing {
  func recognize(imageURL: URL) throws -> String {
    XCTAssertEqual(try Data(contentsOf: imageURL), Data("original image".utf8))
    return "# Page recognized"
  }
}
