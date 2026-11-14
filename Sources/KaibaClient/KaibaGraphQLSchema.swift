import Foundation

public enum KaibaSchemaTypeKind: String, Codable, CaseIterable, Equatable, Sendable {
  case scalar = "SCALAR"
  case object = "OBJECT"
  case interface = "INTERFACE"
  case union = "UNION"
  case enumeration = "ENUM"
  case inputObject = "INPUT_OBJECT"
}

public indirect enum KaibaSchemaTypeReference: Codable, Equatable, Sendable {
  case named(kind: KaibaSchemaTypeKind, name: String)
  case list(KaibaSchemaTypeReference)
  case nonNull(KaibaSchemaTypeReference)

  public var namedTypeName: String {
    switch self {
    case let .named(_, name): name
    case let .list(reference), let .nonNull(reference): reference.namedTypeName
    }
  }

  public var rendered: String {
    switch self {
    case let .named(_, name): name
    case let .list(reference): "[\(reference.rendered)]"
    case let .nonNull(reference): "\(reference.rendered)!"
    }
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case name
    case ofType
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(String.self, forKey: .kind)
    switch kind {
    case "LIST":
      guard try container.decodeIfPresent(String.self, forKey: .name) == nil else {
        throw DecodingError.dataCorruptedError(
          forKey: .name,
          in: container,
          debugDescription: "wrapper GraphQL type reference cannot have a name"
        )
      }
      self = .list(try container.decode(Self.self, forKey: .ofType))
    case "NON_NULL":
      guard try container.decodeIfPresent(String.self, forKey: .name) == nil else {
        throw DecodingError.dataCorruptedError(
          forKey: .name,
          in: container,
          debugDescription: "wrapper GraphQL type reference cannot have a name"
        )
      }
      self = .nonNull(try container.decode(Self.self, forKey: .ofType))
    default:
      guard let typeKind = KaibaSchemaTypeKind(rawValue: kind) else {
        throw DecodingError.dataCorruptedError(
          forKey: .kind,
          in: container,
          debugDescription: "unsupported GraphQL type kind"
        )
      }
      guard try container.decodeIfPresent(Self.self, forKey: .ofType) == nil else {
        throw DecodingError.dataCorruptedError(
          forKey: .ofType,
          in: container,
          debugDescription: "named GraphQL type reference cannot have an ofType value"
        )
      }
      self = .named(
        kind: typeKind,
        name: try container.decode(String.self, forKey: .name)
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .named(kind, name):
      try container.encode(kind.rawValue, forKey: .kind)
      try container.encode(name, forKey: .name)
    case let .list(reference):
      try container.encode("LIST", forKey: .kind)
      try container.encode(reference, forKey: .ofType)
    case let .nonNull(reference):
      try container.encode("NON_NULL", forKey: .kind)
      try container.encode(reference, forKey: .ofType)
    }
  }
}

public struct KaibaSchemaInputValue: Codable, Equatable, Sendable {
  public internal(set) var name: String
  public internal(set) var description: String?
  public internal(set) var type: KaibaSchemaTypeReference

  public init(name: String, description: String? = nil, type: KaibaSchemaTypeReference) {
    self.name = name
    self.description = description
    self.type = type
  }

  private enum CodingKeys: String, CodingKey {
    case name
    case description
    case type
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    description = try container.decodeIfPresent(String.self, forKey: .description)
    type = try container.decode(KaibaSchemaTypeReference.self, forKey: .type)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(name, forKey: .name)
    try container.encodeIfPresent(description, forKey: .description)
    try container.encode(type, forKey: .type)
  }
}

public struct KaibaSchemaField: Codable, Equatable, Sendable {
  public internal(set) var name: String
  public internal(set) var description: String?
  public internal(set) var arguments: [KaibaSchemaInputValue]
  public internal(set) var type: KaibaSchemaTypeReference
  public internal(set) var isDeprecated: Bool
  public internal(set) var deprecationReason: String?

  public init(
    name: String,
    description: String? = nil,
    arguments: [KaibaSchemaInputValue] = [],
    type: KaibaSchemaTypeReference,
    isDeprecated: Bool = false,
    deprecationReason: String? = nil
  ) {
    self.name = name
    self.description = description
    self.arguments = arguments
    self.type = type
    self.isDeprecated = isDeprecated
    self.deprecationReason = deprecationReason
  }

  private enum CodingKeys: String, CodingKey {
    case name
    case description
    case arguments
    case type
    case isDeprecated
    case deprecationReason
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    description = try container.decodeIfPresent(String.self, forKey: .description)
    arguments = try container.decodeIfPresent([KaibaSchemaInputValue].self, forKey: .arguments) ?? []
    type = try container.decode(KaibaSchemaTypeReference.self, forKey: .type)
    isDeprecated = try container.decodeIfPresent(Bool.self, forKey: .isDeprecated) ?? false
    deprecationReason = try container.decodeIfPresent(String.self, forKey: .deprecationReason)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(name, forKey: .name)
    try container.encodeIfPresent(description, forKey: .description)
    try container.encode(arguments, forKey: .arguments)
    try container.encode(type, forKey: .type)
    if isDeprecated {
      try container.encode(true, forKey: .isDeprecated)
      try container.encodeIfPresent(deprecationReason, forKey: .deprecationReason)
    }
  }
}

public struct KaibaSchemaEnumValue: Codable, Equatable, Sendable {
  public internal(set) var name: String
  public internal(set) var description: String?
  public internal(set) var isDeprecated: Bool
  public internal(set) var deprecationReason: String?

  public init(
    name: String,
    description: String? = nil,
    isDeprecated: Bool = false,
    deprecationReason: String? = nil
  ) {
    self.name = name
    self.description = description
    self.isDeprecated = isDeprecated
    self.deprecationReason = deprecationReason
  }

  private enum CodingKeys: String, CodingKey {
    case name
    case description
    case isDeprecated
    case deprecationReason
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    description = try container.decodeIfPresent(String.self, forKey: .description)
    isDeprecated = try container.decodeIfPresent(Bool.self, forKey: .isDeprecated) ?? false
    deprecationReason = try container.decodeIfPresent(String.self, forKey: .deprecationReason)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(name, forKey: .name)
    try container.encodeIfPresent(description, forKey: .description)
    if isDeprecated {
      try container.encode(true, forKey: .isDeprecated)
      try container.encodeIfPresent(deprecationReason, forKey: .deprecationReason)
    }
  }
}

public struct KaibaSchemaType: Codable, Equatable, Sendable {
  public internal(set) var kind: KaibaSchemaTypeKind
  public internal(set) var name: String
  public internal(set) var description: String?
  public internal(set) var fields: [KaibaSchemaField]
  public internal(set) var inputFields: [KaibaSchemaInputValue]
  public internal(set) var enumValues: [KaibaSchemaEnumValue]
  public internal(set) var interfaces: [String]
  public internal(set) var possibleTypes: [String]

  public init(
    kind: KaibaSchemaTypeKind,
    name: String,
    description: String? = nil,
    fields: [KaibaSchemaField] = [],
    inputFields: [KaibaSchemaInputValue] = [],
    enumValues: [KaibaSchemaEnumValue] = [],
    interfaces: [String] = [],
    possibleTypes: [String] = []
  ) {
    self.kind = kind
    self.name = name
    self.description = description
    self.fields = fields
    self.inputFields = inputFields
    self.enumValues = enumValues
    self.interfaces = interfaces
    self.possibleTypes = possibleTypes
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case name
    case description
    case fields
    case inputFields
    case enumValues
    case interfaces
    case possibleTypes
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    kind = try container.decode(KaibaSchemaTypeKind.self, forKey: .kind)
    name = try container.decode(String.self, forKey: .name)
    description = try container.decodeIfPresent(String.self, forKey: .description)
    fields = try container.decodeIfPresent([KaibaSchemaField].self, forKey: .fields) ?? []
    inputFields = try container.decodeIfPresent([KaibaSchemaInputValue].self, forKey: .inputFields) ?? []
    enumValues = try container.decodeIfPresent([KaibaSchemaEnumValue].self, forKey: .enumValues) ?? []
    interfaces = try container.decodeIfPresent([String].self, forKey: .interfaces) ?? []
    possibleTypes = try container.decodeIfPresent([String].self, forKey: .possibleTypes) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    try container.encode(name, forKey: .name)
    try container.encodeIfPresent(description, forKey: .description)
    switch kind {
    case .object:
      try container.encode(fields, forKey: .fields)
      try container.encode(interfaces, forKey: .interfaces)
    case .interface:
      try container.encode(fields, forKey: .fields)
      try container.encode(interfaces, forKey: .interfaces)
      try container.encode(possibleTypes, forKey: .possibleTypes)
    case .union:
      try container.encode(possibleTypes, forKey: .possibleTypes)
    case .inputObject:
      try container.encode(inputFields, forKey: .inputFields)
    case .enumeration:
      try container.encode(enumValues, forKey: .enumValues)
    case .scalar:
      break
    }
  }
}

public struct KaibaGraphQLSchema: Codable, Equatable, Sendable {
  public internal(set) var queryFields: [KaibaSchemaField]
  public internal(set) var mutationFields: [KaibaSchemaField]
  public internal(set) var types: [KaibaSchemaType]

  public init(
    queryFields: [KaibaSchemaField],
    mutationFields: [KaibaSchemaField] = [],
    types: [KaibaSchemaType]
  ) throws {
    try self.init(
      queryFields: queryFields,
      mutationFields: mutationFields,
      types: types,
      validateDeclaredReferenceKinds: false
    )
  }

  private init(
    queryFields: [KaibaSchemaField],
    mutationFields: [KaibaSchemaField],
    types: [KaibaSchemaType],
    validateDeclaredReferenceKinds: Bool
  ) throws {
    self.queryFields = queryFields
    self.mutationFields = mutationFields
    self.types = types
    try canonicalizeAndValidate(validateDeclaredReferenceKinds: validateDeclaredReferenceKinds)
  }

  private enum CodingKeys: String, CodingKey {
    case queryFields
    case mutationFields
    case types
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      queryFields: container.decode([KaibaSchemaField].self, forKey: .queryFields),
      mutationFields: container.decodeIfPresent(
        [KaibaSchemaField].self,
        forKey: .mutationFields
      ) ?? [],
      types: container.decode([KaibaSchemaType].self, forKey: .types),
      validateDeclaredReferenceKinds: true
    )
  }

  public static func parseSDL(_ source: String) throws -> KaibaGraphQLSchema {
    var parser = try KaibaSDLParser(source: source)
    return try parser.parse()
  }

  static func references(in field: KaibaSchemaField) -> [String] {
    [field.type.namedTypeName] + field.arguments.map { $0.type.namedTypeName }
  }

  static func kindOrder(_ kind: KaibaSchemaTypeKind) -> Int {
    switch kind {
    case .object: 0
    case .inputObject: 1
    case .enumeration: 2
    case .scalar: 3
    case .interface: 4
    case .union: 5
    }
  }
}

