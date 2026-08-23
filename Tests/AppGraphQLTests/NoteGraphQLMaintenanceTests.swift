import Foundation

import AppCore
import XCTest
@testable import AppGraphQL

/// Contract round-trips of the store-maintenance surface: `checkNoteStore`
/// and `optimizeNoteStore` (the GraphQL face of `kaiba db check|optimize`).
final class NoteGraphQLMaintenanceTests: XCTestCase {
  func testCheckNoteStoreReportsHealthyStore() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    _ = try service.service.createNote(bodyMarkdown: "# Audited\nbody")

    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation {
        checkNoteStore {
          result { accepted status }
          schemaVersion healthy integrityMessages foreignKeyViolations
          searchIndexHealthy notesMissingFromSearchIndex
          orphanedSearchIndexRows unreferencedFiles searchIndexRepaired
        }
      }
      """
    ))
    XCTAssertTrue(response.handled)
    let payload = try graphQLPayload(response.body, field: "checkNoteStore")
    XCTAssertEqual(try resultObject(payload)["status"], .string("ok"))
    XCTAssertEqual(payload["healthy"], .bool(true))
    XCTAssertEqual(payload["schemaVersion"], .integer(Int64(NoteStoreSchema.currentVersion)))
    XCTAssertEqual(payload["integrityMessages"], .array([.string("ok")]))
    XCTAssertEqual(payload["searchIndexRepaired"], .bool(false))
  }

  func testCheckNoteStoreRepairFlagRebuildsDriftedSearchIndex() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let note = try service.service.createNote(bodyMarkdown: "# Drifted\nindexable body")
    try service.service.driver.withDatabase { database in
      try database.execute(
        "DELETE FROM note_fts_map WHERE note_id = ?",
        bindings: [.id(note.noteId)]
      )
    }

    let repaired = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation Repair($repair: Boolean) {
        checkNoteStore(repair: $repair) {
          result { status }
          healthy searchIndexRepaired notesMissingFromSearchIndex
        }
      }
      """,
      variables: ["repair": .bool(true)]
    ))
    XCTAssertTrue(repaired.handled)
    let payload = try graphQLPayload(repaired.body, field: "checkNoteStore")
    XCTAssertEqual(payload["healthy"], .bool(true))
    XCTAssertEqual(payload["searchIndexRepaired"], .bool(true))
    XCTAssertEqual(payload["notesMissingFromSearchIndex"], .array([]))
  }

  func testOptimizeNoteStoreVacuumReportsSizes() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    _ = try service.service.createNote(bodyMarkdown: "# Compact me\nbody")

    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation {
        optimizeNoteStore(vacuum: true) {
          result { accepted status }
          vacuumed bytesBefore bytesAfter freelistPagesAfter
        }
      }
      """
    ))
    XCTAssertTrue(response.handled)
    let payload = try graphQLPayload(response.body, field: "optimizeNoteStore")
    XCTAssertEqual(try resultObject(payload)["status"], .string("ok"))
    XCTAssertEqual(payload["vacuumed"], .bool(true))
    XCTAssertEqual(payload["freelistPagesAfter"], .integer(0))
    guard case let .integer(bytesAfter)? = payload["bytesAfter"] else {
      return XCTFail("expected integer bytesAfter")
    }
    XCTAssertGreaterThan(bytesAfter, 0)
  }

  private func makeNoteGraphQLService(function: String = #function) throws -> GraphQLNoteGraphQLService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/AppGraphQLTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let noteService = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    return GraphQLNoteGraphQLService(service: noteService)
  }

  private func graphQLPayload(_ body: JSONObject, field: String) throws -> JSONObject {
    guard case let .object(data)? = body["data"], case let .object(payload)? = data[field] else {
      XCTFail("expected data.\(field) object")
      return [:]
    }
    return payload
  }

  private func resultObject(_ payload: JSONObject) throws -> JSONObject {
    guard case let .object(object)? = payload["result"] else {
      XCTFail("expected result object")
      return [:]
    }
    return object
  }
}
