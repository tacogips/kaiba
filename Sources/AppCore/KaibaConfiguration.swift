import Foundation

public struct KaibaConfiguration: Codable, Equatable, Sendable {
  public var database: KaibaDatabaseConfiguration
  public var storageProfiles: [KaibaS3ProfileConfiguration]
  public var importSettings: KaibaImportConfiguration?
  public var ai: KaibaAIConfiguration?

  public init(
    database: KaibaDatabaseConfiguration = .sqlite,
    storageProfiles: [KaibaS3ProfileConfiguration] = [],
    importSettings: KaibaImportConfiguration? = nil,
    ai: KaibaAIConfiguration? = nil
  ) {
    self.database = database
    self.storageProfiles = storageProfiles
    self.importSettings = importSettings
    self.ai = ai
  }

  private enum CodingKeys: String, CodingKey {
    case database
    case storageProfiles
    case importSettings = "import"
    case ai
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    database = try container.decodeIfPresent(
      KaibaDatabaseConfiguration.self,
      forKey: .database
    ) ?? .sqlite
    storageProfiles = try container.decodeIfPresent(
      [KaibaS3ProfileConfiguration].self,
      forKey: .storageProfiles
    ) ?? []
    importSettings = try container.decodeIfPresent(
      KaibaImportConfiguration.self,
      forKey: .importSettings
    )
    ai = try container.decodeIfPresent(KaibaAIConfiguration.self, forKey: .ai)
  }
}

/// Document import settings (`design-docs/specs/document-import.md`). Paths
/// and credential environment-variable names may appear here; secret values
/// never do.
public struct KaibaImportConfiguration: Codable, Equatable, Sendable {
  public var ocr: KaibaOCRConfiguration?

  public init(ocr: KaibaOCRConfiguration? = nil) {
    self.ocr = ocr
  }
}

/// AI OCR settings for standalone image imports. OCR is routed through the
/// installed agent-gateway CLI so vendor and model selection stay explicit.
public struct KaibaOCRConfiguration: Codable, Equatable, Sendable {
  public var commandPath: String?
  public var vendor: String
  public var model: String
  /// Environment-variable NAME for a provider credential, never its value.
  public var apiKeyEnvironmentVariable: String?

  public init(
    commandPath: String? = nil,
    vendor: String,
    model: String,
    apiKeyEnvironmentVariable: String? = nil
  ) {
    self.commandPath = commandPath
    self.vendor = vendor
    self.model = model
    self.apiKeyEnvironmentVariable = apiKeyEnvironmentVariable
  }
}

/// AI settings (`design-docs/specs/ai-agent-integration.md`). Provider
/// credentials never appear here; they are the agent runtime's env-routing
/// concern.
public struct KaibaAIConfiguration: Codable, Equatable, Sendable {
  public var agent: KaibaAgentBackendConfiguration?
  public var autoTag: KaibaAutoTagConfiguration?

  public init(
    agent: KaibaAgentBackendConfiguration? = nil,
    autoTag: KaibaAutoTagConfiguration? = nil
  ) {
    self.agent = agent
    self.autoTag = autoTag
  }

  public var autoTagEnabled: Bool {
    autoTag?.auto == .on
  }
}

public struct KaibaAgentBackendConfiguration: Codable, Equatable, Sendable {
  /// The only recognized backend today; the concrete invoker arrives with the
  /// agent-gateway adapter (impl-plans/active/agent-gateway-adapter.md).
  public static let agentGatewayCLIBackend = "agent-gateway-cli"

  public var backend: String
  public var commandPath: String?
  /// agent-gateway vendor: claude-code, codex, cursor, openai, anthropic,
  /// gemini, or openrouter.
  public var provider: String?
  public var model: String?
  /// Environment-variable NAME for the provider credential (never a value);
  /// the gateway's per-vendor default applies when absent.
  public var apiKeyEnvironmentVariable: String?

  public init(
    backend: String,
    commandPath: String? = nil,
    provider: String? = nil,
    model: String? = nil,
    apiKeyEnvironmentVariable: String? = nil
  ) {
    self.backend = backend
    self.commandPath = commandPath
    self.provider = provider
    self.model = model
    self.apiKeyEnvironmentVariable = apiKeyEnvironmentVariable
  }
}

public struct KaibaAutoTagConfiguration: Codable, Equatable, Sendable {
  public enum Toggle: String, Codable, Equatable, Sendable {
    case on
    case off
  }

  public var auto: Toggle

  public init(auto: Toggle = .off) {
    self.auto = auto
  }
}

public struct KaibaS3ProfileConfiguration: Codable, Equatable, Sendable {
  public var name: String
  public var endpoint: String
  public var region: String
  public var bucket: String
  public var accessKeyIdEnvironmentVariable: String
  public var secretAccessKeyEnvironmentVariable: String
  public var keyPrefix: String

