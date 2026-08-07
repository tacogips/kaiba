import Foundation

import AppGraphQL
import AppCore
import XCTest

final class NoteGraphQLS3SecurityTests: XCTestCase {
  func testDocumentExecutorSanitizesUnexpectedMigrationFailureDetails() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(
      service: service,
      allowRawS3ProfileInput: true,
      rawS3EnvironmentAllowlist: ["PUBLIC_ACCESS_KEY", "SECRET_ENV_SHOULD_NOT_LEAK"]
    )
    let created = await service.createNote(GraphQLCreateNoteInput(bodyMarkdown: "# Missing Secret\n\nBody"))
    let noteId = try XCTUnwrap(created.note?.noteId)
    let attachment = try service.service.attachFile(
      noteId: noteId,
      data: Data("missing secret migration".utf8),
      mediaType: "text/plain"
    )

    let migrated = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation MigrateFile($input: MigrateNoteFileStorageInput!) {
        migrateNoteFileStorage(input: $input) { result { accepted status diagnostics } failures { fileId message } }
      }
      """,
      variables: [
        "input": .object([
          "fileId": .string(attachment.file.fileId),
          "s3Endpoint": .string("https://s3.example.test"),
          "s3Region": .string("ap-northeast-1"),
          "s3Bucket": .string("notes"),
          "s3AccessKeyIdEnv": .string("PUBLIC_ACCESS_KEY"),
          "s3SecretAccessKeyEnv": .string("SECRET_ENV_SHOULD_NOT_LEAK")
        ])
      ],
      operationName: "MigrateFile",
      environment: ["PUBLIC_ACCESS_KEY": "access-key"]
    ))

    XCTAssertNil(migrated.body["errors"])
    let payload = try graphQLPayload(migrated.body, field: "migrateNoteFileStorage")
    let failures = try arrayValue(payload["failures"], field: "migrateNoteFileStorage.failures")
    let firstFailure = try objectValue(failures.first, field: "migrateNoteFileStorage.failures[0]")
    let message = try stringValue(firstFailure["message"], field: "failures[0].message")
    XCTAssertEqual(message, "note operation failed")
    XCTAssertFalse(message.contains("SECRET_ENV_SHOULD_NOT_LEAK"))
  }

  func testDocumentExecutorRejectsRawS3EnvironmentNamesOutsideAllowlist() async throws {
    let service = try makeNoteGraphQLService()
    let executor = NoteGraphQLDocumentExecutor(service: service, allowRawS3ProfileInput: true)
    let created = await service.createNote(GraphQLCreateNoteInput(bodyMarkdown: "# Raw Env\n\nBody"))
    let noteId = try XCTUnwrap(created.note?.noteId)
    let attachment = try service.service.attachFile(
      noteId: noteId,
      data: Data("raw env migration".utf8),
      mediaType: "text/plain"
    )

    let migrated = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation MigrateFile($input: MigrateNoteFileStorageInput!) {
        migrateNoteFileStorage(input: $input) { result { accepted status } failures { fileId message } }
      }
      """,
      variables: [
        "input": .object([
          "fileId": .string(attachment.file.fileId),
          "s3Endpoint": .string("https://s3.example.test"),
          "s3Region": .string("ap-northeast-1"),
          "s3Bucket": .string("notes"),
          "s3AccessKeyIdEnv": .string("GITHUB_TOKEN"),
          "s3SecretAccessKeyEnv": .string("GITHUB_TOKEN")
        ])
      ],
      operationName: "MigrateFile",
      environment: ["GITHUB_TOKEN": "secret"]
    ))

    let payload = try graphQLPayload(migrated.body, field: "migrateNoteFileStorage")
    let failures = try arrayValue(payload["failures"], field: "migrateNoteFileStorage.failures")
    let firstFailure = try objectValue(failures.first, field: "migrateNoteFileStorage.failures[0]")
    let message = try stringValue(firstFailure["message"], field: "failures[0].message")
    XCTAssertTrue(message.contains("raw S3 environment variable is not allowed"))
    XCTAssertFalse(message.contains("GITHUB_TOKEN"))
  }

  private func makeNoteGraphQLService(function: String = #function) throws -> GraphQLNoteGraphQLService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp", isDirectory: true)
      .appendingPathComponent("note-graphql-s3-security-\(function)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    return GraphQLNoteGraphQLService(service: service)
  }

  private func graphQLPayload(_ body: JSONObject, field: String) throws -> JSONObject {
    let data = try objectValue(body["data"], field: "data")
    return try objectValue(data[field], field: field)
  }

  private func objectValue(_ value: JSONValue?, field: String) throws -> JSONObject {
    guard case let .object(object) = value else {
      throw XCTSkip("Expected object at \(field), got \(String(describing: value))")
    }
    return object
  }

  private func arrayValue(_ value: JSONValue?, field: String) throws -> [JSONValue] {
    guard case let .array(array) = value else {
      throw XCTSkip("Expected array at \(field), got \(String(describing: value))")
    }
    return array
  }

  private func stringValue(_ value: JSONValue?, field: String) throws -> String {
    guard case let .string(string) = value else {
      throw XCTSkip("Expected string at \(field), got \(String(describing: value))")
    }
    return string
  }
}