private enum KaibaSDLToken: Equatable {
  case name(String)
  case string(String)
  case punctuation(Character)
}

private struct KaibaSDLParser {
  private let tokens: [KaibaSDLToken]
  private var index = 0

  init(source: String) throws {
    tokens = try Self.tokenize(source)
  }

  mutating func parse() throws -> KaibaGraphQLSchema {
    var definitions: [KaibaSchemaType] = []
    var pendingDescription: String?
    while index < tokens.count {
      if case let .string(description) = tokens[index] {
        pendingDescription = description
        index += 1
        continue
      }
      guard case let .name(keyword) = tokens[index] else { index += 1; continue }
      index += 1
      switch keyword {
      case "scalar":
        definitions.append(KaibaSchemaType(
          kind: .scalar,
          name: try requireName(),
          description: pendingDescription
        ))
      case "type", "interface":
        definitions.append(try parseComposite(
          kind: keyword == "type" ? .object : .interface,
          description: pendingDescription
        ))
      case "input":
        definitions.append(try parseInput(description: pendingDescription))
      case "enum":
        definitions.append(try parseEnum(description: pendingDescription))
      case "union":
        definitions.append(try parseUnion(description: pendingDescription))
      case "schema", "directive":
        try skipDefinition()
      default:
        throw KaibaClientError.schemaUnavailable("unsupported SDL definition")
      }
      pendingDescription = nil
    }
    let queryDefinitions = definitions.filter { $0.kind == .object && $0.name == "Query" }
    let mutationDefinitions = definitions.filter { $0.kind == .object && $0.name == "Mutation" }
    guard queryDefinitions.count <= 1, mutationDefinitions.count <= 1 else {
      throw KaibaClientError.schemaUnavailable("duplicate root type definition")
    }
    let query = queryDefinitions.first
    let mutation = mutationDefinitions.first
    definitions.removeAll { $0.name == "Query" || $0.name == "Mutation" }
    let usedNames = Set(
      (query?.fields ?? []).flatMap(KaibaGraphQLSchema.references(in:))
        + (mutation?.fields ?? []).flatMap(KaibaGraphQLSchema.references(in:))
        + definitions.flatMap { type in
          type.fields.flatMap(KaibaGraphQLSchema.references(in:))
            + type.inputFields.map { $0.type.namedTypeName }
        }
    )
    let existing = Set(definitions.map(\.name))
    for builtin in ["Boolean", "Float", "ID", "Int", "String"]
    where usedNames.contains(builtin) && !existing.contains(builtin) {
      definitions.append(KaibaSchemaType(kind: .scalar, name: builtin))
    }
    guard let query else {
      throw KaibaClientError.schemaUnavailable("schema has no Query root")
    }
    return try KaibaGraphQLSchema(
      queryFields: query.fields,
      mutationFields: mutation?.fields ?? [],
      types: definitions
    )
  }