  public init(
    name: String,
    endpoint: String,
    region: String,
    bucket: String,
    accessKeyIdEnvironmentVariable: String,
    secretAccessKeyEnvironmentVariable: String,
    keyPrefix: String = ""
  ) {
    self.name = name
    self.endpoint = endpoint
    self.region = region
    self.bucket = bucket
    self.accessKeyIdEnvironmentVariable = accessKeyIdEnvironmentVariable
    self.secretAccessKeyEnvironmentVariable = secretAccessKeyEnvironmentVariable
    self.keyPrefix = keyPrefix
  }
}

public enum KaibaDatabaseConfiguration: Codable, Equatable, Sendable {
  case sqlite
  case turso(TursoHTTPConfiguration)

  private enum CodingKeys: String, CodingKey {
    case kind
    case url
    case authTokenEnvironmentVariable
    case allowInsecureLoopbackHTTP
  }

  private enum Kind: String, Codable {
    case sqlite
    case turso
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .sqlite:
      self = .sqlite
    case .turso:
      self = .turso(TursoHTTPConfiguration(
        url: try container.decode(String.self, forKey: .url),
        authTokenEnvironmentVariable: try container.decode(
          String.self,
          forKey: .authTokenEnvironmentVariable
        ),
        allowInsecureLoopbackHTTP: try container.decodeIfPresent(
          Bool.self,
          forKey: .allowInsecureLoopbackHTTP
        ) ?? false
      ))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .sqlite:
      try container.encode(Kind.sqlite, forKey: .kind)
    case .turso(let configuration):
      try container.encode(Kind.turso, forKey: .kind)
      try container.encode(configuration.url, forKey: .url)
      try container.encode(
        configuration.authTokenEnvironmentVariable,
        forKey: .authTokenEnvironmentVariable
      )
      try container.encode(
        configuration.allowInsecureLoopbackHTTP,
        forKey: .allowInsecureLoopbackHTTP
      )
    }
  }
}

public struct TursoHTTPConfiguration: Codable, Equatable, Sendable {
  public var url: String
  public var authTokenEnvironmentVariable: String
  public var allowInsecureLoopbackHTTP: Bool

  public init(
    url: String,
    authTokenEnvironmentVariable: String,
    allowInsecureLoopbackHTTP: Bool = false
  ) {
    self.url = url
    self.authTokenEnvironmentVariable = authTokenEnvironmentVariable
    self.allowInsecureLoopbackHTTP = allowInsecureLoopbackHTTP
  }
}

public enum KaibaConfigurationError: Error, Equatable, Sendable {
  case unreadable(String)
  case invalid(String)
  case missingEnvironmentVariable(String)
}

public enum KaibaConfigurationLoader {
  public static func load(at path: String, required: Bool) throws -> KaibaConfiguration {
    guard FileManager.default.fileExists(atPath: path) else {
      if required {
        throw KaibaConfigurationError.unreadable(path)
      }
      return KaibaConfiguration()
    }
    do {
      let data = try Data(contentsOf: URL(fileURLWithPath: path))
      return try JSONDecoder().decode(KaibaConfiguration.self, from: data)
    } catch {
      throw KaibaConfigurationError.invalid(path)
    }
  }

  public static func makeDriver(
    configuration: KaibaDatabaseConfiguration,
    noteRoot: String,
    environment: [String: String]
  ) throws -> any NoteDatabaseDriving {
    switch configuration {
    case .sqlite:
      return SQLiteNoteDatabaseDriver(noteRoot: noteRoot)
    case .turso(let turso):
      guard let url = URL(string: turso.url) else {
        throw KaibaConfigurationError.invalid("database.url")
      }
      guard let token = environment[turso.authTokenEnvironmentVariable] else {
        throw KaibaConfigurationError.missingEnvironmentVariable(
          turso.authTokenEnvironmentVariable
        )
      }
      return try TursoNoteDatabaseDriver(
        noteRoot: noteRoot,
        configuration: TursoDatabaseConfiguration(
          url: url,
          authToken: token,
          allowInsecureLoopbackHTTP: turso.allowInsecureLoopbackHTTP
        )
      )
    }
  }

  public static func makeS3Profiles(
    configuration: KaibaConfiguration,
    environment: [String: String]
  ) throws -> [S3StorageProfile] {
    try configuration.storageProfiles.map { profile in
      guard let endpoint = URL(string: profile.endpoint), endpoint.scheme != nil else {
        throw KaibaConfigurationError.invalid("storageProfiles.\(profile.name).endpoint")
      }
      return try S3StorageProfile.environmentBacked(
        name: profile.name,
        endpoint: endpoint,
        region: profile.region,
        bucket: profile.bucket,
        accessKeyIdEnv: profile.accessKeyIdEnvironmentVariable,
        secretAccessKeyEnv: profile.secretAccessKeyEnvironmentVariable,
        keyPrefix: profile.keyPrefix,
        environment: environment
      )
    }
  }
}
