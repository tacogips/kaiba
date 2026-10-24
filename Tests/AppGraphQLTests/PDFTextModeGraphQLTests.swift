import AppCore
import Foundation
import XCTest
@testable import AppGraphQL

final class PDFTextModeGraphQLTests: XCTestCase {
  func testStoredDefaultImportOverrideAndPlainTextQuery() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    _ = try store.setAppSetting(key: "web", valueJSON: #"{"pdfTextMode":"ocr-only"}"#)
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("AppCoreTests/Fixtures/sample.pdf")
    let recognizer = ModeOCRRecognizer()
    let api = GraphQLNoteGraphQLService(service: store, documentPageRecognizer: recognizer)
    let encoded = try Data(contentsOf: source).base64EncodedString()
    let forced = await api.importDocument(.init(filename: "forced.pdf", contentBase64: encoded, maximumOCRPages: "all"))
    XCTAssertTrue(forced.result.accepted)
    XCTAssertEqual(recognizer.calls, 2)
    let native = await api.importDocument(.init(filename: "native.pdf", contentBase64: encoded, maximumOCRPages: "0", textExtractionMode: "prefer-pdf-text"))
    XCTAssertTrue(native.result.accepted)
    XCTAssertEqual(recognizer.calls, 2)
    let notebook = try XCTUnwrap(native.notebook)
    let page = try XCTUnwrap(store.listNotes(notebookId: notebook.notebookId).first)
    let executor = NoteGraphQLDocumentExecutor(service: api)
    let response = await executor.execute(GraphQLDocumentRequest(query: """
      query($id:String!){documentPageText(noteId:$id){result{accepted} value{pageNumber text textSource ocrState}}}
      """, variables: ["id": .string(page.noteId.rawValue)]))
    let payload = try XCTUnwrap(response.body["data"]?.asObject?["documentPageText"]?.asObject)
    XCTAssertEqual(payload["result"]?.asObject?["accepted"], .bool(true))
    XCTAssertEqual(payload["value"]?.asObject?["textSource"], .string("pdf-text"))
    XCTAssertTrue(try XCTUnwrap(payload["value"]?.asObject?["text"]?.asString).contains("Fixture Document"))
    let invalid = await api.importDocument(.init(filename: "invalid.pdf", contentBase64: encoded, textExtractionMode: "invalid"))
    XCTAssertFalse(invalid.result.accepted)
  }
}

private final class ModeOCRRecognizer: DocumentPageRecognizing, @unchecked Sendable {
  var calls = 0
  func recognize(imageURL: URL) throws -> String { calls += 1; return "Forced OCR\n\nSearch text" }
}
