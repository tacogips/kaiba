import Foundation

public enum SearchEngineFactory {
  /// The default adapter, used when the `searchEngine` config section has no `kind`.
  public static let defaultKind = "meilisearch"
  /// Environment variable that names the Meilisearch URL used when none is configured.
  public static let meilisearchURLEnvironmentVariable = "KAIBA_MEILISEARCH_URL"
  /// Fallback when `KAIBA_MEILISEARCH_URL` is unset: the local compose instance.
  public static let fallbackMeilisearchURL = "http://127.0.0.1:7700"

  public static let adapters: [SearchEngineAdapterDescriptor] = [
    SearchEngineAdapterDescriptor(kind: "meilisearch", displayName: "Meilisearch", authModes: [.none, .apiKey])
  ]

  /// The default URL for an adapter: its environment variable when set and
  /// non-empty, otherwise the fallback constant; nil for an unknown kind.
  public static func defaultURL(for kind: String, environment: [String: String]) -> String? {
    guard kind == "meilisearch" else { return nil }
    let value = environment[meilisearchURLEnvironmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? fallbackMeilisearchURL : value
  }

  /// `adapters` with each `defaultURL` resolved from the environment.
  public static func adapters(environment: [String: String]) -> [SearchEngineAdapterDescriptor] {
    adapters.map { adapter in
      var resolved = adapter
      resolved.defaultURL = defaultURL(for: adapter.kind, environment: environment)
      return resolved
    }
  }

  public static func normalizedTarget(_ url: String) -> String? {
    guard let components = URLComponents(string: url),
          let scheme = components.scheme?.lowercased(), let rawHost = components.host, !rawHost.isEmpty else { return nil }
    let hostValue = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
    let host = hostValue.contains(":") ? "[\(hostValue)]" : hostValue
    let port = components.port.map { ":\($0)" } ?? ""
    let path = components.path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    return "\(scheme)://\(host)\(port)\(path)"
  }

  public static func make(
    configuration: KaibaSearchEngineConfiguration?,
    environment: [String: String]
  ) throws -> (any SearchEngine)? {
    guard let configuration, configuration.isEnabled else { return nil }
    guard adapters.contains(where: { $0.kind == configuration.kind }) else {
      throw KaibaConfigurationError.invalid("searchEngine.kind")
    }
    let configuredURL = configuration.resolvedURL(environment: environment)
    guard let components = URLComponents(string: configuredURL),
          components.url != nil,
          let scheme = components.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = components.host, !host.isEmpty,
          components.user == nil, components.password == nil,
          scheme != "http" || ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()) else {
      throw KaibaConfigurationError.invalid("searchEngine.url")
    }
    guard configuration.resolvedIndexPrefix.range(
      of: "^[a-z0-9][a-z0-9_-]{0,63}$", options: .regularExpression
    ) != nil else {
      throw KaibaConfigurationError.invalid("searchEngine.indexPrefix")
    }

    // Username and password credentials need an adapter with basic auth;
    // the bundled adapters accept only an API key.
    if configuration.usernameEnvironmentVariable != nil || configuration.passwordEnvironmentVariable != nil {
      throw KaibaConfigurationError.invalid("searchEngine.credentials")
    }
    let settings: SearchEngineConnectionSettings
    let secret: String?
    if let apiKeyName = configuration.apiKeyEnvironmentVariable {
      settings = SearchEngineConnectionSettings(kind: configuration.kind, url: configuredURL,
        indexPrefix: configuration.resolvedIndexPrefix, authMode: .apiKey)
      secret = try environmentValue(apiKeyName, in: environment)
    } else {
      settings = SearchEngineConnectionSettings(kind: configuration.kind, url: configuredURL,
        indexPrefix: configuration.resolvedIndexPrefix)
      secret = nil
    }
    return try make(settings: settings, secret: secret)
  }

  public static func make(settings: SearchEngineConnectionSettings, secret: String?) throws -> any SearchEngine {
    try make(settings: settings, secret: secret, transport: nil)
  }

  static func make(
    settings: SearchEngineConnectionSettings,
    secret: String?,
    transport: (any SearchEngineHTTPTransport)?
  ) throws -> any SearchEngine {
    guard adapters.contains(where: { $0.kind == settings.kind }) else {
      throw KaibaConfigurationError.invalid("searchEngine.kind")
    }
    guard let descriptor = adapters.first(where: { $0.kind == settings.kind }), descriptor.authModes.contains(settings.authMode) else {
      throw KaibaConfigurationError.invalid("searchEngine.authMode")
    }
    let urlString = settings.url
    guard urlString.count <= 2048,
          !urlString.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
          let components = URLComponents(string: urlString),
          let url = components.url,
          let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
          let host = components.host, !host.isEmpty,
          components.user == nil, components.password == nil,
          scheme != "http" || ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()) else {
      throw KaibaConfigurationError.invalid("searchEngine.url")
    }
    guard settings.indexPrefix.range(of: "^[a-z0-9][a-z0-9_-]{0,63}$", options: .regularExpression) != nil else {
      throw KaibaConfigurationError.invalid("searchEngine.indexPrefix")
    }
    if settings.authMode != .none {
      guard let secret, !secret.isEmpty, secret.count <= 4096,
            !secret.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
        throw KaibaConfigurationError.invalid("searchEngine.secret")
      }
    }
    guard (1...120).contains(settings.requestTimeoutSeconds) else {
      throw KaibaConfigurationError.invalid("searchEngine.requestTimeoutSeconds")
    }
    if !settings.verifyTLS && (scheme != "https" || !URLSessionSearchEngineTransport.supportsInsecureTLS) {
      throw KaibaConfigurationError.invalid("searchEngine.verifyTLS")
    }
    return MeilisearchSearchEngine(baseURL: url, indexPrefix: settings.indexPrefix,
      apiKey: settings.authMode == .apiKey ? secret : nil, requestTimeoutSeconds: settings.requestTimeoutSeconds,
      verifyTLS: settings.verifyTLS, transport: transport)
  }

  private static func environmentValue(_ name: String, in environment: [String: String]) throws -> String {
    guard let value = environment[name], !value.isEmpty else {
      throw KaibaConfigurationError.missingEnvironmentVariable(name)
    }
    return value
  }
}
