import Foundation

public struct KaibaGraphQLErrorLocation: Codable, Equatable, Sendable {
  public var line: Int
  public var column: Int

  public init(line: Int, column: Int) {
    self.line = line
    self.column = column
  }
}

public struct KaibaGraphQLError: Codable, Equatable, Sendable {
  public var message: String
  public var locations: [KaibaGraphQLErrorLocation]?
  public var path: [KaibaJSONValue]?
  public var extensions: [String: KaibaJSONValue]?

  public init(
    message: String,
    locations: [KaibaGraphQLErrorLocation]? = nil,
    path: [KaibaJSONValue]? = nil,
    extensions: [String: KaibaJSONValue]? = nil
  ) {
    self.message = message
    self.locations = locations
    self.path = path
    self.extensions = extensions
  }
}

public enum KaibaClientError: Error, Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable {
  case invalidEndpoint(String)
  case invalidConfiguration(String)
  case invalidRequest(String)
  case invalidRegex
  case connectionFailed(Int?)
  case authFailed(Int)
  case httpFailed(Int)
  case invalidResponse(status: Int?, byteCount: Int)
  case graphqlFailed([KaibaGraphQLError], partialData: KaibaJSONValue?)
  case decodingFailed(String)
  case schemaUnavailable(String)

  public var code: String {
    switch self {
    case .invalidEndpoint: "invalid_endpoint"
    case .invalidConfiguration: "invalid_configuration"
    case .invalidRequest: "invalid_request"
    case .invalidRegex: "invalid_regex"
    case .connectionFailed: "connection_failed"
    case .authFailed: "auth_failed"
    case .httpFailed: "http_failed"
    case .invalidResponse: "invalid_response"
    case .graphqlFailed: "graphql_failed"
    case .decodingFailed: "decoding_failed"
    case .schemaUnavailable: "schema_unavailable"
    }
  }

  public var description: String {
    switch self {
    case let .invalidEndpoint(reason), let .invalidConfiguration(reason), let .invalidRequest(reason):
      return "\(code): \(Self.safe(reason))"
    case .invalidRegex:
      return "invalid_regex: the schema filter is not a valid regular expression"
    case let .connectionFailed(category):
      return "connection_failed\(category.map { ": category \($0)" } ?? "")"
    case let .authFailed(status), let .httpFailed(status):
      return "\(code): HTTP \(status)"
    case let .invalidResponse(status, byteCount):
      return "invalid_response: HTTP \(status.map(String.init) ?? "unknown"), \(byteCount) bytes"
    case .graphqlFailed:
      return "graphql_failed: the server rejected the GraphQL operation"
    case let .decodingFailed(path):
      return "decoding_failed: \(Self.safe(path))"
    case let .schemaUnavailable(reason):
      return "schema_unavailable: \(Self.safe(reason))"
    }
  }

  public var debugDescription: String {
    "KaibaClientError(\(code))"
  }

  public var customMirror: Mirror {
    Mirror(self, children: ["code": code], displayStyle: .enum)
  }

  static func safe(_ value: String) -> String {
    String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(256))
  }
}
