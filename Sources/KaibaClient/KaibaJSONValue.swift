import Foundation

public enum KaibaJSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case integer(Int)
  case double(Double)
  case string(String)
  case array([KaibaJSONValue])
  case object([String: KaibaJSONValue])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Double.self) {
      self = .double(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([KaibaJSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: KaibaJSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case let .bool(value): try container.encode(value)
    case let .integer(value): try container.encode(value)
    case let .double(value): try container.encode(value)
    case let .string(value): try container.encode(value)
    case let .array(value): try container.encode(value)
    case let .object(value): try container.encode(value)
    }
  }
}

extension KaibaJSONValue {
  public var objectValue: [String: KaibaJSONValue]? {
    guard case let .object(value) = self else { return nil }
    return value
  }

  public var arrayValue: [KaibaJSONValue]? {
    guard case let .array(value) = self else { return nil }
    return value
  }

  public var stringValue: String? {
    guard case let .string(value) = self else { return nil }
    return value
  }
}
