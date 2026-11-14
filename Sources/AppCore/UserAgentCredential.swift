import Foundation

/// The provider a personal-agent credential talks to
/// (`design-docs/specs/user-agent-tools.md`, UA2). The raw values are the
/// stored `provider` column and the strings accepted by every surface.
public enum UserAgentProvider: String, Codable, Equatable, Sendable, CaseIterable {
  case anthropic
  case openai
  case openrouter
  case openaiCompatible = "openai-compatible"

  /// The wire format the runtime speaks for this provider.
  public var wireFormat: UserAgentWireFormat {
    switch self {
    case .anthropic: return .anthropicMessages
    case .openai, .openrouter, .openaiCompatible: return .openAIChatCompletions
    }
  }

  /// The endpoint used when the credential carries no `baseURL`. Nil means a
  /// base URL is mandatory.
  public var defaultBaseURL: URL? {
    switch self {
    case .anthropic: return URL(string: "https://api.anthropic.com")
    case .openai: return URL(string: "https://api.openai.com/v1")
    case .openrouter: return URL(string: "https://openrouter.ai/api/v1")
    case .openaiCompatible: return nil
    }
  }

  public var requiresBaseURL: Bool {
    defaultBaseURL == nil
  }
}

public enum UserAgentWireFormat: String, Codable, Equatable, Sendable {
  case anthropicMessages = "anthropic-messages"
  case openAIChatCompletions = "openai-chat-completions"
}

/// The stored credential. This type never leaves `AppCore`: it carries the
/// secret and exists only so the dispatcher can build a runtime for one turn.
struct UserAgentCredential: Equatable, Sendable {
  var userId: UserID
  var provider: UserAgentProvider
  var apiKey: String
  var baseURL: URL?
  var defaultModel: String
  var enabled: Bool
  var createdAt: String
  var updatedAt: String

  /// The endpoint the runtime targets.
  var resolvedBaseURL: URL? {
    baseURL ?? provider.defaultBaseURL
  }

  var summary: UserAgentCredentialSummary {
    UserAgentCredentialSummary(
      provider: provider,
      keyHint: UserAgentCredentialValidation.keyHint(for: apiKey),
      baseURL: baseURL?.absoluteString,
      defaultModel: defaultModel,
      enabled: enabled,
      updatedAt: updatedAt
    )
  }
}

/// What callers may learn about a stored credential. `keyHint` is the last
/// four characters of the key; the key itself is never projected.
public struct UserAgentCredentialSummary: Codable, Equatable, Sendable {
  public var provider: UserAgentProvider
  public var keyHint: String
  public var baseURL: String?
  public var defaultModel: String
  public var enabled: Bool
  public var updatedAt: String

  public init(
    provider: UserAgentProvider,
    keyHint: String,
    baseURL: String?,
    defaultModel: String,
    enabled: Bool,
    updatedAt: String
  ) {
    self.provider = provider
    self.keyHint = keyHint
    self.baseURL = baseURL
    self.defaultModel = defaultModel
    self.enabled = enabled
    self.updatedAt = updatedAt
  }
}

/// Input for storing a credential. `apiKey` is validated but otherwise stored
/// verbatim; `baseURL` is validated against the operator's
/// `ai.userAgent.allowCustomBaseURL` policy at write time.
public struct UserAgentCredentialInput: Equatable, Sendable {
  public var provider: UserAgentProvider
  public var apiKey: String
  public var defaultModel: String
  public var baseURL: String?
  public var enabled: Bool

  public init(
    provider: UserAgentProvider,
    apiKey: String,
    defaultModel: String,
    baseURL: String? = nil,
    enabled: Bool = true
  ) {
    self.provider = provider
    self.apiKey = apiKey
    self.defaultModel = defaultModel
    self.baseURL = baseURL
    self.enabled = enabled
  }
}

public enum UserAgentCredentialValidation {
  public static let maximumKeyLength = 4096
  public static let maximumModelLength = 200
  public static let maximumBaseURLLength = 512

  static func keyHint(for apiKey: String) -> String {
    String(apiKey.suffix(4))
  }

  static func validatedKey(_ apiKey: String) throws -> String {
    guard !apiKey.isEmpty, apiKey.count <= maximumKeyLength else {
      throw NoteServiceError.invalidInput("apiKey must be 1-\(maximumKeyLength) characters")
    }
    guard apiKey.unicodeScalars.allSatisfy({ scalar in
      scalar.isASCII && scalar.value > 0x20 && scalar.value < 0x7F
    }) else {
      throw NoteServiceError.invalidInput(
        "apiKey must contain only printable ASCII without whitespace"
      )
    }
    return apiKey
  }

  static func validatedModel(_ model: String) throws -> String {
    let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= maximumModelLength,
      !trimmed.contains(where: { $0.isNewline })
    else {
      throw NoteServiceError.invalidInput("defaultModel must be 1-\(maximumModelLength) characters")
    }
    return trimmed
  }

  /// Applies UA2: a custom endpoint needs operator permission, and providers
  /// without a default endpoint need one.
  static func validatedBaseURL(
    _ raw: String?,
    provider: UserAgentProvider,
    customBaseURLAllowed: Bool
  ) throws -> URL? {
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else {
      if provider.requiresBaseURL {
        throw NoteServiceError.invalidInput(
          "provider \(provider.rawValue) requires baseURL"
        )
      }
      return nil
    }
    guard customBaseURLAllowed else {
      throw NoteServiceError.invalidInput(
        "custom baseURL is not permitted on this server (ai.userAgent.allowCustomBaseURL is off)"
      )
    }
    guard trimmed.count <= maximumBaseURLLength,
      let components = URLComponents(string: trimmed),
      let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil,
      let url = components.url
    else {
      throw NoteServiceError.invalidInput(
        "baseURL must be an http(s) URL with a host and no credentials, query, or fragment"
      )
    }
    return url
  }
}
