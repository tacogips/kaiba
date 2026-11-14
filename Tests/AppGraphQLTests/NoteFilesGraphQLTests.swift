import Foundation

import AppCore
import XCTest
@testable import AppGraphQL

final class NoteFilesGraphQLTests: XCTestCase {
  func testNoteFilesQueryProjectsAttachmentsInStoreOrder() async throws {
    let service = try makeService()
    let note = try service.service.createNote(bodyMarkdown: "# Illustrated\nBody.")
    _ = try service.service.attachFile(
      noteId: note.noteId,
      data: Data("second".utf8),
      role: .related,
      mediaType: "image/jpeg",
      originalFilename: "second.jpg",
      position: 1
    )
    _ = try service.service.attachFile(
      noteId: note.noteId,
      data: Data([0x89, 0x50, 0x4E, 0x47]),
      role: .sourcePageImage,
      mediaType: "image/png",
      originalFilename: "first.png",
      position: 0
    )

    let executor = NoteGraphQLDocumentExecutor(service: service)
    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      query Files($noteId: String!) {
        noteFiles(noteId: $noteId) {
          result { accepted status }
          value { noteId role position file { fileId mediaType byteSize originalFilename } }
        }
      }
      """,
      variables: ["noteId": .string(note.noteId.rawValue)],
      operationName: "Files"
    ))

    let payload = try graphQLPayload(response.body, field: "noteFiles")
    XCTAssertEqual(try objectValue(payload["result"], field: "noteFiles.result")["accepted"], .bool(true))
    let values = try arrayValue(payload["value"], field: "noteFiles.value")
    XCTAssertEqual(values.count, 2)

    let first = try objectValue(values[0], field: "noteFiles.value[0]")
    XCTAssertEqual(first["noteId"], .string(note.noteId.rawValue))
    XCTAssertEqual(first["role"], .string("source-page-image"))
    XCTAssertEqual(first["position"], .integer(0))
    let firstFile = try objectValue(first["file"], field: "noteFiles.value[0].file")
    XCTAssertEqual(firstFile["mediaType"], .string("image/png"))
    XCTAssertEqual(firstFile["originalFilename"], .string("first.png"))
    XCTAssertEqual(firstFile["byteSize"], .integer(4))
    guard case let .string(fileId)? = firstFile["fileId"] else {
      return XCTFail("noteFiles.value[0].file.fileId must be a string")
    }
    XCTAssertFalse(fileId.isEmpty)

    let second = try objectValue(values[1], field: "noteFiles.value[1]")
    XCTAssertEqual(second["role"], .string("related"))
    XCTAssertEqual(second["position"], .integer(1))
  }

  func testNoteFilesQueryReportsNotFoundForUnknownNote() async throws {
    let service = try makeService()
    let missing = await service.noteFiles(noteId: NoteID("note-missing"))
    XCTAssertFalse(missing.result.accepted)
    XCTAssertEqual(missing.result.status, "not_found")
    XCTAssertNil(missing.value)
  }

  private func makeService(function: String = #function) throws -> GraphQLNoteGraphQLService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/AppGraphQLTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return GraphQLNoteGraphQLService(
      service: try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    )
  }

  private func graphQLPayload(_ body: JSONObject, field: String) throws -> JSONObject {
    let data = try objectValue(body["data"], field: "data")
    return try objectValue(data[field], field: field)
  }

  private func objectValue(_ value: JSONValue?, field: String) throws -> JSONObject {
    guard case let .object(object)? = value else {
      throw NSError(domain: "NoteFilesGraphQLTests", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "expected object at \(field)"
      ])
    }
    return object
  }

  private func arrayValue(_ value: JSONValue?, field: String) throws -> [JSONValue] {
    guard case let .array(values)? = value else {
      throw NSError(domain: "NoteFilesGraphQLTests", code: 2, userInfo: [
        NSLocalizedDescriptionKey: "expected array at \(field)"
      ])
    }
    return values
  }
}
