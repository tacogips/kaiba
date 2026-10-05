import Foundation

public struct KaibaEngineHitReason: Codable, Equatable, Sendable {
  public var kind: String
  public var tags: [String]
}

public struct KaibaEngineFacetBucket: Codable, Equatable, Sendable {
  public var value: String
  public var count: Int
}

public struct KaibaEngineTagFacetBucket: Codable, Equatable, Sendable {
  public var tagId: String
  public var name: String
  public var tagClass: String?
  public var count: Int
}

public struct KaibaEngineSearchFacets: Codable, Equatable, Sendable {
  public var tagClasses: [KaibaEngineFacetBucket]
  public var tags: [KaibaEngineTagFacetBucket]
}

public struct KaibaEngineSearchPagePayload: Codable, Equatable, Sendable {
  public var result: KaibaControlPlaneResult
  public var value: [KaibaEngineNoteHit]?
  public var facets: KaibaEngineSearchFacets?
}

public struct KaibaSearchEngineAdapterDescriptor: Codable, Equatable, Sendable {
  public var kind: String
  public var displayName: String
  public var authModes: [String]
  /// Server-resolved URL to prefill when this adapter is chosen with an empty URL.
  public var defaultURL: String?
}

public struct KaibaSearchEngineSettings: Codable, Equatable, Sendable {
  public var managedBy: String
  public var kind: String
  public var url: String?
  public var indexPrefix: String?
  public var authMode: String
  public var username: String?
  public var hasSecret: Bool
  public var verifyTLS: Bool
  public var requestTimeoutSeconds: Int
  public var adapters: [KaibaSearchEngineAdapterDescriptor]
  public var active: Bool
}

public struct KaibaSearchEngineSettingsPayload: Codable, Equatable, Sendable {
  public var result: KaibaControlPlaneResult
  public var value: KaibaSearchEngineSettings?
}

public struct KaibaSearchEngineSettingsInput: Codable, Equatable, Sendable {
  public var kind: String
  public var url: String?
  public var indexPrefix: String?
  public var authMode: String?
  public var username: String?
  public var secret: String?
  public var clearSecret: Bool?
  public var verifyTLS: Bool?
  public var requestTimeoutSeconds: Int?

  private enum CodingKeys: String, CodingKey {
    case kind, url, indexPrefix, authMode, username, secret, clearSecret, verifyTLS, requestTimeoutSeconds
  }

  public init(
    kind: String, url: String? = nil, indexPrefix: String? = nil, authMode: String? = nil,
    username: String? = nil, secret: String? = nil, clearSecret: Bool? = nil,
    verifyTLS: Bool? = nil, requestTimeoutSeconds: Int? = nil
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

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    try container.encodeIfPresent(url, forKey: .url)
    try container.encodeIfPresent(indexPrefix, forKey: .indexPrefix)
    try container.encodeIfPresent(authMode, forKey: .authMode)
    try container.encodeIfPresent(username, forKey: .username)
    try container.encodeIfPresent(secret, forKey: .secret)
    try container.encodeIfPresent(clearSecret, forKey: .clearSecret)
    try container.encodeIfPresent(verifyTLS, forKey: .verifyTLS)
    try container.encodeIfPresent(requestTimeoutSeconds, forKey: .requestTimeoutSeconds)
  }
}

public struct KaibaSearchEngineConnectionTestResult: Codable, Equatable, Sendable {
  public var available: Bool
  public var status: String
  public var detail: String
}

public struct KaibaSearchEngineConnectionTestPayload: Codable, Equatable, Sendable {
  public var result: KaibaControlPlaneResult
  public var value: KaibaSearchEngineConnectionTestResult?
}