  private mutating func parseComposite(
    kind: KaibaSchemaTypeKind,
    description: String?
  ) throws -> KaibaSchemaType {
    let name = try requireName()
    var interfaces: [String] = []
    if consumeName("implements") {
      _ = consumePunctuation("&")
      while case .name = peek() {
        interfaces.append(try requireName())
        if !consumePunctuation("&") { break }
      }
    }
    try requirePunctuation("{")
    var fields: [KaibaSchemaField] = []
    var fieldDescription: String?
    while !consumePunctuation("}") {
      if case let .string(description) = peek() {
        fieldDescription = description
        index += 1
        continue
      }
      fields.append(try parseField(description: fieldDescription))
      fieldDescription = nil
    }
    return KaibaSchemaType(
      kind: kind,
      name: name,
      description: description,
      fields: fields,
      interfaces: interfaces
    )
  }

  private mutating func parseInput(description: String?) throws -> KaibaSchemaType {
    let name = try requireName()
    try requirePunctuation("{")
    var fields: [KaibaSchemaInputValue] = []
    var fieldDescription: String?
    while !consumePunctuation("}") {
      if case let .string(description) = peek() {
        fieldDescription = description
        index += 1
        continue
      }
      let fieldName = try requireName()
      try requirePunctuation(":")
      let reference = try parseTypeReference()
      try skipDefaultAndDirectives()
      fields.append(KaibaSchemaInputValue(
        name: fieldName,
        description: fieldDescription,
        type: reference
      ))
      fieldDescription = nil
    }
    return KaibaSchemaType(
      kind: .inputObject,
      name: name,
      description: description,
      inputFields: fields
    )
  }

