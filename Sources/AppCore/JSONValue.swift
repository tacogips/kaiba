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

  public var asInt: Int? {
    asInt64.flatMap(Int.init(exactly:))
  }

  public var asString: String? {
    guard case let .string(value) = self else {
      return nil
    }
    return value
  }

  public var asBool: Bool? {
    guard case let .bool(value) = self else {
      return nil
    }
    return value
  }

  public var asArray: [JSONValue]? {
    guard case let .array(value) = self else {
      return nil
    }
    return value
  }

  public var asObject: JSONObject? {
    guard case let .object(value) = self else {
      return nil
    }
    return value
  }

  public var isNull: Bool {
    self == .null
  }

  /// Reads a member of an object value; nil for any other case, and nil rather
  /// than `.null` for a member that is explicitly null, which is what every
  /// caller here wants to treat as absent.
  public subscript(member: String) -> JSONValue? {
    guard case let .object(members) = self, let value = members[member], value != .null else {
      return nil
    }
    return value
  }

  /// Reads an identifier out of a string member.
  public func identifier<Identifier: KaibaIdentifier>(
    _ member: String,
    as type: Identifier.Type = Identifier.self
  ) -> Identifier? {
    self[member]?.asString.map(Identifier.init)
  }

  // MARK: - Construction

  /// An identifier as its raw string. Ids reach JSON only through this, so one
  /// can never be dropped in as an opaque value.
  public static func id(_ value: some KaibaIdentifier) -> JSONValue {
    .string(value.rawValue)
  }

  public static func optionalString(_ value: String?) -> JSONValue {
    value.map(JSONValue.string) ?? .null
  }

  public static func optionalID<Identifier: KaibaIdentifier>(_ value: Identifier?) -> JSONValue {
    value.map { .string($0.rawValue) } ?? .null
  }

  public static func optionalInt(_ value: Int?) -> JSONValue {
    value.map { .integer(Int64($0)) } ?? .null
  }

  public static func strings(_ values: [String]) -> JSONValue {
    .array(values.map(JSONValue.string))
  }

  public static func ids(_ values: [some KaibaIdentifier]) -> JSONValue {
    .array(values.map { .string($0.rawValue) })
  }

  // MARK: - Serialization

  /// Parses UTF-8 JSON text. Replaces `JSONSerialization.jsonObject`, whose
  /// `Any` result had to be cast back into shape at every use.
  public init(parsing data: Data) throws {
    self = try JSONDecoder().decode(JSONValue.self, from: data)
  }

  public init(parsing text: String) throws {
    try self.init(parsing: Data(text.utf8))
  }

  /// Encodes with sorted keys and unescaped slashes, matching the output the
  /// store and the CLI produced through `JSONSerialization`.
  public func encodedData(prettyPrinted: Bool = false) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = prettyPrinted
      ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      : [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  public func encodedString(prettyPrinted: Bool = false) throws -> String {
    let data = try encodedData(prettyPrinted: prettyPrinted)
    guard let text = String(bytes: data, encoding: .utf8) else {
      throw JSONValueError.invalidUTF8
    }
    return text
  }

  // MARK: - Codable

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

public enum JSONValueError: Error, Equatable, Sendable {
  case invalidUTF8
}
