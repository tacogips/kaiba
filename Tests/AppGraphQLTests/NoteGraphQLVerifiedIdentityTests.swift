import Foundation

import AppCore
import XCTest
@testable import AppGraphQL

/// Verifies that on the authenticated HTTP note API the audit-attribution
/// identity is always the bearer-verified client and cannot be overridden by
/// request input, and that migration diagnostics are redacted (theme T2,
/// findings F21/F26).
final class NoteGraphQLVerifiedIdentityTests: XCTestCase {
  func testAuthenticatedApplyTagsRejectsExplicitAssignedBy() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let note = try service.service.createNote(bodyMarkdown: "# Identity\n\nBody")

    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation ApplyTags($input: ApplyNoteTagsInput!) {
        applyNoteTags(input: $input) { result { accepted } }
      }
      """,
      variables: [
        "input": .object([
          "noteId": .string(note.noteId),
          "tags": .array([.object(["name": .string("topic")])]),
          "assignedBy": .string("client:other")
        ])
      ],
      operationName: "ApplyTags",
      authenticatedClientId: "abc123"
    ))

    XCTAssertTrue(response.handled)
    let message = try errorMessage(response)
    XCTAssertTrue(message.contains("invalidVariable"), message)
    XCTAssertTrue(message.contains("assignedBy"), message)
  }

  func testAuthenticatedApplyTagsPersistsVerifiedIdentity() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let note = try service.service.createNote(bodyMarkdown: "# Identity\n\nBody")

    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation ApplyTags($input: ApplyNoteTagsInput!) {
        applyNoteTags(input: $input) { result { accepted } }
      }
      """,
      variables: [
        "input": .object([
          "noteId": .string(note.noteId),
          "tags": .array([.object(["name": .string("topic")])])
        ])
      ],
      operationName: "ApplyTags",
      authenticatedClientId: "abc123"
    ))

    XCTAssertTrue(response.handled)
    XCTAssertNil(response.body["errors"])

    let stored = try service.service.getNote(note.noteId)
    let assignedBy = stored.tags.first(where: { $0.tag.name == "topic" })?.assignedBy
    XCTAssertEqual(assignedBy, "client:abc123")
  }

  /// A distinctive substring an S3 upload error's description carries (e.g. a
  /// signed endpoint path). It must never reach a client-visible response body
  /// through either the `failures` list or the control-plane `diagnostics`.
  /// Uses no `/` so the assertion is not defeated by JSON forward-slash escaping
  /// (`\/`); a slashed URL below still confirms the whole raw string is dropped.
  private static let leakToken = "AKIA-LEAK-TOKEN-ENDPOINT-secret-endpoint"
  private static let leakSecret = "s3.internal.example/\(leakToken)"

  func testMigrateAllNoteFilesFailureDiagnosticsAreRedacted() async throws {
    let service = try makeNoteGraphQLService()
    // A configured profile whose uploads fail with an error whose description
    // carries a secret-looking substring makes every file migration report a
    // per-file failure; both the failures list and the control-plane diagnostics
    // must equal the fixed redacted constant, never the raw error text.
    let profile = S3StorageProfile(
      name: "backup",
      endpoint: URL(string: "https://s3.example.test")!,
      region: "ap-northeast-1",
      bucket: "notes",
      accessKeyId: "access-key",
      secretAccessKey: "secret-key"
    )
    let executor = NoteGraphQLDocumentExecutor(
      service: service,
      s3HTTPClient: SecretLeakingS3HTTPClient(secret: Self.leakSecret),
      s3Profiles: [profile]
    )
    let note = try service.service.createNote(bodyMarkdown: "# File\n\nBody")
    _ = try service.service.attachFile(
      noteId: note.noteId,
      data: Data("payload".utf8),
      mediaType: "text/plain",
      originalFilename: "note.txt"
    )

    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation MigrateAll($input: MigrateAllNoteFilesInput!) {
        migrateAllNoteFiles(input: $input) {
          result { accepted status diagnostics }
          failures { fileId message }
        }
      }
      """,
      variables: ["input": .object(["s3ProfileName": .string("backup")])],
      operationName: "MigrateAll"
    ))

    XCTAssertTrue(response.handled)
    XCTAssertNil(response.body["errors"])
    let failures = try XCTUnwrap(arrayIfPresent(response.body, "data", "migrateAllNoteFiles", "failures"))
    XCTAssertFalse(failures.isEmpty)
    for failure in failures {
      guard case let .object(object) = failure, case let .string(message)? = object["message"] else {
        return XCTFail("expected a failure with a string message")
      }
      XCTAssertEqual(message, "note file migration failed")
    }

    let text = responseText(response.body)
    // `leakToken` carries no `/`, so it survives JSON forward-slash escaping and
    // catches the raw error text leaking into the client-selectable `diagnostics`.
    for leak in ["SELECT", "INSERT", "sqlite", ".db", "/tmp", "no such", "s3.example.test", "secret-key", Self.leakToken] {
      XCTAssertFalse(text.localizedCaseInsensitiveContains(leak), "leaked '\(leak)': \(text)")
    }
    // The control-plane diagnostics use the same redacted constant per file.
    XCTAssertTrue(text.contains("note file migration failed"), text)
  }

  // MARK: - helpers

  private func errorMessage(_ response: GraphQLDocumentExecutionResponse) throws -> String {
    guard case let .array(errors)? = response.body["errors"], let first = errors.first,
          case let .object(errorObject) = first, case let .string(message)? = errorObject["message"] else {
      XCTFail("expected an error message, got \(String(describing: response.body))")
      return ""
    }
    return message
  }

  private func responseText(_ body: JSONObject) -> String {
    guard let data = try? JSONEncoder().encode(JSONValue.object(body)),
          let text = String(data: data, encoding: .utf8) else {
      return ""
    }
    return text
  }

  private func arrayIfPresent(_ body: JSONObject, _ keys: String...) -> [JSONValue]? {
    var current: JSONValue = .object(body)
    for key in keys {
      guard case let .object(object) = current, let next = object[key] else {
        return nil
      }
      current = next
    }
    guard case let .array(values) = current else {
      return nil
    }
    return values
  }

  private func makeNoteGraphQLService(function: String = #function) throws -> GraphQLNoteGraphQLService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp", isDirectory: true)
      .appendingPathComponent("note-graphql-identity-\(function)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    return GraphQLNoteGraphQLService(service: service)
  }
}

/// Fails every upload by throwing an error whose description embeds a secret
/// substring, exercising the redaction of raw error text into response bodies.
private struct SecretLeakingS3HTTPClient: S3HTTPClient {
  struct UploadError: Error, CustomStringConvertible {
    let secret: String
    var description: String { "s3 upload rejected by \(secret)" }
  }

  let secret: String

  func send(_ request: S3HTTPRequest) throws -> S3HTTPResponse {
    throw UploadError(secret: secret)
  }
}
