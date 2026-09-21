import Foundation
import AppCore
import XCTest
@testable import AppGraphQL

final class DocumentUploadGraphQLTests: XCTestCase {
  func testUploadPreservesOriginalAndZeroPageLimitThenAllowsManualOCR() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    let executor = NoteGraphQLDocumentExecutor(service: GraphQLNoteGraphQLService(
      service: service, documentPageRecognizer: UploadRecognizer()
    ))
    let query = GraphQLDocumentRequest(query: """
      mutation($input:ImportDocumentInput!){importDocument(input:$input){result{accepted status} notebook{notebookId title}}}
      """, variables: ["input": .object([
        "filename": .string("page.png"), "contentBase64": .string(Data("page bytes".utf8).base64EncodedString()),
        "maximumOCRPages": .string("0"), "title": .string("Uploaded book")
      ])])
    let result = await executor.execute(query)
    let payload = try XCTUnwrap(result.body["data"]?.asObject?["importDocument"]?.asObject)
    XCTAssertEqual(payload["result"]?.asObject?["accepted"], .bool(true))
    let id = NotebookID(try XCTUnwrap(payload["notebook"]?.asObject?["notebookId"]?.asString))
    let note = try XCTUnwrap(service.listNotes(notebookId: id).first)
    XCTAssertEqual(note.bodyMarkdown, "")
    let origin = try XCTUnwrap(service.listFiles(noteId: note.noteId).first { $0.role == .sourcePageImage })
    XCTAssertEqual(try service.resolveFileContent(fileId: origin.file.fileId), Data("page bytes".utf8))
    let completed = await executor.service.recognizeDocumentPage(noteId: note.noteId)
    XCTAssertTrue(completed.result.accepted)
    XCTAssertEqual(try service.getNote(note.noteId).bodyMarkdown, "Recognized upload")
  }

  func testRejectsInvalidFilenamePayloadAndLimitWithoutCreatingNotebook() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    let api = GraphQLNoteGraphQLService(service: service, documentPageRecognizer: UploadRecognizer())
    let before = try service.listNotebooks().count
    for input in [
      GraphQLDocumentImportInput(filename: "../page.png", contentBase64: "YWJj", maximumOCRPages: "0"),
      GraphQLDocumentImportInput(filename: "page.png", contentBase64: "invalid!", maximumOCRPages: "0"),
      GraphQLDocumentImportInput(filename: "page.png", contentBase64: "YWJj", maximumOCRPages: "-1")
    ] {
      let response = await api.importDocument(input)
      XCTAssertFalse(response.result.accepted)
    }
    XCTAssertEqual(try service.listNotebooks().count, before)
  }
}

private struct UploadRecognizer: DocumentPageRecognizing {
  func recognize(imageURL: URL) throws -> String { "Recognized upload" }
}
