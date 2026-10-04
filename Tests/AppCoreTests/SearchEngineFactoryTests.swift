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
    XCTAssertEqual(apiKey.indexIdentity, "elasticsearch:kaiba-notes-v1")
    let basic = try XCTUnwrap(SearchEngineFactory.make(
      configuration: config(username: "USER", password: "PASS"),
      environment: ["USER": "u", "PASS": "p"]
    ))
    XCTAssertEqual(basic.indexIdentity, "elasticsearch:kaiba-notes-v1")
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