  private mutating func parseEnum(description: String?) throws -> KaibaSchemaType {
    let name = try requireName()
    try requirePunctuation("{")
    var values: [KaibaSchemaEnumValue] = []
    var valueDescription: String?
    while !consumePunctuation("}") {
      if case let .string(description) = peek() {
        valueDescription = description
        index += 1
        continue
      }
      let name = try requireName()
      let deprecation = try parseDirectives()
      values.append(KaibaSchemaEnumValue(
        name: name,
        description: valueDescription,
        isDeprecated: deprecation.isDeprecated,
        deprecationReason: deprecation.reason
      ))
      valueDescription = nil
    }
    return KaibaSchemaType(
      kind: .enumeration,
      name: name,
      description: description,
      enumValues: values
    )
  }

  private mutating func parseUnion(description: String?) throws -> KaibaSchemaType {
    let name = try requireName()
    try requirePunctuation("=")
    var possible: [String] = []
    repeat { possible.append(try requireName()) } while consumePunctuation("|")
    return KaibaSchemaType(
      kind: .union,
      name: name,
      description: description,
      possibleTypes: possible
    )
  }

  private mutating func parseField(description: String?) throws -> KaibaSchemaField {
    let name = try requireName()
    var arguments: [KaibaSchemaInputValue] = []
    if consumePunctuation("(") {
      var argumentDescription: String?
      while !consumePunctuation(")") {
        if case let .string(description) = peek() {
          argumentDescription = description
          index += 1
          continue
        }
        let argumentName = try requireName()
        try requirePunctuation(":")
        let reference = try parseTypeReference()
        try skipDefaultAndDirectives(untilClosingParenthesis: true)
        arguments.append(KaibaSchemaInputValue(
          name: argumentName,
          description: argumentDescription,
          type: reference
        ))
        argumentDescription = nil
      }
    }
    try requirePunctuation(":")
    let reference = try parseTypeReference()
    let deprecation = try parseDirectives()
    return KaibaSchemaField(
      name: name,
      description: description,
      arguments: arguments,
      type: reference,
      isDeprecated: deprecation.isDeprecated,
      deprecationReason: deprecation.reason
    )
  }

