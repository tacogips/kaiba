import Foundation

import AppCore
import AppGraphQL
import XCTest

final class SearchEngineSettingsGraphQLTests: XCTestCase {
  func testAdminReadsSettingsAndNonAdminGetsNotFoundShape() async throws {
    let service = try makeService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let adminResponse = await run(executor, "query { searchEngineSettings { result { accepted status } value { adapters { kind } hasSecret } } }")
    XCTAssertEqual(try string(adminResponse, ["searchEngineSettings", "result", "status"]), "ok")
    XCTAssertTrue(try bool(adminResponse, ["searchEngineSettings", "value", "hasSecret"]) == false)
    let adapters = try array(adminResponse, ["searchEngineSettings", "value", "adapters"])
    XCTAssertEqual(try string(try XCTUnwrap(adapters.first), ["kind"]), "meilisearch")

    let user = try service.service.createUser(email: "reader@example.test", displayName: "Reader")
    let denied = await run(executor, "query { searchEngineSettings { result { accepted status diagnostics } } }", actingUserId: user.userId)
    XCTAssertEqual(try string(denied, ["searchEngineSettings", "result", "status"]), "not_found")
    XCTAssertFalse(try bool(denied, ["searchEngineSettings", "result", "accepted"]))
  }

  func testConfigLockAndInvalidSettingsMapToStableStatuses() async throws {
    let service = try makeService()
    service.service.searchEngineSlot.setManagedConfiguration(
      KaibaSearchEngineConfiguration(kind: "meilisearch", url: "https://search.internal")
    )
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let managed = await run(executor, "mutation { updateSearchEngineSettings(input: { kind: \"none\" }) { result { status diagnostics } } }")
    XCTAssertEqual(try string(managed, ["updateSearchEngineSettings", "result", "status"]), "settings-managed-by-config")
    XCTAssertEqual(
      try stringArray(managed, ["updateSearchEngineSettings", "result", "diagnostics"]),
      ["search engine settings are managed by the configuration file"]
    )

    let ordinary = try makeService()
    let invalid = await run(NoteGraphQLDocumentExecutor(service: ordinary), "mutation { updateSearchEngineSettings(input: { kind: \"meilisearch\", url: \"not-a-url\" }) { result { status diagnostics } } }")
    XCTAssertEqual(try string(invalid, ["updateSearchEngineSettings", "result", "status"]), "invalid-settings")
    XCTAssertEqual(try stringArray(invalid, ["updateSearchEngineSettings", "result", "diagnostics"]), ["searchEngine.url"])
  }

  func testRetargetedTestConnectionIsAcceptedValueAndSecretNeverEchoes() async throws {
    let service = try makeService()
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let update = """
    mutation Update($input: SearchEngineSettingsInput!) {
      updateSearchEngineSettings(input: $input) { result { accepted status diagnostics } value { hasSecret } }
    }
    """
    let secret = "TOPSECRET-123"
    let saved = await run(executor, update, variables: ["input": .object([
      "kind": .string("meilisearch"), "url": .string("https://search.internal:7700"),
      "authMode": .string("apiKey"), "secret": .string(secret)
    ])])
    XCTAssertTrue(try bool(saved, ["updateSearchEngineSettings", "result", "accepted"]))
    XCTAssertTrue(try bool(saved, ["updateSearchEngineSettings", "value", "hasSecret"]))

    let retarget = """
    mutation Test($input: SearchEngineSettingsInput!) {
      testSearchEngineConnection(input: $input) { result { accepted status diagnostics } value { status detail } }
    }
    """
    let tested = await run(executor, retarget, variables: ["input": .object([
      "kind": .string("meilisearch"), "url": .string("https://other.internal:7700"),
      "authMode": .string("apiKey")
    ])])
    XCTAssertTrue(try bool(tested, ["testSearchEngineConnection", "result", "accepted"]))
    XCTAssertEqual(try string(tested, ["testSearchEngineConnection", "value", "status"]), "invalid-settings")
    XCTAssertEqual(try string(tested, ["testSearchEngineConnection", "value", "detail"]), "searchEngine.secret")

    let read = await run(executor, "query { searchEngineSettings { result { status } value { hasSecret } } }")
    XCTAssertFalse(try serializedResponse(saved).contains(secret))
    XCTAssertFalse(try serializedResponse(read).contains(secret))
    XCTAssertFalse(try serializedResponse(tested).contains(secret))
  }

