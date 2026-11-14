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

@Test func searchEngineConfigurationResolvesOnlyExplicitNonblankURL() throws {
  let absent = try JSONDecoder().decode(KaibaSearchEngineConfiguration.self, from: Data("{}".utf8))
  #expect(absent.explicitURL == nil)
  #expect(absent.resolvedURL(environment: [:]) == SearchEngineFactory.fallbackMeilisearchURL)
  #expect(absent.resolvedURL(environment: ["KAIBA_MEILISEARCH_URL": ""]) == SearchEngineFactory.fallbackMeilisearchURL)
  #expect(absent.resolvedURL(environment: ["KAIBA_MEILISEARCH_URL": " https://env.example "]) == "https://env.example")

  let empty = try JSONDecoder().decode(KaibaSearchEngineConfiguration.self, from: Data(#"{"url":""}"#.utf8))
  #expect(empty.explicitURL == nil)
  #expect(empty.resolvedURL(environment: [:]) == SearchEngineFactory.fallbackMeilisearchURL)
  let whitespace = try JSONDecoder().decode(KaibaSearchEngineConfiguration.self, from: Data(#"{"url":"   "}"#.utf8))
  #expect(whitespace.explicitURL == nil)
  #expect(whitespace.resolvedURL(environment: ["KAIBA_MEILISEARCH_URL": " https://env.example "]) == "https://env.example")

  let explicit = try JSONDecoder().decode(
    KaibaSearchEngineConfiguration.self,
    from: Data(#"{"url":" https://search.example "}"#.utf8)
  )
  #expect(explicit.explicitURL == " https://search.example ")
  #expect(explicit.resolvedURL(environment: ["KAIBA_MEILISEARCH_URL": "https://env.example"]) == " https://search.example ")
}

@Test func emptySearchEngineConfigurationURLUsesFactoryFallback() throws {
  let configuration = try JSONDecoder().decode(
    KaibaSearchEngineConfiguration.self,
    from: Data(#"{"url":""}"#.utf8)
  )
  let engine = try SearchEngineFactory.make(configuration: configuration, environment: [:])
  #expect(engine?.indexIdentity == "meilisearch:http://127.0.0.1:7700/kaiba-notes-v1")
}