  private mutating func parseTypeReference(depth: Int = 0) throws -> KaibaSchemaTypeReference {
    guard depth <= 8 else {
      throw KaibaClientError.schemaUnavailable("type-reference wrapper depth exceeds eight")
    }
    var reference: KaibaSchemaTypeReference
    if consumePunctuation("[") {
      reference = .list(try parseTypeReference(depth: depth + 1))
      try requirePunctuation("]")
    } else {
      reference = .named(kind: .scalar, name: try requireName())
    }
    if consumePunctuation("!") { reference = .nonNull(reference) }
    return reference
  }

  private mutating func skipDefaultAndDirectives(untilClosingParenthesis: Bool = false) throws {
    if consumePunctuation("=") {
      var depth = 0
      while let token = peek() {
        if token == .punctuation("@") || token == .punctuation("}") { break }
        if untilClosingParenthesis, token == .punctuation(")"), depth == 0 { break }
        if !untilClosingParenthesis, depth == 0, case .name = token { break }
        if token == .punctuation("[") || token == .punctuation("{") { depth += 1 }
        if token == .punctuation("]") || token == .punctuation("}") { depth -= 1 }
        index += 1
      }
    }
    _ = try parseDirectives()
  }

  private mutating func parseDirectives() throws -> (isDeprecated: Bool, reason: String?) {
    var isDeprecated = false
    var reason: String?
    while consumePunctuation("@") {
      let directive = try requireName()
      guard consumePunctuation("(") else {
        if directive == "deprecated" { isDeprecated = true }
        continue
      }
      if directive == "deprecated" {
        isDeprecated = true
        while !consumePunctuation(")") {
          let argument = try requireName()
          try requirePunctuation(":")
          guard case let .string(value)? = peek() else {
            throw KaibaClientError.schemaUnavailable("deprecated directive reason must be a string")
          }
          index += 1
          if argument == "reason" { reason = value }
        }
      } else {
        try skipBalanced(open: "(", close: ")")
      }
    }
    return (isDeprecated, reason)
  }

