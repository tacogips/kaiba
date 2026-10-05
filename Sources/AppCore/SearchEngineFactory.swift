import Foundation

public enum SearchEngineFactory {
  public static let adapters: [SearchEngineAdapterDescriptor] = [
    SearchEngineAdapterDescriptor(kind: "elasticsearch", displayName: "Elasticsearch", authModes: [.none, .basic, .apiKey]),
    SearchEngineAdapterDescriptor(kind: "meilisearch", displayName: "Meilisearch", authModes: [.none, .apiKey])
  ]

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
    if configuration.kind == "meilisearch",
       configuration.usernameEnvironmentVariable != nil || configuration.passwordEnvironmentVariable != nil {
      throw KaibaConfigurationError.invalid("searchEngine.credentials")
    }
    guard let components = URLComponents(string: configuration.url),
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

    let apiKeyName = configuration.apiKeyEnvironmentVariable
    let usernameName = configuration.usernameEnvironmentVariable
    let passwordName = configuration.passwordEnvironmentVariable
    if (apiKeyName != nil && (usernameName != nil || passwordName != nil)) ||
      ((usernameName == nil) != (passwordName == nil)) {
      throw KaibaConfigurationError.invalid("searchEngine.credentials")
    }

    let settings: SearchEngineConnectionSettings
    let secret: String?
    if let apiKeyName {
      settings = SearchEngineConnectionSettings(kind: configuration.kind, url: configuration.url,
        indexPrefix: configuration.resolvedIndexPrefix, authMode: .apiKey)
      secret = try environmentValue(apiKeyName, in: environment)
    } else if let usernameName, let passwordName {
      let username = try environmentValue(usernameName, in: environment)
      settings = SearchEngineConnectionSettings(kind: configuration.kind, url: configuration.url,
        indexPrefix: configuration.resolvedIndexPrefix, authMode: .basic, username: username)
      secret = try environmentValue(passwordName, in: environment)
    } else {
      settings = SearchEngineConnectionSettings(kind: configuration.kind, url: configuration.url,
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
    transport: (any ElasticsearchHTTPTransport)?
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
    if settings.kind == "elasticsearch", settings.authMode == .basic {
      guard let username = settings.username, !username.isEmpty, username.count <= 256,
            !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
        throw KaibaConfigurationError.invalid("searchEngine.username")
      }
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
    if !settings.verifyTLS && (scheme != "https" || !URLSessionElasticsearchTransport.supportsInsecureTLS) {
      throw KaibaConfigurationError.invalid("searchEngine.verifyTLS")
    }
    if settings.kind == "meilisearch" {
      return MeilisearchSearchEngine(baseURL: url, indexPrefix: settings.indexPrefix,
        apiKey: settings.authMode == .apiKey ? secret : nil, requestTimeoutSeconds: settings.requestTimeoutSeconds,
        verifyTLS: settings.verifyTLS, transport: transport)
    }
    let authorization: ElasticsearchAuthorization
    switch settings.authMode {
    case .none: authorization = .none
    case .basic: authorization = .basic(username: settings.username ?? "", password: secret ?? "")
    case .apiKey: authorization = .apiKey(secret ?? "")
    }
    return ElasticsearchSearchEngine(baseURL: url, indexPrefix: settings.indexPrefix,
      authorization: authorization, requestTimeoutSeconds: settings.requestTimeoutSeconds,
      verifyTLS: settings.verifyTLS, transport: transport)
  }

  private static func environmentValue(_ name: String, in environment: [String: String]) throws -> String {
    guard let value = environment[name], !value.isEmpty else {
      throw KaibaConfigurationError.missingEnvironmentVariable(name)
    }
    return value
  }
}
