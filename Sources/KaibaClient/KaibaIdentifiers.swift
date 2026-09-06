import Foundation

public protocol KaibaIdentifier: RawRepresentable, Codable, Hashable, Sendable where RawValue == String {}

public struct KaibaNoteID: KaibaIdentifier { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct KaibaNotebookID: KaibaIdentifier { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct KaibaTagID: KaibaIdentifier { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct KaibaFileID: KaibaIdentifier { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct KaibaCommentID: KaibaIdentifier { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct KaibaAutoActionID: KaibaIdentifier { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }

public enum KaibaOperationStatus: Codable, Equatable, Sendable {
  case ok
  case notFound
  case invalidRequest
  case forbidden
  case custom(String)

  public init(from decoder: Decoder) throws {
    switch try decoder.singleValueContainer().decode(String.self) {
    case "ok": self = .ok
    case "not_found": self = .notFound
    case "invalid_request": self = .invalidRequest
    case "forbidden": self = .forbidden
    case let value: self = .custom(value)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .ok: try container.encode("ok")
    case .notFound: try container.encode("not_found")
    case .invalidRequest: try container.encode("invalid_request")
    case .forbidden: try container.encode("forbidden")
    case let .custom(value): try container.encode(value)
    }
  }
}

public enum KaibaAttachmentRole: Codable, Equatable, Sendable {
  case related
  case embedded
  case sourcePageImage
  case sourceDocument
  case custom(String)

  public init(from decoder: Decoder) throws {
    switch try decoder.singleValueContainer().decode(String.self) {
    case "related": self = .related
    case "embedded": self = .embedded
    case "source-page-image": self = .sourcePageImage
    case "source-document": self = .sourceDocument
    case let value: self = .custom(value)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public var rawValue: String {
    switch self {
    case .related: "related"
    case .embedded: "embedded"
    case .sourcePageImage: "source-page-image"
    case .sourceDocument: "source-document"
    case let .custom(value): value
    }
  }
}
