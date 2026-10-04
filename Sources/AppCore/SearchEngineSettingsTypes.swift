import Foundation

public enum SearchEngineAuthMode: String, CaseIterable, Codable, Equatable, Sendable {
  case none
  case basic
  case apiKey
}

public struct SearchEngineAdapterDescriptor: Equatable, Sendable {
  public var kind: String
  public var displayName: String
  public var authModes: [SearchEngineAuthMode]

  public init(kind: String, displayName: String, authModes: [SearchEngineAuthMode]) {
    self.kind = kind
    self.displayName = displayName
    self.authModes = authModes
  }
}

public struct SearchEngineConnectionSettings: Codable, Equatable, Sendable {
  public var kind: String
  public var url: String
  public var indexPrefix: String
  public var authMode: SearchEngineAuthMode
  public var username: String?
  public var verifyTLS: Bool
  public var requestTimeoutSeconds: Int

  public init(
    kind: String,
    url: String,
    indexPrefix: String = "kaiba",
    authMode: SearchEngineAuthMode = .none,
    username: String? = nil,
    verifyTLS: Bool = true,
    requestTimeoutSeconds: Int = 10
  ) {
    self.kind = kind
    self.url = url
    self.indexPrefix = indexPrefix
    self.authMode = authMode
    self.username = username
    self.verifyTLS = verifyTLS
    self.requestTimeoutSeconds = requestTimeoutSeconds
  }
}

public enum SearchEngineSettingsManagement: String, Equatable, Sendable {
  case config
  case store
  case unset = "default"
}

public struct SearchEngineSettingsView: Equatable, Sendable {
  public var managedBy: SearchEngineSettingsManagement
  public var kind: String
  public var url: String?
  public var indexPrefix: String?
  public var authMode: SearchEngineAuthMode
  public var username: String?
  public var hasSecret: Bool
  public var verifyTLS: Bool
  public var requestTimeoutSeconds: Int
  public var adapters: [SearchEngineAdapterDescriptor]
  public var active: Bool

  public init(
    managedBy: SearchEngineSettingsManagement,
    kind: String,
    url: String?,
    indexPrefix: String?,
    authMode: SearchEngineAuthMode,
    username: String?,
    hasSecret: Bool,
    verifyTLS: Bool,
    requestTimeoutSeconds: Int,
    adapters: [SearchEngineAdapterDescriptor],
    active: Bool
  ) {
    self.managedBy = managedBy
    self.kind = kind
    self.url = url
    self.indexPrefix = indexPrefix
    self.authMode = authMode
    self.username = username
    self.hasSecret = hasSecret
    self.verifyTLS = verifyTLS
    self.requestTimeoutSeconds = requestTimeoutSeconds
    self.adapters = adapters
    self.active = active
  }
}

public struct SearchEngineSettingsInput: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public var kind: String
  public var url: String?
  public var indexPrefix: String?
  public var authMode: String?
  public var username: String?
  public var secret: String?
  public var clearSecret: Bool
  public var verifyTLS: Bool?
  public var requestTimeoutSeconds: Int?

  public init(
    kind: String,
    url: String? = nil,
    indexPrefix: String? = nil,
    authMode: String? = nil,
    username: String? = nil,
    secret: String? = nil,
    clearSecret: Bool = false,
    verifyTLS: Bool? = nil,
    requestTimeoutSeconds: Int? = nil
  ) {
    self.kind = kind
    self.url = url
    self.indexPrefix = indexPrefix
    self.authMode = authMode
    self.username = username
    self.secret = secret
    self.clearSecret = clearSecret
    self.verifyTLS = verifyTLS
    self.requestTimeoutSeconds = requestTimeoutSeconds
  }

  public var description: String {
    "SearchEngineSettingsInput(kind: \(kind), url: \(String(describing: url)), " +
      "indexPrefix: \(String(describing: indexPrefix)), authMode: \(String(describing: authMode)), " +
      "username: \(String(describing: username)), secret: \(secret == nil ? "nil" : "[redacted]"), " +
      "clearSecret: \(clearSecret), verifyTLS: \(String(describing: verifyTLS)), " +
      "requestTimeoutSeconds: \(String(describing: requestTimeoutSeconds)))"
  }

  public var debugDescription: String { description }
}

public enum SearchEngineConnectionTestStatus: String, Equatable, Sendable {
  case available
  case unhealthy
  case unavailable
  case rejected
  case invalidResponse = "invalid-response"
  case invalidSettings = "invalid-settings"
}

public struct SearchEngineConnectionTestResult: Equatable, Sendable {
  public var available: Bool
  public var status: SearchEngineConnectionTestStatus
  public var detail: String

  public init(available: Bool, status: SearchEngineConnectionTestStatus, detail: String) {
    self.available = available
    self.status = status
    self.detail = detail
  }
}

public enum SearchEngineSettingsError: Error, Equatable, CustomStringConvertible {
  case managedByConfig
  case invalid(field: String)

  public var description: String {
    switch self {
    case .managedByConfig:
      "settings-managed-by-config"
    case let .invalid(field):
      "invalid-settings: \(field)"
    }
  }
}

public struct SearchEngineReloadOutcome: Equatable, Sendable {
  public var active: Bool
  public var indexIdentity: String?

  public init(active: Bool, indexIdentity: String?) {
    self.active = active
    self.indexIdentity = indexIdentity
  }
}
