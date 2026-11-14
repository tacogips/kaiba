import Foundation

public extension NoteService {
  func searchEngineSettings() throws -> SearchEngineSettingsView {
    try requireSearchEngineAdministrator()
    let environment = searchEngineSlot.environment
    let adapters = SearchEngineFactory.adapters
    let active = searchEngineSlot.engine != nil
    if let config = searchEngineSlot.managedConfiguration {
      let authMode: SearchEngineAuthMode = config.apiKeyEnvironmentVariable != nil ? .apiKey :
        (config.usernameEnvironmentVariable != nil && config.passwordEnvironmentVariable != nil ? .basic : .none)
      return SearchEngineSettingsView(
        managedBy: .config,
        kind: config.isEnabled ? config.kind : "none",
        url: config.explicitURL,
        indexPrefix: config.resolvedIndexPrefix,
        authMode: authMode,
        username: nil,
        hasSecret: authMode != .none,
        verifyTLS: true,
        requestTimeoutSeconds: 10,
        adapters: adapters,
        active: active
      )
    }
    guard let settings = try storedSearchEngineSettings(environment: environment) else {
      return SearchEngineSettingsView(
        managedBy: .unset,
        kind: "none",
        url: nil,
        indexPrefix: nil,
        authMode: .none,
        username: nil,
        hasSecret: false,
        verifyTLS: true,
        requestTimeoutSeconds: 10,
        adapters: adapters,
        active: active
      )
    }
    let secret = try storedSearchEngineSecret()
    let target = SearchEngineFactory.normalizedTarget(settings.url)
    let explicitURL = try storedSearchEngineExplicitURL()
    return SearchEngineSettingsView(
      managedBy: .store,
      kind: settings.kind,
      url: explicitURL,
      indexPrefix: settings.indexPrefix,
      authMode: settings.authMode,
      username: settings.username,
      hasSecret: settings.authMode != .none && secret?.authMode == settings.authMode.rawValue && secret?.target == target,
      verifyTLS: settings.verifyTLS,
      requestTimeoutSeconds: settings.requestTimeoutSeconds,
      adapters: adapters,
      active: active
    )
  }

  func updateSearchEngineSettings(_ input: SearchEngineSettingsInput) async throws -> SearchEngineSettingsView {
    try requireSearchEngineAdministrator()
    guard searchEngineSlot.managedConfiguration == nil else { throw SearchEngineSettingsError.managedByConfig }
    if input.kind == "none" {
      try persistSearchEngineSettings(json: "{\"kind\":\"none\"}", secret: nil)
      _ = await searchEngineSlot.reload()
      return try searchEngineSettings()
    }
    let candidate = try validatedSettings(input, timeoutCap: nil)
    try persistSearchEngineSettings(json: candidate.settingsJSON, secret: candidate.secretRecord)
    _ = await searchEngineSlot.reload()
    return try searchEngineSettings()
  }

  func testSearchEngineConnection(_ input: SearchEngineSettingsInput) async throws -> SearchEngineConnectionTestResult {
    try await testSearchEngineConnection(input) { settings, secret in
      try SearchEngineFactory.make(settings: settings, secret: secret)
    }
  }

  func testSearchEngineConnection(
    _ input: SearchEngineSettingsInput,
    makeEngine: (SearchEngineConnectionSettings, String?) throws -> any SearchEngine
  ) async throws -> SearchEngineConnectionTestResult {
    try requireSearchEngineAdministrator()
    guard searchEngineSlot.managedConfiguration == nil else { throw SearchEngineSettingsError.managedByConfig }
    let candidate: ValidatedSearchSettings
    do {
      candidate = try validatedSettings(input, timeoutCap: 10, makeEngine: makeEngine)
    } catch let error as SearchEngineSettingsError {
      if case .invalid(let field) = error {
        return SearchEngineConnectionTestResult(available: false, status: .invalidSettings, detail: field)
      }
      throw error
    }
    guard let engine = candidate.engine else {
      return SearchEngineConnectionTestResult(available: false, status: .invalidSettings, detail: "searchEngine.kind")
    }
    do {
      let health = try await engine.health()
      let detail = sanitizedHealthDetail(health.detail, username: candidate.settings.username, secret: candidate.secret)
      return SearchEngineConnectionTestResult(
        available: health.isAvailable,
        status: health.isAvailable ? .available : .unhealthy,
        detail: detail
      )
    } catch let error as SearchEngineError {
      let status: SearchEngineConnectionTestStatus
      let raw: String
      switch error {
      case .unavailable(let detail): status = .unavailable; raw = detail
      case .rejected(let code, let reason): status = .rejected; raw = "HTTP \(code) \(reason)"
      case .invalidResponse(let detail): status = .invalidResponse; raw = detail
      case .notConfigured: status = .unavailable; raw = "transport failure"
      }
      return SearchEngineConnectionTestResult(
        available: false,
        status: status,
        detail: sanitizedHealthDetail(raw, username: candidate.settings.username, secret: candidate.secret)
      )
    } catch {
      return SearchEngineConnectionTestResult(
        available: false,
        status: .unavailable,
        detail: "transport failure"
      )
    }
  }
}

private struct ValidatedSearchSettings {
  var settings: SearchEngineConnectionSettings
  var secret: String?
  var engine: (any SearchEngine)?
  var settingsJSON: String
  var secretRecord: String?
}

private extension NoteService {
  func requireSearchEngineAdministrator() throws {
    try driver.withDatabase { try requireStoreAdministrator(in: $0) }
  }

