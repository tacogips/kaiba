import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AppCore

final class SearchEngineFactoryTests: XCTestCase {
  func testAbsentDisabledAndWrongKind() throws {
    XCTAssertNil(try SearchEngineFactory.make(configuration: nil, environment: [:]))
    XCTAssertNil(try SearchEngineFactory.make(configuration: config(enabled: false), environment: [:]))
    XCTAssertThrowsError(try SearchEngineFactory.make(
      configuration: config(kind: "opensearch"), environment: [:]
    )) { error in XCTAssertEqual(error as? KaibaConfigurationError, .invalid("searchEngine.kind")) }
  }

  func testURLValidationAndLoopbackRules() throws {
    for value in ["http://es.example.com:9200", "https://user:pw@es.example.com", "ftp://127.0.0.1", "not a url"] {
      XCTAssertThrowsError(try SearchEngineFactory.make(configuration: config(url: value), environment: [:]), value) {
        XCTAssertEqual($0 as? KaibaConfigurationError, .invalid("searchEngine.url"))
      }
    }
    for value in ["http://127.0.0.1:9200", "http://localhost:9200", "https://es.example.com"] {
      XCTAssertNotNil(try SearchEngineFactory.make(configuration: config(url: value), environment: [:]), value)
    }
  }

  func testPrefixAndCredentialValidation() throws {
    XCTAssertThrowsError(try SearchEngineFactory.make(configuration: config(prefix: "Kaiba"), environment: [:])) {
      XCTAssertEqual($0 as? KaibaConfigurationError, .invalid("searchEngine.indexPrefix"))
    }
    XCTAssertThrowsError(try SearchEngineFactory.make(configuration: config(
      apiKey: "KEY", username: "USER"
    ), environment: ["KEY": "key", "USER": "user"])) {
      XCTAssertEqual($0 as? KaibaConfigurationError, .invalid("searchEngine.credentials"))
    }
    XCTAssertThrowsError(try SearchEngineFactory.make(configuration: config(username: "USER"), environment: ["USER": "user"])) {
      XCTAssertEqual($0 as? KaibaConfigurationError, .invalid("searchEngine.credentials"))
    }
    XCTAssertThrowsError(try SearchEngineFactory.make(configuration: config(apiKey: "KEY"), environment: [:])) {
      XCTAssertEqual($0 as? KaibaConfigurationError, .missingEnvironmentVariable("KEY"))
    }
    XCTAssertThrowsError(try SearchEngineFactory.make(configuration: config(apiKey: "KEY"), environment: ["KEY": ""])) {
      XCTAssertEqual($0 as? KaibaConfigurationError, .missingEnvironmentVariable("KEY"))
    }
  }

  func testValidFactoryBuildsEngineAndResolvesCredentials() async throws {
    let apiKey = try XCTUnwrap(SearchEngineFactory.make(
      configuration: config(apiKey: "KEY"), environment: ["KEY": "secret"]
    ))
    XCTAssertEqual(apiKey.indexIdentity, "elasticsearch:http://localhost:9200/kaiba-notes-v2")
    let basic = try XCTUnwrap(SearchEngineFactory.make(
      configuration: config(username: "USER", password: "PASS"),
      environment: ["USER": "u", "PASS": "p"]
    ))
    XCTAssertEqual(basic.indexIdentity, "elasticsearch:http://localhost:9200/kaiba-notes-v2")
  }

  func testSettingsValidationAndNormalizedTargets() async throws {
    func settings(_ edits: (inout SearchEngineConnectionSettings) -> Void = { _ in }) -> SearchEngineConnectionSettings {
      var value = SearchEngineConnectionSettings(kind: "elasticsearch", url: "https://es.example/sub/")
      edits(&value)
      return value
    }
    XCTAssertEqual(SearchEngineFactory.normalizedTarget("HTTP://LocalHost:9200/"), "http://localhost:9200")
    XCTAssertEqual(SearchEngineFactory.normalizedTarget("https://es.example/sub/"), "https://es.example/sub")
    XCTAssertNil(SearchEngineFactory.normalizedTarget("not-a-url"))
    XCTAssertEqual(SearchEngineFactory.adapters, [SearchEngineAdapterDescriptor(
      kind: "elasticsearch", displayName: "Elasticsearch", authModes: [.none, .basic, .apiKey]
    ), SearchEngineAdapterDescriptor(kind: "meilisearch", displayName: "Meilisearch", authModes: [.none, .apiKey])])

    let invalidSettings: [(SearchEngineConnectionSettings, String?)] = [
      (settings { $0.kind = "other" }, nil),
      (settings { $0.url = "https://user:pass@example.test" }, nil),
      (settings { $0.url = "http://es.example" }, nil),
      (settings { $0.indexPrefix = "Bad" }, nil),
      (settings { $0.authMode = .basic }, "secret"),
      (settings { $0.authMode = .apiKey }, nil),
      (settings { $0.requestTimeoutSeconds = 0 }, nil),
      (settings { $0.url = "http://localhost:9200"; $0.verifyTLS = false }, nil)
    ]
    let expected = ["searchEngine.kind", "searchEngine.url", "searchEngine.url", "searchEngine.indexPrefix",
      "searchEngine.username", "searchEngine.secret", "searchEngine.requestTimeoutSeconds", "searchEngine.verifyTLS"]
    for (index, item) in invalidSettings.enumerated() {
      XCTAssertThrowsError(try SearchEngineFactory.make(settings: item.0, secret: item.1)) {
        XCTAssertEqual($0 as? KaibaConfigurationError, .invalid(expected[index]))
      }
    }
    let transport = RecordingFactoryTransport()
    let basic = try SearchEngineFactory.make(settings: settings { $0.authMode = .basic; $0.username = "alice" },
      secret: "pw", transport: transport)
    _ = try await basic.health()
    XCTAssertEqual(transport.request?.value(forHTTPHeaderField: "Authorization"), "Basic YWxpY2U6cHc=")
    let apiTransport = RecordingFactoryTransport()
    let api = try SearchEngineFactory.make(settings: settings { $0.authMode = .apiKey }, secret: "key", transport: apiTransport)
    _ = try await api.health()
    XCTAssertEqual(apiTransport.request?.value(forHTTPHeaderField: "Authorization"), "ApiKey key")
  }

  private func config(
    kind: String = "elasticsearch",
    enabled: Bool? = nil,
    url: String = "http://localhost:9200",
    prefix: String? = nil,
    apiKey: String? = nil,
    username: String? = nil,
    password: String? = nil
  ) -> KaibaSearchEngineConfiguration {
    KaibaSearchEngineConfiguration(
      kind: kind, enabled: enabled, url: url, indexPrefix: prefix,
      apiKeyEnvironmentVariable: apiKey,
      usernameEnvironmentVariable: username,
      passwordEnvironmentVariable: password
    )
  }
}

private final class RecordingFactoryTransport: ElasticsearchHTTPTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var value: URLRequest?
  var request: URLRequest? { lock.withLock { value } }
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    lock.withLock { value = request }
    return (Data(#"{"status":"green"}"#.utf8), try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)))
  }
}
