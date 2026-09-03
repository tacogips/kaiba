import Foundation

public struct KaibaConfiguration: Codable, Equatable, Sendable {
  public var database: KaibaDatabaseConfiguration
  public var storageProfiles: [KaibaS3ProfileConfiguration]
  public var libraries: [KaibaLibraryBinding]
  public var importSettings: KaibaImportConfiguration?
  public var ai: KaibaAIConfiguration?

  public init(
    database: KaibaDatabaseConfiguration = .sqlite(path: nil),
    storageProfiles: [KaibaS3ProfileConfiguration] = [],
    libraries: [KaibaLibraryBinding] = [],
    importSettings: KaibaImportConfiguration? = nil,
    ai: KaibaAIConfiguration? = nil
  ) {
    self.database = database
    self.storageProfiles = storageProfiles
    self.libraries = libraries
    self.importSettings = importSettings
    self.ai = ai
  }

  private enum CodingKeys: String, CodingKey {
    case database
    case storageProfiles
    case libraries
    case importSettings = "import"
    case ai
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    database = try container.decodeIfPresent(
      KaibaDatabaseConfiguration.self,
      forKey: .database
    ) ?? .sqlite(path: nil)
    storageProfiles = try container.decodeIfPresent(
      [KaibaS3ProfileConfiguration].self,
      forKey: .storageProfiles
    ) ?? []
    libraries = try container.decodeIfPresent(
      [KaibaLibraryBinding].self,
      forKey: .libraries
    ) ?? []
    importSettings = try container.decodeIfPresent(
      KaibaImportConfiguration.self,
      forKey: .importSettings
    )
    ai = try container.decodeIfPresent(KaibaAIConfiguration.self, forKey: .ai)
  }

  public func libraryBinding(named name: String) -> KaibaLibraryBinding? {
    libraries.first { $0.name.lowercased() == name.lowercased() }
  }

  /// The environment variables a library's storage reads from. Names only:
  /// the config never holds a secret, and neither does this output.
  public func environmentVariableNames(forLibrary name: String) -> [String] {
    guard let binding = libraryBinding(named: name),
          let profileName = binding.storageProfile,
          let profile = storageProfiles.first(where: { $0.name == profileName }) else {
      return []
    }
    return [profile.accessKeyIdEnvironmentVariable, profile.secretAccessKeyEnvironmentVariable]
  }
}

/// Binds a library to the credential scope it reads from. Policy — whether the
/// library requires authentication — lives in the store, not here: two sources
/// of truth for one flag is how they drift (`design-docs/specs/library.md`).
public struct KaibaLibraryBinding: Codable, Equatable, Sendable {
  public var name: String
  /// The kinko scope supplying this library's secrets, e.g.
  /// `logical:kaiba/shared`. Defaults to `logical:kaiba/<name>` when absent.
  public var kinkoPath: String?
  /// A `storageProfiles` entry this library's attachments live in.
  public var storageProfile: String?

  public init(name: String, kinkoPath: String? = nil, storageProfile: String? = nil) {
    self.name = name
    self.kinkoPath = kinkoPath
    self.storageProfile = storageProfile
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
  public var translate: KaibaTranslateConfiguration?
  /// Personal-agent runtime settings (`design-docs/specs/user-agent-tools.md`,
  /// UA6). Nil applies every default, so the feature is on unless disabled.
  public var userAgent: KaibaUserAgentConfiguration?

  public init(
    agent: KaibaAgentBackendConfiguration? = nil,
    autoTag: KaibaAutoTagConfiguration? = nil,
    translate: KaibaTranslateConfiguration? = nil,
    userAgent: KaibaUserAgentConfiguration? = nil
  ) {
    self.agent = agent
    self.autoTag = autoTag
    self.translate = translate
    self.userAgent = userAgent
  }

  public var autoTagEnabled: Bool {
    autoTag?.auto == .on
  }
}

/// Settings for the personal agent runtime: chat turns that run on a user's
/// own provider credential with kaiba's operations exposed as in-process
/// tools (`design-docs/specs/user-agent-tools.md`). Every field is optional
/// in `config.json`; the resolved accessors below supply the defaults.
public struct KaibaUserAgentConfiguration: Codable, Equatable, Sendable {
  public static let defaultMaxToolRounds = 24
  public static let maximumConfigurableToolRounds = 200

  /// `false` hides the credential surface and routes every chat to the
  /// server-configured runtime.
  public var enabled: Bool?
  /// Whether a user may point their credential at a custom `baseURL`
  /// (`openai-compatible` requires one). Off by default because the server
  /// would open outbound connections to a user-chosen host.
  public var allowCustomBaseURL: Bool?
  /// Upper bound on provider round trips per chat turn.
  public var maxToolRounds: Int?

