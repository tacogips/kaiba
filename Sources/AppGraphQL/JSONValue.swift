import Foundation

/// A JSON value model that canonicalizes integral decoded numbers to
/// `.integer`, so `1.0` may re-encode as `1`.
public enum JSONValue: Codable, Equatable, Sendable {
  private static let maxExactlyRepresentableIntegerAsDouble: Int64 = 9_007_199_254_740_992

  case null
  case bool(Bool)
  case integer(Int64)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
    switch (lhs, rhs) {
    case (.null, .null):
      return true
    case let (.bool(lhs), .bool(rhs)):
      return lhs == rhs
    case let (.integer(lhs), .integer(rhs)):
      return lhs == rhs
    case let (.number(lhs), .number(rhs)):
      return lhs == rhs
    case let (.integer(integer), .number(number)), let (.number(number), .integer(integer)):
      return integerExactlyMatches(number, integer: integer)
    case let (.string(lhs), .string(rhs)):
      return lhs == rhs
    case let (.array(lhs), .array(rhs)):
      return lhs == rhs
    case let (.object(lhs), .object(rhs)):
      return lhs == rhs
    default:
      return false
    }
  }

  public var asDouble: Double? {
    switch self {
    case let .integer(value):
      return Double(value)
    case let .number(value):
      return value
    case .null, .bool, .string, .array, .object:
      return nil
    }
  }

  public var asInt64: Int64? {
    switch self {
    case let .integer(value):
      return value
    case let .number(value) where value.isFinite && value.rounded(.towardZero) == value:
      return Int64(exactly: value)
    case .null, .bool, .number, .string, .array, .object:
      return nil
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case let .bool(value):
      try container.encode(value)
    case let .integer(value):
      try container.encode(value)
    case let .number(value):
      try container.encode(value)
    case let .string(value):
      try container.encode(value)
    case let .array(value):
      try container.encode(value)
    case let .object(value):
      try container.encode(value)
    }
  }

  private static func integerExactlyMatches(_ number: Double, integer: Int64) -> Bool {
    guard number.isFinite,
      abs(integer) <= maxExactlyRepresentableIntegerAsDouble,
      number.rounded(.towardZero) == number else {
      return false
    }
    return Int64(number) == integer
  }
}

public typealias JSONObject = [String: JSONValue]
