import Foundation

public struct KaibaConfiguration: Codable, Equatable, Sendable {
  public var database: KaibaDatabaseConfiguration
  public var storageProfiles: [KaibaS3ProfileConfiguration]

  public init(
    database: KaibaDatabaseConfiguration = .sqlite,
    storageProfiles: [KaibaS3ProfileConfiguration] = []
  ) {
    self.database = database
    self.storageProfiles = storageProfiles
  }

  private enum CodingKeys: String, CodingKey {
    case database
    case storageProfiles
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
