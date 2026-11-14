import Foundation

public enum SearchEngineSettingsResolution: Sendable {
  case managedByConfig(KaibaSearchEngineConfiguration)
  case store(SearchEngineConnectionSettings, secret: String?)
  case none
}

private struct StoredSearchEngineSettings: Codable {
  var kind: String
  var url: String?
  var indexPrefix: String?
  var authMode: String?
  var username: String?
  var verifyTLS: Bool?
  var requestTimeoutSeconds: Int?

  func connection(environment: [String: String]) -> SearchEngineConnectionSettings {
    let explicitURL = url.flatMap { value in
      value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }
    return SearchEngineConnectionSettings(
      kind: kind,
      url: explicitURL ?? SearchEngineFactory.defaultURL(for: kind, environment: environment) ?? "",
      indexPrefix: indexPrefix ?? "kaiba",
      authMode: SearchEngineAuthMode(rawValue: authMode ?? "none") ?? .none,
      username: username,
      verifyTLS: verifyTLS ?? true,
      requestTimeoutSeconds: requestTimeoutSeconds ?? 10
    )
  }
}

struct StoredSearchEngineSecret: Codable {
  var authMode: String
  var target: String
  var secret: String
}

public extension NoteService {
  internal static let searchEngineSettingsKey = "auth.search-engine.settings"
  internal static let searchEngineSecretKey = "auth.search-engine.secret"

  func resolveSearchEngineSettings(
    configuration: KaibaSearchEngineConfiguration?,
    environment: [String: String]
  ) throws -> SearchEngineSettingsResolution {
    if let configuration { return .managedByConfig(configuration) }
    guard let settingsJSON = try appSetting(key: Self.searchEngineSettingsKey, allowReserved: true) else {
      return .none
    }
    guard let data = settingsJSON.data(using: .utf8),
          let stored = try? JSONDecoder().decode(StoredSearchEngineSettings.self, from: data) else {
      throw SearchEngineSettingsError.invalid(field: "searchEngine.settings")
    }
    guard stored.kind != "none" else { return .none }
    if let authMode = stored.authMode, SearchEngineAuthMode(rawValue: authMode) == nil {
      throw SearchEngineSettingsError.invalid(field: "searchEngine.authMode")
    }

    let settings = stored.connection(environment: environment)
    let storedSecret = try storedSecret()
    let secret: String?
    if let storedSecret,
       storedSecret.authMode == settings.authMode.rawValue,
       storedSecret.target == SearchEngineFactory.normalizedTarget(settings.url) {
      secret = storedSecret.secret
    } else {
      secret = nil
    }
    return .store(settings, secret: secret)
  }

  func makeResolvedSearchEngine(
    configuration: KaibaSearchEngineConfiguration?,
    environment: [String: String]
  ) throws -> (any SearchEngine)? {
    switch try resolveSearchEngineSettings(configuration: configuration, environment: environment) {
    case .managedByConfig(let config):
      return try SearchEngineFactory.make(configuration: config, environment: environment)
    case .store(let settings, let secret):
      do {
        return try SearchEngineFactory.make(settings: settings, secret: secret)
      } catch let error as KaibaConfigurationError {
        if case .invalid(let field) = error {
          throw SearchEngineSettingsError.invalid(field: field)
        }
        throw error
      }
    case .none:
      return nil
    }
  }

  internal func storedSearchEngineSettings(environment: [String: String]) throws -> SearchEngineConnectionSettings? {
    switch try resolveSearchEngineSettings(configuration: nil, environment: environment) {
    case .store(let settings, _): return settings
    case .none: return nil
    case .managedByConfig: return nil
    }
  }

  internal func storedSearchEngineExplicitURL() throws -> String? {
    guard let settingsJSON = try appSetting(key: Self.searchEngineSettingsKey, allowReserved: true),
          let data = settingsJSON.data(using: .utf8),
          let stored = try? JSONDecoder().decode(StoredSearchEngineSettings.self, from: data),
          stored.kind != "none",
          let url = stored.url,
          !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return url
  }

  internal func storedSearchEngineSecret() throws -> StoredSearchEngineSecret? {
    try storedSecret()
  }

  private func storedSecret() throws -> StoredSearchEngineSecret? {
    guard let raw = try appSetting(key: Self.searchEngineSecretKey, allowReserved: true),
          let data = raw.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(StoredSearchEngineSecret.self, from: data)
  }
}
