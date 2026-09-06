import Foundation

struct KaibaRedaction: Sendable {
  private let activeToken: String?

  init(authentication: KaibaAuthentication) {
    if case let .bearer(token) = authentication {
      activeToken = token.rawValue
    } else {
      activeToken = nil
    }
  }

  func text(_ source: String) -> String {
    var value = source
    if let activeToken {
      for tokenRepresentation in Self.tokenRepresentations(activeToken) {
        value = value.replacingOccurrences(of: tokenRepresentation, with: "<redacted>")
      }
    }
    let authorizationPattern =
      #"(?i)(?:[\\\"'`\[]+)?[\p{L}\p{M}\p{N}\p{Pc}-]*authorization(?:[ \t_-]*header)?(?![\p{L}\p{M}\p{N}\p{Pc}])(?:[^a-z0-9\r\n,;:=]*(?::|=)\s*|\s+)[^\r\n,;]+"#
    let patterns = [
      #"(?i)\b((?:https?|wss?)://)[^/\s@]+@"#,
      authorizationPattern,
      #"(?i)\bbearer\s+[^\s,;]+"#
    ]
    for (index, pattern) in patterns.enumerated() {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let range = NSRange(value.startIndex..., in: value)
      value = regex.stringByReplacingMatches(
        in: value,
        range: range,
        withTemplate: index == 0 ? "$1<redacted>@" : "<redacted>"
      )
    }
    return KaibaClientError.safe(value)
  }

  func identifier(_ source: String) throws -> String {
    guard text(source) == source else {
      throw KaibaClientError.schemaUnavailable("introspection contains a tainted identifier")
    }
    return source
  }

  func endpoint(_ source: String) -> String {
    guard var components = URLComponents(string: source),
          components.scheme != nil,
          components.host != nil else {
      return "<redacted-endpoint>"
    }
    components.user = nil
    components.password = nil
    components.query = nil
    components.fragment = nil
    let path = components.percentEncodedPath
    guard !path.isEmpty, path != "/", path != "/graphql" else {
      return components.string.map(text) ?? "<redacted-endpoint>"
    }
    let marker = "__KAIBA_REDACTED_CREDENTIAL__"
    components.path = "/\(marker)"
    guard let rendered = components.string else { return "<redacted-endpoint>" }
    return text(rendered).replacingOccurrences(of: marker, with: "<redacted>")
  }

  private static func tokenRepresentations(_ token: String) -> [String] {
    var representations = Set([token])
    var pathCharacters = CharacterSet.alphanumerics
    pathCharacters.insert(charactersIn: "-._~")
    if let encoded = token.addingPercentEncoding(withAllowedCharacters: pathCharacters) {
      representations.insert(encoded)
      representations.insert(lowercasedPercentEscapes(encoded))
    }
    return representations.sorted {
      $0.count == $1.count ? $0 < $1 : $0.count > $1.count
    }
  }

  private static func lowercasedPercentEscapes(_ source: String) -> String {
    let characters = Array(source)
    var result = ""
    var index = 0
    while index < characters.count {
      if characters[index] == "%", index + 2 < characters.count {
        result.append("%")
        result.append(contentsOf: String(characters[index + 1]).lowercased())
        result.append(contentsOf: String(characters[index + 2]).lowercased())
        index += 3
      } else {
        result.append(characters[index])
        index += 1
      }
    }
    return result
  }
}

extension KaibaAuthentication {
  public func redactedDiagnostic(_ source: String) -> String {
    KaibaRedaction(authentication: self).text(source)
  }

  public func redactedEndpointDiagnostic(_ source: String) -> String {
    KaibaRedaction(authentication: self).endpoint(source)
  }
}