  public init(enabled: Bool? = nil, allowCustomBaseURL: Bool? = nil, maxToolRounds: Int? = nil) {
    self.enabled = enabled
    self.allowCustomBaseURL = allowCustomBaseURL
    self.maxToolRounds = maxToolRounds
  }

  public var isEnabled: Bool { enabled ?? true }
  public var customBaseURLAllowed: Bool { allowCustomBaseURL ?? false }
  public var resolvedMaxToolRounds: Int {
    let rounds = maxToolRounds ?? Self.defaultMaxToolRounds
    return min(max(rounds, 1), Self.maximumConfigurableToolRounds)
  }
}

public extension Optional where Wrapped == KaibaAIConfiguration {
  /// The personal-agent settings with defaults applied even when `ai` or
  /// `ai.userAgent` is absent from `config.json`.
  var resolvedUserAgent: KaibaUserAgentConfiguration {
    self?.userAgent ?? KaibaUserAgentConfiguration()
  }
}

/// Notebook translation settings. `provider`/`model` override the agent
/// defaults for translation requests only, so translations can run on a
/// different agent-gateway vendor than chat and tagging. Set `model` whenever
/// `provider` differs from `ai.agent.provider` — model ids are vendor-specific.
public struct KaibaTranslateConfiguration: Codable, Equatable, Sendable {
  public var provider: String?
  public var model: String?
  /// Used by `kaiba ai translate` when `--to` is omitted.
  public var defaultTargetLanguage: String?

  public init(
    provider: String? = nil,
    model: String? = nil,
    defaultTargetLanguage: String? = nil
  ) {
    self.provider = provider
    self.model = model
    self.defaultTargetLanguage = defaultTargetLanguage
  }
}

public struct KaibaAgentBackendConfiguration: Codable, Equatable, Sendable {
  /// The only recognized backend today, served by the agent-gateway adapter
  /// (`design-docs/specs/ai-agent-integration.md`).
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
  /// `path` overrides the default `<note-root>/note-store.sqlite` location.
  case sqlite(path: String?)
  case turso(TursoHTTPConfiguration)

  private enum CodingKeys: String, CodingKey {
    case kind
    case path
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
      self = .sqlite(path: try container.decodeIfPresent(String.self, forKey: .path))
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
    case .sqlite(let path):
      try container.encode(Kind.sqlite, forKey: .kind)
      try container.encodeIfPresent(path, forKey: .path)
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

  /// Resolves the local sqlite file location. Precedence: `KAIBA_SQLITE_PATH`
  /// environment variable, then the configured `database.path`, then the
  /// default `<note-root>/note-store.sqlite`.
  public static func resolveSQLiteDatabasePath(
    configuredPath: String?,
    noteRoot: String,
    environment: [String: String]
  ) -> String {
    if let env = environment["KAIBA_SQLITE_PATH"], !env.isEmpty {
      return (env as NSString).expandingTildeInPath
    }
    if let configuredPath, !configuredPath.isEmpty {
      return (configuredPath as NSString).expandingTildeInPath
    }
    return SQLiteNoteDatabaseDriver.defaultDatabasePath(noteRoot: noteRoot)
  }

  public static func makeDriver(
    configuration: KaibaDatabaseConfiguration,
    noteRoot: String,
    environment: [String: String]
  ) throws -> any NoteDatabaseDriving {
    switch configuration {
    case .sqlite(let path):
      let databasePath = resolveSQLiteDatabasePath(
        configuredPath: path,
        noteRoot: noteRoot,
        environment: environment
      )
      try ensureParentDirectoryExists(of: databasePath)
      return SQLiteNoteDatabaseDriver(databasePath: databasePath)
    case .turso(let turso):
      guard let url = URL(string: turso.url) else {
        throw KaibaConfigurationError.invalid("database.url")
      }
      guard let token = environment[turso.authTokenEnvironmentVariable] else {
        throw KaibaConfigurationError.missingEnvironmentVariable(
          turso.authTokenEnvironmentVariable
        )
      }
      let databasePath = resolveSQLiteDatabasePath(
        configuredPath: nil,
        noteRoot: noteRoot,
        environment: environment
      )
      try ensureParentDirectoryExists(of: databasePath)
      return try TursoNoteDatabaseDriver(
        databasePath: databasePath,
        configuration: TursoDatabaseConfiguration(
          url: url,
          authToken: token,
          allowInsecureLoopbackHTTP: turso.allowInsecureLoopbackHTTP
        )
      )
    }
  }

  private static func ensureParentDirectoryExists(of databasePath: String) throws {
    let parent = URL(fileURLWithPath: databasePath).deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
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
