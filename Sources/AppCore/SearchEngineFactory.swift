import Foundation

public enum SearchEngineFactory {
  public static func make(
    configuration: KaibaSearchEngineConfiguration?,
    environment: [String: String]
  ) throws -> (any SearchEngine)? {
    guard let configuration, configuration.isEnabled else { return nil }
    guard configuration.kind == "elasticsearch" else {
      throw KaibaConfigurationError.invalid("searchEngine.kind")
    }
    guard let components = URLComponents(string: configuration.url),
          let url = components.url,
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

    let authorization: ElasticsearchAuthorization
    if let apiKeyName {
      authorization = .apiKey(try environmentValue(apiKeyName, in: environment))
    } else if let usernameName, let passwordName {
      authorization = .basic(
        username: try environmentValue(usernameName, in: environment),
        password: try environmentValue(passwordName, in: environment)
      )
    } else {
      authorization = .none
    }
    return ElasticsearchSearchEngine(
      baseURL: url,
      indexPrefix: configuration.resolvedIndexPrefix,
      authorization: authorization
    )
  }

  private static func environmentValue(_ name: String, in environment: [String: String]) throws -> String {
    guard let value = environment[name], !value.isEmpty else {
      throw KaibaConfigurationError.missingEnvironmentVariable(name)
    }
    return value
  }
}
