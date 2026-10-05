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
    for value in ["http://search.example.com:7700", "https://user:pw@search.example.com", "ftp://127.0.0.1", "not a url"] {
      XCTAssertThrowsError(try SearchEngineFactory.make(configuration: config(url: value), environment: [:]), value) {
        XCTAssertEqual($0 as? KaibaConfigurationError, .invalid("searchEngine.url"))
      }
    }
    for value in ["http://127.0.0.1:7700", "http://localhost:7700", "https://search.example.com"] {
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
    XCTAssertEqual(apiKey.indexIdentity, "meilisearch:http://localhost:7700/kaiba-notes-v1")
    XCTAssertThrowsError(try SearchEngineFactory.make(
      configuration: config(username: "USER", password: "PASS"), environment: ["USER": "u", "PASS": "p"]
    )) { XCTAssertEqual($0 as? KaibaConfigurationError, .invalid("searchEngine.credentials")) }
  }

  func testDefaultsSelectMeilisearchAndResolveURLFromEnvironment() throws {
    let decoded = try JSONDecoder().decode(KaibaSearchEngineConfiguration.self, from: Data("{}".utf8))
    XCTAssertEqual(decoded.kind, "meilisearch")
    XCTAssertNil(decoded.url)
    XCTAssertEqual(decoded.resolvedURL(environment: [:]), SearchEngineFactory.fallbackMeilisearchURL)
    XCTAssertEqual(SearchEngineFactory.fallbackMeilisearchURL, "http://127.0.0.1:7700")
    let fromEnvironment = ["KAIBA_MEILISEARCH_URL": " http://search.local:7700 "]
    XCTAssertEqual(decoded.resolvedURL(environment: fromEnvironment), "http://search.local:7700")
    XCTAssertEqual(decoded.resolvedURL(environment: ["KAIBA_MEILISEARCH_URL": ""]), "http://127.0.0.1:7700")
    let explicit = KaibaSearchEngineConfiguration(url: "https://search.example")
    XCTAssertEqual(explicit.resolvedURL(environment: fromEnvironment), "https://search.example")

    let engine = try XCTUnwrap(SearchEngineFactory.make(configuration: decoded, environment: [:]))
    XCTAssertEqual(engine.indexIdentity, "meilisearch:http://127.0.0.1:7700/kaiba-notes-v1")
    let environmentEngine = try XCTUnwrap(SearchEngineFactory.make(
      configuration: decoded, environment: ["KAIBA_MEILISEARCH_URL": "http://localhost:7701"]
    ))
    XCTAssertEqual(environmentEngine.indexIdentity, "meilisearch:http://localhost:7701/kaiba-notes-v1")
    XCTAssertNil(SearchEngineFactory.defaultURL(for: "other", environment: fromEnvironment))
  }

  func testSettingsValidationAndNormalizedTargets() async throws {
    func settings(_ edits: (inout SearchEngineConnectionSettings) -> Void = { _ in }) -> SearchEngineConnectionSettings {
      var value = SearchEngineConnectionSettings(kind: "meilisearch", url: "https://search.example/sub/")
      edits(&value)
      return value
    }
    XCTAssertEqual(SearchEngineFactory.normalizedTarget("HTTP://LocalHost:7700/"), "http://localhost:7700")
    XCTAssertEqual(SearchEngineFactory.normalizedTarget("https://search.example/sub/"), "https://search.example/sub")
    XCTAssertNil(SearchEngineFactory.normalizedTarget("not-a-url"))
    XCTAssertEqual(SearchEngineFactory.adapters, [
      SearchEngineAdapterDescriptor(kind: "meilisearch", displayName: "Meilisearch", authModes: [.none, .apiKey])
    ])

    let invalidSettings: [(SearchEngineConnectionSettings, String?)] = [
      (settings { $0.kind = "elasticsearch" }, nil),
      (settings { $0.url = "https://user:pass@example.test" }, nil),
      (settings { $0.url = "http://search.example" }, nil),
      (settings { $0.indexPrefix = "Bad" }, nil),
      (settings { $0.authMode = .basic; $0.username = "alice" }, "secret"),
      (settings { $0.authMode = .apiKey }, nil),
      (settings { $0.requestTimeoutSeconds = 0 }, nil),
      (settings { $0.url = "http://localhost:7700"; $0.verifyTLS = false }, nil)
    ]
    let expected = ["searchEngine.kind", "searchEngine.url", "searchEngine.url", "searchEngine.indexPrefix",
      "searchEngine.authMode", "searchEngine.secret", "searchEngine.requestTimeoutSeconds", "searchEngine.verifyTLS"]
    for (index, item) in invalidSettings.enumerated() {
      XCTAssertThrowsError(try SearchEngineFactory.make(settings: item.0, secret: item.1)) {
        XCTAssertEqual($0 as? KaibaConfigurationError, .invalid(expected[index]))
      }
    }
    let apiTransport = RecordingFactoryTransport()
    let api = try SearchEngineFactory.make(settings: settings { $0.authMode = .apiKey }, secret: "key", transport: apiTransport)
    _ = try await api.health()
    XCTAssertEqual(apiTransport.request?.value(forHTTPHeaderField: "Authorization"), "Bearer key")
  }

  private func config(
    kind: String = "meilisearch",
    enabled: Bool? = nil,
    url: String = "http://localhost:7700",
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

private final class RecordingFactoryTransport: SearchEngineHTTPTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var value: URLRequest?
  var request: URLRequest? { lock.withLock { value } }
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    lock.withLock { value = request }
    return (Data(#"{"status":"available"}"#.utf8), try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)))
  }
}
