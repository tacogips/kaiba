import Foundation
import XCTest
@testable import AppCore

final class MeilisearchFactoryTests: NoteTestCase {
  func testDescriptorSupportsNoneAndApiKeyOnly() {
    XCTAssertEqual(SearchEngineFactory.adapters.first(where: { $0.kind == "meilisearch" }),
      SearchEngineAdapterDescriptor(kind: "meilisearch", displayName: "Meilisearch", authModes: [.none, .apiKey]))
  }

  func testBasicAuthModeRejectedBeforeTransport() {
    let transport = MeilisearchFactoryTransport()
    let settings = SearchEngineConnectionSettings(kind: "meilisearch", url: "http://localhost:7700", authMode: .basic, username: "alice")
    XCTAssertThrowsError(try SearchEngineFactory.make(settings: settings, secret: "secret", transport: transport)) {
      XCTAssertEqual($0 as? KaibaConfigurationError, .invalid("searchEngine.authMode"))
    }
    XCTAssertEqual(transport.calls, 0)
  }

  func testConfigurationBuildsExpectedIdentity() throws {
    let configuration = KaibaSearchEngineConfiguration(kind: "meilisearch", url: "http://127.0.0.1:7700")
    let engine = try XCTUnwrap(SearchEngineFactory.make(configuration: configuration, environment: [:]))
    XCTAssertEqual(engine.indexIdentity, "meilisearch:http://127.0.0.1:7700/kaiba-notes-v1")
  }

  func testApiKeyConfigurationBuilds() throws {
    let configuration = KaibaSearchEngineConfiguration(kind: "meilisearch", url: "http://localhost:7700", apiKeyEnvironmentVariable: "MEILI_KEY")
    XCTAssertNotNil(try SearchEngineFactory.make(configuration: configuration, environment: ["MEILI_KEY": "secret"]))
  }

  func testUsernameEnvironmentVariableRejectedForMeilisearch() {
    let configuration = KaibaSearchEngineConfiguration(kind: "meilisearch", url: "http://localhost:7700", usernameEnvironmentVariable: "USER")
    XCTAssertThrowsError(try SearchEngineFactory.make(configuration: configuration, environment: ["USER": "alice"])) {
      XCTAssertEqual($0 as? KaibaConfigurationError, .invalid("searchEngine.credentials"))
    }
  }

  func testPasswordEnvironmentVariableRejectedForMeilisearch() {
    let configuration = KaibaSearchEngineConfiguration(kind: "meilisearch", url: "http://localhost:7700", passwordEnvironmentVariable: "PASS")
    XCTAssertThrowsError(try SearchEngineFactory.make(configuration: configuration, environment: ["PASS": "secret"])) {
      XCTAssertEqual($0 as? KaibaConfigurationError, .invalid("searchEngine.credentials"))
    }
  }

  func testTestConnectionReportsAuthModeAsInvalidSettings() async throws {
    let service = try makeService(function: #function)
    let input = SearchEngineSettingsInput(kind: "meilisearch", url: "http://localhost:7700", authMode: "basic", username: "alice", secret: "pw")
    let result = try await service.testSearchEngineConnection(input) { settings, secret in
      try SearchEngineFactory.make(settings: settings, secret: secret)
    }
    XCTAssertEqual(result.status, .invalidSettings)
    XCTAssertEqual(result.detail, "searchEngine.authMode")
  }
}

private final class MeilisearchFactoryTransport: SearchEngineHTTPTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var calls: Int { lock.withLock { count } }
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    lock.withLock { count += 1 }
    return (Data(#"{"status":"available"}"#.utf8), try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)))
  }
}