  func validatedSettings(
    _ input: SearchEngineSettingsInput,
    timeoutCap: Int?,
    makeEngine: (SearchEngineConnectionSettings, String?) throws -> any SearchEngine = { settings, secret in
      try SearchEngineFactory.make(settings: settings, secret: secret)
    }
  ) throws -> ValidatedSearchSettings {
    guard SearchEngineFactory.adapters.contains(where: { $0.kind == input.kind }) else {
      throw SearchEngineSettingsError.invalid(field: "searchEngine.kind")
    }
    guard let authMode = SearchEngineAuthMode(rawValue: input.authMode ?? "none") else {
      throw SearchEngineSettingsError.invalid(field: "searchEngine.authMode")
    }
    let explicitURL = input.url.flatMap { value in
      value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }
    let url = explicitURL ?? SearchEngineFactory.defaultURL(
      for: input.kind,
      environment: searchEngineSlot.environment
    ) ?? ""
    guard let target = SearchEngineFactory.normalizedTarget(url) else {
      throw SearchEngineSettingsError.invalid(field: "searchEngine.url")
    }
    let timeout = input.requestTimeoutSeconds ?? 10
    let settings = SearchEngineConnectionSettings(
      kind: input.kind,
      url: url,
      indexPrefix: input.indexPrefix ?? "kaiba",
      authMode: authMode,
      username: input.username,
      verifyTLS: input.verifyTLS ?? true,
      requestTimeoutSeconds: timeoutCap.map { min(timeout, $0) } ?? timeout
    )
    let priorSecret = try storedSearchEngineSecret()
    let secret: String?
    if authMode == .none {
      secret = nil
    } else if let provided = input.secret, !provided.isEmpty {
      secret = provided
    } else if input.clearSecret {
      throw SearchEngineSettingsError.invalid(field: "searchEngine.secret")
    } else if let priorSecret, priorSecret.authMode == authMode.rawValue, priorSecret.target == target {
      secret = priorSecret.secret
    } else {
      throw SearchEngineSettingsError.invalid(field: "searchEngine.secret")
    }
    let engine: any SearchEngine
    do {
      engine = try makeEngine(settings, secret)
    } catch let error as KaibaConfigurationError {
      if case .invalid(let field) = error { throw SearchEngineSettingsError.invalid(field: field) }
      throw SearchEngineSettingsError.invalid(field: "searchEngine.settings")
    }
    let settingsStored = StoredSettingsForEncoding(settings: settings, explicitURL: explicitURL)
    let settingsData = try JSONEncoder().encode(settingsStored)
    guard let settingsJSON = String(data: settingsData, encoding: .utf8) else {
      throw SearchEngineSettingsError.invalid(field: "searchEngine.settings")
    }
    var secretRecord: String?
    if let secret {
      let data = try JSONEncoder().encode(StoredSecretForEncoding(authMode: authMode.rawValue, target: target, secret: secret))
      secretRecord = String(data: data, encoding: .utf8)
    }
    return ValidatedSearchSettings(settings: settings, secret: secret, engine: engine,
      settingsJSON: settingsJSON, secretRecord: secretRecord)
  }

  func persistSearchEngineSettings(json: String, secret: String?) throws {
    let settingsKey = try Self.normalizedSettingKey(Self.searchEngineSettingsKey, allowReserved: true)
    let secretKey = try Self.normalizedSettingKey(Self.searchEngineSecretKey, allowReserved: true)
    try driver.withDatabase { database in
      try database.transaction { db in
        try requireStoreAdministrator(in: db)
        try db.execute(
          "INSERT INTO app_settings(setting_key, value_json, updated_at) VALUES (?, jsonb(?), ?) ON CONFLICT(setting_key) DO UPDATE SET value_json = excluded.value_json, updated_at = excluded.updated_at",
          bindings: [.text(settingsKey), .text(json), .text(NoteStoreClock.system.now())]
        )
        if let secret {
          try db.execute(
            "INSERT INTO app_settings(setting_key, value_json, updated_at) VALUES (?, jsonb(?), ?) ON CONFLICT(setting_key) DO UPDATE SET value_json = excluded.value_json, updated_at = excluded.updated_at",
            bindings: [.text(secretKey), .text(secret), .text(NoteStoreClock.system.now())]
          )
        } else {
          try db.execute("DELETE FROM app_settings WHERE setting_key = ?", bindings: [.text(secretKey)])
        }
      }
    }
  }

  func sanitizedHealthDetail(_ detail: String, username: String?, secret: String?) -> String {
    var result = detail
    for value in [username, secret].compactMap({ $0 }) where !value.isEmpty {
      result = result.replacingOccurrences(of: value, with: "[redacted]")
    }
    return String(result.prefix(200))
  }
}

private struct StoredSettingsForEncoding: Encodable {
  var kind: String
  var url: String?
  var indexPrefix: String
  var authMode: String
  var username: String?
  var verifyTLS: Bool
  var requestTimeoutSeconds: Int

  init(settings: SearchEngineConnectionSettings, explicitURL: String?) {
    kind = settings.kind
    url = explicitURL
    indexPrefix = settings.indexPrefix
    authMode = settings.authMode.rawValue
    username = settings.username
    verifyTLS = settings.verifyTLS
    requestTimeoutSeconds = settings.requestTimeoutSeconds
  }
}

private struct StoredSecretForEncoding: Encodable {
  var authMode: String
  var target: String
  var secret: String
}
