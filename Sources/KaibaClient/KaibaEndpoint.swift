import Foundation

public enum KaibaTransportSecurity: Equatable, Sendable {
  case secureByDefault
  case allowInsecureRemoteHTTP
}

public struct KaibaEndpoint: Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable {
  let transportURL: URL
  public let isLoopback: Bool

  public init(
    _ source: URL,
    transportSecurity: KaibaTransportSecurity = .secureByDefault
  ) throws {
    guard var components = URLComponents(url: source, resolvingAgainstBaseURL: false),
          let rawScheme = components.scheme?.lowercased(),
          rawScheme == "http" || rawScheme == "https",
          let rawHost = components.host, !rawHost.isEmpty else {
      throw KaibaClientError.invalidEndpoint("an absolute HTTP(S) URL with a host is required")
    }
    guard components.user == nil, components.password == nil else {
      throw KaibaClientError.invalidEndpoint("URL user information is not allowed")
    }
    guard components.query == nil, components.fragment == nil else {
      throw KaibaClientError.invalidEndpoint("URL query and fragment components are not allowed")
    }
    try Self.validateExplicitAuthorityPort(in: source)
    guard !source.absoluteString.unicodeScalars.contains(where: {
      CharacterSet.controlCharacters.contains($0)
    }) else {
      throw KaibaClientError.invalidEndpoint("control characters are not allowed")
    }
    guard let decodedPath = components.percentEncodedPath.removingPercentEncoding,
          !decodedPath.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
          }) else {
      throw KaibaClientError.invalidEndpoint("encoded control characters are not allowed")
    }
    let decodedSegments = decodedPath.split(separator: "/").map(String.init)
    guard !decodedSegments.contains("."), !decodedSegments.contains("..") else {
      throw KaibaClientError.invalidEndpoint("dot path segments are not allowed")
    }
    let host = rawHost.lowercased()
    let loopback = Self.classifyLoopback(host)
    guard rawScheme == "https" || loopback || transportSecurity == .allowInsecureRemoteHTTP else {
      throw KaibaClientError.invalidEndpoint("remote HTTP requires allowInsecureRemoteHTTP")
    }
    components.scheme = rawScheme
    components.host = host
    if (rawScheme == "http" && components.port == 80)
      || (rawScheme == "https" && components.port == 443) {
      components.port = nil
    }
    if components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/" {
      components.percentEncodedPath = "/graphql"
    }
    guard let normalized = components.url else {
      throw KaibaClientError.invalidEndpoint("the endpoint could not be normalized")
    }
    transportURL = normalized
    isLoopback = loopback
  }

  /// A safe default for routine logging. Custom paths are opaque because the
  /// endpoint value does not know which bearer credential must be removed.
  public var description: String {
    guard URLComponents(url: transportURL, resolvingAgainstBaseURL: false)?.percentEncodedPath == "/graphql" else {
      return Self.redactedCustomPathDescription(transportURL)
    }
    return transportURL.absoluteString
  }

  public var debugDescription: String { description }

  public var customMirror: Mirror {
    Mirror(self, children: ["endpoint": description])
  }

  public func diagnosticDescription(authentication: KaibaAuthentication) -> String {
    authentication.redactedEndpointDiagnostic(transportURL.absoluteString)
  }

  private static func redactedCustomPathDescription(_ url: URL) -> String {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return "<redacted-endpoint>"
    }
    components.percentEncodedPath = "/"
    guard let base = components.url?.absoluteString else {
      return "<redacted-endpoint>"
    }
    return base + "<redacted>"
  }

  private static func validateExplicitAuthorityPort(in source: URL) throws {
    let rawValue = source.absoluteString
    guard let schemeSeparator = rawValue.range(of: "://") else { return }
    let authorityStart = schemeSeparator.upperBound
    let authorityEnd = rawValue[authorityStart...].firstIndex(where: { "/?#".contains($0) })
      ?? rawValue.endIndex
    let authority = rawValue[authorityStart..<authorityEnd]

    let portText: Substring?
    if authority.hasPrefix("[") {
      guard let closingBracket = authority.firstIndex(of: "]") else {
        throw KaibaClientError.invalidEndpoint("the endpoint port must be between 1 and 65535")
      }
      let suffix = authority[authority.index(after: closingBracket)...]
      guard !suffix.isEmpty else { return }
      guard suffix.first == ":" else {
        throw KaibaClientError.invalidEndpoint("the endpoint port must be between 1 and 65535")
      }
      portText = suffix.dropFirst()
    } else if let separator = authority.lastIndex(of: ":") {
      portText = authority[authority.index(after: separator)...]
    } else {
      portText = nil
    }

    guard let portText else { return }
    guard !portText.isEmpty,
          portText.utf8.allSatisfy({ (48...57).contains($0) }),
          let port = Int(portText),
          (1...65_535).contains(port) else {
      throw KaibaClientError.invalidEndpoint("the endpoint port must be between 1 and 65535")
    }
  }

  private static func classifyLoopback(_ rawHost: String) -> Bool {
    let unbracketed = rawHost.hasPrefix("[") && rawHost.hasSuffix("]")
      ? String(rawHost.dropFirst().dropLast())
      : rawHost
    let host = unbracketed.hasSuffix(".") ? String(unbracketed.dropLast()) : unbracketed
    if host == "localhost" || host == "::1" { return true }
    let octets = host.split(separator: ".")
    return octets.count == 4 && octets.first == "127" && octets.allSatisfy {
      guard let value = Int($0) else { return false }
      return (0...255).contains(value)
    }
  }
}