  func testGraphQLServerDefaultInputResolvesOnBackendAndNeverReturnsEngineURL() async throws {
    let slot = SearchEngineSlot()
    slot.setEnvironment(["KAIBA_MEILISEARCH_URL": "https://engine-only.internal"])
    let service = try makeService(slot: slot)
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let omitted = await run(executor, """
      mutation { updateSearchEngineSettings(input: { kind: "meilisearch", authMode: "none" }) {
        result { accepted status } value { kind url }
      } }
      """)
    XCTAssertTrue(try bool(omitted, ["updateSearchEngineSettings", "result", "accepted"]))
    XCTAssertEqual(try string(omitted, ["updateSearchEngineSettings", "value", "kind"]), "meilisearch")
    XCTAssertEqual(try value(omitted, ["data", "updateSearchEngineSettings", "value", "url"]), .null)

    let empty = await run(executor, """
      mutation { updateSearchEngineSettings(input: { kind: "meilisearch", url: "", authMode: "none" }) {
        result { accepted status } value { kind url }
      } }
      """)
    XCTAssertTrue(try bool(empty, ["updateSearchEngineSettings", "result", "accepted"]))
    XCTAssertEqual(try value(empty, ["data", "updateSearchEngineSettings", "value", "url"]), .null)

    let testConnection = await run(executor, """
      mutation { testSearchEngineConnection(input: { kind: "meilisearch", authMode: "apiKey" }) {
        result { accepted status } value { status detail }
      } }
      """)
    XCTAssertTrue(try bool(testConnection, ["testSearchEngineConnection", "result", "accepted"]))
    XCTAssertEqual(try string(testConnection, ["testSearchEngineConnection", "value", "status"]), "invalid-settings")
    XCTAssertEqual(try string(testConnection, ["testSearchEngineConnection", "value", "detail"]), "searchEngine.secret")

    let read = await run(executor, "query { searchEngineSettings { result { status } value { kind url } } }")
    XCTAssertEqual(try value(read, ["data", "searchEngineSettings", "value", "url"]), .null)
    for response in [omitted, empty, testConnection, read] {
      XCTAssertFalse(try serializedResponse(response).contains("engine-only.internal"))
    }
  }

  private func makeService(slot: SearchEngineSlot = SearchEngineSlot()) throws -> GraphQLNoteGraphQLService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/SearchEngineSettingsGraphQLTests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return GraphQLNoteGraphQLService(service: try NoteService(
      driver: SQLiteNoteDatabaseDriver(noteRoot: root.path),
      searchEngineSlot: slot
    ))
  }

  private func run(
    _ executor: NoteGraphQLDocumentExecutor,
    _ query: String,
    variables: JSONObject = [:],
    actingUserId: UserID? = nil
  ) async -> JSONObject {
    await executor.execute(GraphQLDocumentRequest(query: query, variables: variables, actingUserId: actingUserId)).body
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

  private func string(_ body: JSONObject, _ path: [String]) throws -> String {
    guard case let .string(result) = try value(body, ["data"] + path) else { throw Failure.invalidPath }
    return result
  }

  private func stringArray(_ body: JSONObject, _ path: [String]) throws -> [String] {
    guard case let .array(items) = try value(body, ["data"] + path) else { throw Failure.invalidPath }
    return items.compactMap { if case let .string(value) = $0 { value } else { nil } }
  }

  private func array(_ body: JSONObject, _ path: [String]) throws -> [JSONValue] {
    guard case let .array(items) = try value(body, ["data"] + path) else { throw Failure.invalidPath }
    return items
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

  private func bool(_ body: JSONObject, _ path: [String]) throws -> Bool {
    guard case let .bool(result) = try value(body, ["data"] + path) else { throw Failure.invalidPath }
    return result
  }

  private func serializedResponse(_ body: JSONObject) throws -> String {
    let data = try JSONEncoder().encode(JSONValue.object(body))
    return String(bytes: data, encoding: .utf8) ?? ""
  }

  private enum Failure: Error { case invalidPath }
}
