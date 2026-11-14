import Foundation

public struct KaibaBearerToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable {
  let rawValue: String

  public init(_ value: String) throws {
    guard !value.isEmpty,
          value == value.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
      throw KaibaClientError.invalidConfiguration("bearer token is empty or contains whitespace/control characters")
    }
    rawValue = value
  }

  public var description: String { "<redacted>" }
  public var debugDescription: String { "<redacted>" }
  public var customMirror: Mirror {
    Mirror(self, children: ["rawValue": "<redacted>"], displayStyle: .struct)
  }
}

public enum KaibaAuthentication: Sendable {
  case bearer(KaibaBearerToken)
  case unauthenticated

  public var mode: KaibaAuthenticationMode {
    switch self {
    case .bearer: .bearer
    case .unauthenticated: .unauthenticated
    }
  }
}

public enum KaibaAuthenticationMode: String, Codable, Equatable, Sendable {
  case bearer
  case unauthenticated
}

public struct KaibaClientConfiguration: Equatable, Sendable {
  public static let maximumRequestTimeout: TimeInterval = 86_400

  public var requestTimeout: TimeInterval
  public var transportSecurity: KaibaTransportSecurity
  public var maximumRequestBytes: Int
  public var maximumResponseBytes: Int
  public var allowRemoteUnauthenticated: Bool

  public init(
    requestTimeout: TimeInterval = 10,
    transportSecurity: KaibaTransportSecurity = .secureByDefault,
    maximumRequestBytes: Int = 2 * 1_024 * 1_024,
    maximumResponseBytes: Int = 8 * 1_024 * 1_024,
    allowRemoteUnauthenticated: Bool = false
  ) throws {
    self.requestTimeout = requestTimeout
    self.transportSecurity = transportSecurity
    self.maximumRequestBytes = maximumRequestBytes
    self.maximumResponseBytes = maximumResponseBytes
    self.allowRemoteUnauthenticated = allowRemoteUnauthenticated
    try validate()
  }

  func validate() throws {
    try Self.validateRequestTimeout(requestTimeout)
    guard maximumRequestBytes > 0, maximumResponseBytes > 0 else {
      throw KaibaClientError.invalidConfiguration("byte limits must be positive")
    }
  }

  static func validateRequestTimeout(_ timeout: TimeInterval) throws {
    guard timeout.isFinite, timeout > 0, timeout <= maximumRequestTimeout else {
      throw KaibaClientError.invalidConfiguration(
        "request timeout must be finite, positive, and at most \(Int(maximumRequestTimeout)) seconds"
      )
    }
  }
}
