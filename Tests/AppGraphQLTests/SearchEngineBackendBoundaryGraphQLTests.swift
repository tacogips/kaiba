import Foundation

import AppCore
import AppGraphQL
import XCTest

final class SearchEngineBackendBoundaryGraphQLTests: XCTestCase {
  func testSchemaAndSettingsExposeDescriptorWithoutEngineURL() async throws {
    let schemaLine = "type SearchEngineAdapterDescriptor { kind: String!, displayName: String!, authModes: [String!]! }"
    XCTAssertTrue(GraphQLContractProjector.schemaContract.contains(schemaLine))
    XCTAssertFalse(GraphQLContractProjector.schemaContract.contains("defaultURL"))

    let service = try makeService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let response = await run(
      executor,
      "query { searchEngineSettings { value { adapters { kind displayName authModes } } } }"
    )
    let adapters = try array(response, ["data", "searchEngineSettings", "value", "adapters"])
    let adapter = try XCTUnwrap(adapters.first)
    XCTAssertEqual(try string(adapter, ["kind"]), "meilisearch")
    XCTAssertEqual(try string(adapter, ["displayName"]), "Meilisearch")
    XCTAssertEqual(try stringArray(adapter, ["authModes"]), ["none", "apiKey"])
  }

  func testDefaultURLSelectionIsRejected() async throws {
    let service = try makeService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let result = await executor.execute(GraphQLDocumentRequest(
      query: "query { searchEngineSettings { value { adapters { defaultURL } } } }"
    ))

    let data = try object(try value(result.body, ["data"]))
    XCTAssertEqual(data["searchEngineSettings"], .null)
    let errors = try array(result.body, ["errors"])
    let error = try XCTUnwrap(errors.first)
    let message = try string(error, ["message"])
    XCTAssertTrue(message.contains("invalidSelection"))
    XCTAssertTrue(message.contains("defaultURL"))
  }

  func testSettingsResponseDoesNotExposeEnvironmentEngineURL() async throws {
    let service = try makeService()
    service.service.searchEngineSlot.setEnvironment([
      "KAIBA_MEILISEARCH_URL": "https://engine-only.internal"
    ])
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let response = await run(
      executor,
      "query { searchEngineSettings { value { adapters { kind displayName authModes } } } }"
    )

    XCTAssertFalse(try serializedResponse(response).contains("engine-only.internal"))
  }

  private func makeService() throws -> GraphQLNoteGraphQLService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/SearchEngineBackendBoundaryGraphQLTests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return GraphQLNoteGraphQLService(service: try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path)))
  }

  private func run(_ executor: NoteGraphQLDocumentExecutor, _ query: String) async -> JSONObject {
    await executor.execute(GraphQLDocumentRequest(query: query)).body
  }

  private func value(_ body: JSONObject, _ path: [String]) throws -> JSONValue {
    var current: JSONValue? = .object(body)
    for key in path {
      guard case let .object(object)? = current else { throw Failure.invalidPath }
      current = object[key]
    }
    guard let current else { throw Failure.invalidPath }
    return current
  }

  private func object(_ value: JSONValue) throws -> JSONObject {
    guard case let .object(result) = value else { throw Failure.invalidPath }
    return result
  }

  private func array(_ body: JSONObject, _ path: [String]) throws -> [JSONValue] {
    guard case let .array(result) = try value(body, path) else { throw Failure.invalidPath }
    return result
  }

  private func string(_ item: JSONValue, _ path: [String]) throws -> String {
    var current: JSONValue? = item
    for key in path {
      guard case let .object(object)? = current else { throw Failure.invalidPath }
      current = object[key]
    }
    guard case let .string(result)? = current else { throw Failure.invalidPath }
    return result
  }

  private func stringArray(_ item: JSONValue, _ path: [String]) throws -> [String] {
    var current: JSONValue? = item
    for key in path {
      guard case let .object(object)? = current else { throw Failure.invalidPath }
      current = object[key]
    }
    guard case let .array(values)? = current else { throw Failure.invalidPath }
    return try values.map { value in
      guard case let .string(string) = value else { throw Failure.invalidPath }
      return string
    }
  }

  private func serializedResponse(_ body: JSONObject) throws -> String {
    let data = try JSONEncoder().encode(JSONValue.object(body))
    return String(bytes: data, encoding: .utf8) ?? ""
  }

  private enum Failure: Error { case invalidPath }
}