  private mutating func skipDefinition() throws {
    while let token = peek() {
      index += 1
      if token == .punctuation("{") { try skipBalanced(open: "{", close: "}"); return }
    }
  }

  private mutating func skipBalanced(open: Character, close: Character) throws {
    var depth = 1
    while index < tokens.count, depth > 0 {
      if tokens[index] == .punctuation(open) { depth += 1 }
      if tokens[index] == .punctuation(close) { depth -= 1 }
      index += 1
    }
    guard depth == 0 else { throw KaibaClientError.schemaUnavailable("unbalanced SDL") }
  }

  private func peek() -> KaibaSDLToken? { index < tokens.count ? tokens[index] : nil }

  private mutating func requireName() throws -> String {
    guard case let .name(value)? = peek() else {
      throw KaibaClientError.schemaUnavailable("expected SDL name")
    }
    index += 1
    return value
  }

  private mutating func consumeName(_ expected: String) -> Bool {
    guard peek() == .name(expected) else { return false }
    index += 1
    return true
  }

  private mutating func requirePunctuation(_ expected: Character) throws {
    guard consumePunctuation(expected) else {
      throw KaibaClientError.schemaUnavailable("expected SDL punctuation")
    }
  }

  private mutating func consumePunctuation(_ expected: Character) -> Bool {
    guard peek() == .punctuation(expected) else { return false }
    index += 1
    return true
  }

  private static func tokenize(_ source: String) throws -> [KaibaSDLToken] {
    var tokens: [KaibaSDLToken] = []
    var index = source.startIndex
    while index < source.endIndex {
      let character = source[index]
      if character.isWhitespace || character == "," { index = source.index(after: index); continue }
      if character == "#" {
        while index < source.endIndex, source[index] != "\n" { index = source.index(after: index) }
        continue
      }
      if character == "\"" {
        if source[index...].hasPrefix("\"\"\"") {
          index = source.index(index, offsetBy: 3)
          let start = index
          guard let end = source[index...].range(of: "\"\"\"")?.lowerBound else {
            throw KaibaClientError.schemaUnavailable("unterminated SDL block string")
          }
          tokens.append(.string(String(source[start..<end])))
          index = source.index(end, offsetBy: 3)
          continue
        }
        index = source.index(after: index)
        var value = ""
        var escaped = false
        while index < source.endIndex, escaped || source[index] != "\"" {
          if escaped {
            value.append(source[index])
            escaped = false
          } else if source[index] == "\\" {
            escaped = true
          } else {
            value.append(source[index])
          }
          index = source.index(after: index)
        }
        guard index < source.endIndex else {
          throw KaibaClientError.schemaUnavailable("unterminated SDL string")
        }
        index = source.index(after: index)
        tokens.append(.string(value))
        continue
      }
      if character.isLetter || character == "_" {
        let start = index
        index = source.index(after: index)
        while index < source.endIndex,
              source[index].isLetter || source[index].isNumber || source[index] == "_" {
          index = source.index(after: index)
        }
        tokens.append(.name(String(source[start..<index])))
        continue
      }
      if "{}()[]:!=|@&$".contains(character) {
        tokens.append(.punctuation(character)); index = source.index(after: index); continue
      }
      throw KaibaClientError.schemaUnavailable("unsupported SDL token")
    }
    return tokens
  }
}
