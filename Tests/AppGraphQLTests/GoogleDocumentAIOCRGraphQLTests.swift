import Foundation
import AppCore
import XCTest
@testable import AppGraphQL

final class GoogleDocumentAIOCRGraphQLTests: XCTestCase {
  func testGoogleGatewayCompletesDeferredPageThroughGraphQL() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try fixture(root: root, fails: false)
    let response = await fixture.executor.execute(request(noteId: fixture.note.noteId))
    let payload = try XCTUnwrap(response.body["data"]?.asObject?["recognizeDocumentPage"]?.asObject)
    XCTAssertEqual(payload["result"]?.asObject?["accepted"], .bool(true))
    XCTAssertEqual(payload["note"]?.asObject?["bodyMarkdown"], .string("右列。\n左列。"))
    XCTAssertEqual(try fixture.executor.service.service.listFiles(noteId: fixture.note.noteId).filter { $0.role == .sourcePageImage }.count, 1)
  }

  func testGoogleGatewayFailureKeepsPagePendingWithoutLeakingDiagnostic() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try fixture(root: root, fails: true)
    let response = await fixture.executor.execute(request(noteId: fixture.note.noteId))
    let result = response.body["data"]?.asObject?["recognizeDocumentPage"]?.asObject?["result"]?.asObject
    XCTAssertEqual(result?["accepted"], .bool(false))
    let persisted = try fixture.executor.service.service.getNote(fixture.note.noteId)
    XCTAssertEqual(persisted, fixture.note)
    XCTAssertFalse(String(describing: response.body).contains("private-document-and-key"))
  }

  private func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("document-ai-graphql-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func fixture(root: URL, fails: Bool) throws -> (executor: NoteGraphQLDocumentExecutor, note: Note) {
    let gateway = root.appendingPathComponent("gateway")
    let result = fails
      ? "echo private-document-and-key >&2\nexit 4"
      : "printf '%s' '{\"ok\":true,\"data\":{\"document\":{\"text\":\"右列。\\n左列。\",\"pages\":[{}]}}}'"
    try Data("#!/bin/sh\n/bin/cat >/dev/null\n\(result)\n".utf8).write(to: gateway)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gateway.path)
    let config = KaibaImportConfiguration(googleDocumentAI: .init(
      processorName: "projects/test/locations/us/processors/ocr", commandPath: gateway.path
    ))
    let recognizer = try config.makePageRecognizer(environment: ["GOOGLE_APPLICATION_CREDENTIALS_JSON": "fake"], executionMode: .served)
    let source = root.appendingPathComponent("page.png")
    try Data("original".utf8).write(to: source)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.appendingPathComponent("store").path))
    let imported = try service.importDocumentPages(at: source.path, processor: DocumentPageProcessor(recognizer: recognizer), maximumOCRPages: 0)
    return (NoteGraphQLDocumentExecutor(service: GraphQLNoteGraphQLService(service: service, documentPageRecognizer: recognizer)), try XCTUnwrap(imported.notes.first))
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
}
