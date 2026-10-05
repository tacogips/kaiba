import Foundation
import Testing
@testable import AppCore

@Test func searchEngineConfigurationIsOptionalAndDefaultsToNil() throws {
  let configuration = try JSONDecoder().decode(KaibaConfiguration.self, from: Data("{}".utf8))
  #expect(configuration.searchEngine == nil)
  #expect(KaibaConfiguration().searchEngine == nil)
}

@Test func searchEngineConfigurationDecodesDefaultsAndUnknownKinds() throws {
  let enabled = try JSONDecoder().decode(
    KaibaConfiguration.self,
    from: Data(#"{"searchEngine":{"kind":"meilisearch","url":"http://127.0.0.1:7700"}}"#.utf8)
  ).searchEngine
  #expect(enabled?.isEnabled == true)
  #expect(enabled?.resolvedIndexPrefix == "kaiba")

  let disabled = try JSONDecoder().decode(
    KaibaSearchEngineConfiguration.self,
    from: Data(#"{"kind":"meilisearch","url":"http://127.0.0.1:7700","enabled":false}"#.utf8)
  )
  #expect(!disabled.isEnabled)

  let unknown = try JSONDecoder().decode(
    KaibaSearchEngineConfiguration.self,
    from: Data(#"{"kind":"opensearch","url":"https://search.example"}"#.utf8)
  )
  #expect(unknown.kind == "opensearch")
}

@Test func searchEngineConfigurationRoundTripsEveryField() throws {
  let expected = KaibaSearchEngineConfiguration(
    kind: "meilisearch",
    enabled: false,
    url: "https://search.example",
    indexPrefix: "custom-index",
    apiKeyEnvironmentVariable: "SEARCH_API_KEY",
    usernameEnvironmentVariable: "SEARCH_USERNAME",
    passwordEnvironmentVariable: "SEARCH_PASSWORD"
  )
  let configuration = KaibaConfiguration(searchEngine: expected)
  let encoded = try JSONEncoder().encode(configuration)
  let decoded = try JSONDecoder().decode(KaibaConfiguration.self, from: encoded)
  #expect(decoded.searchEngine == expected)
}
