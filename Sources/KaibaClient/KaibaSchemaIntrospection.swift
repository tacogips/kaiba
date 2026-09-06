import Foundation

public enum KaibaSchemaIntrospectionV1 {
  public static let document = """
  query KaibaSchemaIntrospectionV1 {
    __schema {
      queryType { name }
      mutationType { name }
      types {
        kind name description
        fields(includeDeprecated: true) {
          name description isDeprecated deprecationReason
          args { name description type { ...TypeRef } }
          type { ...TypeRef }
        }
        inputFields { name description type { ...TypeRef } }
        enumValues(includeDeprecated: true) { name description isDeprecated deprecationReason }
        interfaces { kind name }
        possibleTypes { kind name }
      }
    }
  }
  fragment TypeRef on __Type {
    kind name ofType {
      kind name ofType {
        kind name ofType {
          kind name ofType {
            kind name ofType {
              kind name ofType {
                kind name ofType { kind name ofType { kind name } }
              }
            }
          }
        }
      }
    }
  }
  """
}

extension KaibaClient {
  public func fetchSchema() async throws -> KaibaGraphQLSchema {
    let redaction = KaibaRedaction(authentication: authentication)
    do {
      let response = try await execute(KaibaGraphQLRequest(
        document: KaibaSchemaIntrospectionV1.document,
        operationName: "KaibaSchemaIntrospectionV1"
      ))
      return try KaibaGraphQLSchema(introspectionData: response.data, redaction: redaction)
    } catch let error as KaibaClientError {
      switch error {
      case .authFailed, .connectionFailed, .httpFailed, .invalidResponse:
        throw error
      case .graphqlFailed:
        throw KaibaClientError.schemaUnavailable("the endpoint rejected schema introspection")
      case let .schemaUnavailable(reason):
        throw KaibaClientError.schemaUnavailable(redaction.text(reason))
      default:
        throw KaibaClientError.schemaUnavailable("the endpoint returned an invalid schema")
      }
    }
  }
}

extension KaibaGraphQLSchema {
  init(
    introspectionData value: KaibaJSONValue,
    redaction: KaibaRedaction = KaibaRedaction(authentication: .unauthenticated)
  ) throws {
    guard let schema = value.objectValue?["__schema"]?.objectValue else {
      throw KaibaClientError.schemaUnavailable("introspection response has no schema root")
    }
    let queryName = try Self.rootTypeName(schema["queryType"], required: true, redaction: redaction)
    let mutationName = try Self.rootTypeName(
      schema["mutationType"],
      required: false,
      redaction: redaction
    )
    guard let rawTypes = schema["types"]?.arrayValue else {
      throw KaibaClientError.schemaUnavailable("introspection schema types are invalid")
    }
    var decodedTypes = try rawTypes.map { try Self.decodeType($0, redaction: redaction) }
      .filter { !$0.name.hasPrefix("__") }
    try Self.validateReferenceKinds(in: decodedTypes)
    guard let queryName,
          let query = decodedTypes.first(where: { $0.name == queryName && $0.kind == .object }) else {
      throw KaibaClientError.schemaUnavailable("introspection query root is missing")
    }
    let mutation: KaibaSchemaType?
    if let mutationName {
      guard let root = decodedTypes.first(where: { $0.name == mutationName && $0.kind == .object }) else {
        throw KaibaClientError.schemaUnavailable("introspection mutation root is missing")
      }
      mutation = root
    } else {
      mutation = nil
    }
    decodedTypes.removeAll { $0.name == queryName || $0.name == mutationName }
    try self.init(
      queryFields: query.fields,
      mutationFields: mutation?.fields ?? [],
      types: decodedTypes
    )
  }

  public func introspectionData() -> KaibaJSONValue {
    let query = KaibaSchemaType(kind: .object, name: "Query", fields: queryFields)
    let mutation = KaibaSchemaType(kind: .object, name: "Mutation", fields: mutationFields)
    let allTypes = ([query] + (mutationFields.isEmpty ? [] : [mutation]) + types)
      .sorted { $0.name < $1.name }
    return .object([
      "__schema": .object([
        "queryType": .object(["name": .string("Query")]),
        "mutationType": mutationFields.isEmpty
          ? .null
          : .object(["name": .string("Mutation")]),
        "types": .array(allTypes.map(Self.encodeType))
      ])
    ])
  }

  private static func decodeType(
    _ value: KaibaJSONValue,
    redaction: KaibaRedaction
  ) throws -> KaibaSchemaType {
    guard let object = value.objectValue,
          let rawKind = object["kind"]?.stringValue,
          let kind = KaibaSchemaTypeKind(rawValue: rawKind),
          let name = object["name"]?.stringValue else {
      throw KaibaClientError.schemaUnavailable("introspection contains an invalid type")
    }
    return KaibaSchemaType(
      kind: kind,
      name: try redaction.identifier(name),
      description: try optionalString("description", in: object).map(redaction.text),
      fields: try memberArray(
        "fields",
        in: object,
        applicable: kind == .object || kind == .interface
      ).map { try decodeField($0, redaction: redaction) },
      inputFields: try memberArray(
        "inputFields",
        in: object,
        applicable: kind == .inputObject
      ).map { try decodeInputValue($0, redaction: redaction) },
      enumValues: try memberArray(
        "enumValues",
        in: object,
        applicable: kind == .enumeration
      ).map { try decodeEnumValue($0, redaction: redaction) },
      interfaces: try memberArray(
        "interfaces",
        in: object,
        applicable: kind == .object || kind == .interface
      ).map { try decodeNamedReference($0, expectedKind: .interface, redaction: redaction) },
      possibleTypes: try memberArray(
        "possibleTypes",
        in: object,
        applicable: kind == .interface || kind == .union
      ).map { try decodeNamedReference($0, expectedKind: .object, redaction: redaction) }
    )
  }

  private static func decodeField(
    _ value: KaibaJSONValue,
    redaction: KaibaRedaction
  ) throws -> KaibaSchemaField {
    guard let object = value.objectValue,
          let name = object["name"]?.stringValue,
          let rawType = object["type"] else {
      throw KaibaClientError.schemaUnavailable("introspection contains an invalid field")
    }
    return KaibaSchemaField(
      name: try redaction.identifier(name),
      description: try optionalString("description", in: object).map(redaction.text),
      arguments: try requiredArray("args", in: object).map {
        try decodeInputValue($0, redaction: redaction)
      },
      type: try decodeReference(rawType, redaction: redaction),
      isDeprecated: try requiredBool("isDeprecated", in: object),
      deprecationReason: try optionalString("deprecationReason", in: object).map(redaction.text)
    )
  }

  private static func decodeInputValue(
    _ value: KaibaJSONValue,
    redaction: KaibaRedaction
  ) throws -> KaibaSchemaInputValue {
    guard let object = value.objectValue,
          let name = object["name"]?.stringValue,
          let rawType = object["type"] else {
      throw KaibaClientError.schemaUnavailable("introspection contains an invalid input value")
    }
    return KaibaSchemaInputValue(
      name: try redaction.identifier(name),
      description: try optionalString("description", in: object).map(redaction.text),
      type: try decodeReference(rawType, redaction: redaction)
    )
  }

  private static func decodeEnumValue(
    _ value: KaibaJSONValue,
    redaction: KaibaRedaction
  ) throws -> KaibaSchemaEnumValue {
    guard let object = value.objectValue, let name = object["name"]?.stringValue else {
      throw KaibaClientError.schemaUnavailable("introspection contains an invalid enum value")
    }
    return KaibaSchemaEnumValue(
      name: try redaction.identifier(name),
      description: try optionalString("description", in: object).map(redaction.text),
      isDeprecated: try requiredBool("isDeprecated", in: object),
      deprecationReason: try optionalString("deprecationReason", in: object).map(redaction.text)
    )
  }

  private static func decodeNamedReference(
    _ value: KaibaJSONValue,
    expectedKind: KaibaSchemaTypeKind,
    redaction: KaibaRedaction
  ) throws -> String {
    guard let object = value.objectValue,
          object["kind"]?.stringValue == expectedKind.rawValue,
          let name = object["name"]?.stringValue else {
      throw KaibaClientError.schemaUnavailable("introspection contains an unnamed reference")
    }
    return try redaction.identifier(name)
  }

  private static func decodeReference(
    _ value: KaibaJSONValue,
    redaction: KaibaRedaction,
    depth: Int = 0
  ) throws -> KaibaSchemaTypeReference {
    guard depth <= 8, let object = value.objectValue,
          let rawKind = object["kind"]?.stringValue else {
      throw KaibaClientError.schemaUnavailable("introspection contains an invalid type reference")
    }
    switch rawKind {
    case "LIST":
      guard object["name"] == nil || object["name"] == .null,
            let nested = object["ofType"], nested != .null else {
        throw KaibaClientError.schemaUnavailable("LIST reference has no ofType")
      }
      return .list(try decodeReference(nested, redaction: redaction, depth: depth + 1))
    case "NON_NULL":
      guard object["name"] == nil || object["name"] == .null,
            let nested = object["ofType"], nested != .null else {
        throw KaibaClientError.schemaUnavailable("NON_NULL reference has no ofType")
      }
      return .nonNull(try decodeReference(nested, redaction: redaction, depth: depth + 1))
    default:
      guard let kind = KaibaSchemaTypeKind(rawValue: rawKind),
            let name = object["name"]?.stringValue,
            object["ofType"] == nil || object["ofType"] == .null else {
        throw KaibaClientError.schemaUnavailable("named reference is invalid")
      }
      return .named(kind: kind, name: try redaction.identifier(name))
    }
  }

  private static func rootTypeName(
    _ value: KaibaJSONValue?,
    required: Bool,
    redaction: KaibaRedaction
  ) throws -> String? {
    if value == nil || value == .null {
      guard !required else {
        throw KaibaClientError.schemaUnavailable("introspection query root is invalid")
      }
      return nil
    }
    guard let object = value?.objectValue,
          let name = object["name"]?.stringValue else {
      throw KaibaClientError.schemaUnavailable("introspection root type is invalid")
    }
    return try redaction.identifier(name)
  }

  private static func memberArray(
    _ key: String,
    in object: [String: KaibaJSONValue],
    applicable: Bool
  ) throws -> [KaibaJSONValue] {
    guard applicable else {
      guard object[key] == nil || object[key] == .null else {
        throw KaibaClientError.schemaUnavailable("introspection type has invalid \(key)")
      }
      return []
    }
    return try requiredArray(key, in: object)
  }

  private static func requiredArray(
    _ key: String,
    in object: [String: KaibaJSONValue]
  ) throws -> [KaibaJSONValue] {
    guard let values = object[key]?.arrayValue else {
      throw KaibaClientError.schemaUnavailable("introspection member \(key) is invalid")
    }
    return values
  }

  private static func optionalString(
    _ key: String,
    in object: [String: KaibaJSONValue]
  ) throws -> String? {
    guard let value = object[key], value != .null else { return nil }
    guard let string = value.stringValue else {
      throw KaibaClientError.schemaUnavailable("introspection member \(key) is invalid")
    }
    return string
  }

  private static func requiredBool(
    _ key: String,
    in object: [String: KaibaJSONValue]
  ) throws -> Bool {
    guard case let .bool(value)? = object[key] else {
      throw KaibaClientError.schemaUnavailable("introspection member \(key) is invalid")
    }
    return value
  }

  private static func validateReferenceKinds(in types: [KaibaSchemaType]) throws {
    var kindByName: [String: KaibaSchemaTypeKind] = [:]
    for type in types {
      guard kindByName[type.name] == nil else {
        throw KaibaClientError.schemaUnavailable("introspection contains duplicate type names")
      }
      kindByName[type.name] = type.kind
    }
    for name in ["String", "Int", "Float", "Boolean", "ID"] where kindByName[name] == nil {
      kindByName[name] = .scalar
    }
    for type in types {
      for interface in type.interfaces where kindByName[interface] != .interface {
        throw KaibaClientError.schemaUnavailable("introspection interface reference has conflicting kind")
      }
      for possibleType in type.possibleTypes where kindByName[possibleType] != .object {
        throw KaibaClientError.schemaUnavailable("introspection possible type has conflicting kind")
      }
      for field in type.fields {
        try validateReference(field.type, kindByName: kindByName)
        for argument in field.arguments {
          try validateReference(argument.type, kindByName: kindByName)
        }
      }
      for input in type.inputFields {
        try validateReference(input.type, kindByName: kindByName)
      }
    }
  }

  private static func validateReference(
    _ reference: KaibaSchemaTypeReference,
    kindByName: [String: KaibaSchemaTypeKind]
  ) throws {
    switch reference {
    case let .named(kind, name):
      guard kindByName[name] == kind else {
        throw KaibaClientError.schemaUnavailable("introspection type reference has conflicting kind")
      }
    case let .list(nested), let .nonNull(nested):
      try validateReference(nested, kindByName: kindByName)
    }
  }

  private static func encodeType(_ type: KaibaSchemaType) -> KaibaJSONValue {
    .object([
      "kind": .string(type.kind.rawValue),
      "name": .string(type.name),
      "description": type.description.map(KaibaJSONValue.string) ?? .null,
      "fields": type.kind == .object || type.kind == .interface
        ? .array(type.fields.map(encodeField)) : .null,
      "inputFields": type.kind == .inputObject
        ? .array(type.inputFields.map(encodeInputValue)) : .null,
      "enumValues": type.kind == .enumeration
        ? .array(type.enumValues.map(encodeEnumValue)) : .null,
      "interfaces": type.kind == .object || type.kind == .interface
        ? .array(type.interfaces.map {
          .object(["kind": .string(KaibaSchemaTypeKind.interface.rawValue), "name": .string($0)])
        }) : .null,
      "possibleTypes": type.kind == .interface || type.kind == .union
        ? .array(type.possibleTypes.map {
          .object(["kind": .string(KaibaSchemaTypeKind.object.rawValue), "name": .string($0)])
        }) : .null
    ])
  }

  private static func encodeField(_ field: KaibaSchemaField) -> KaibaJSONValue {
    .object([
      "name": .string(field.name),
      "description": field.description.map(KaibaJSONValue.string) ?? .null,
      "args": .array(field.arguments.map(encodeInputValue)),
      "type": encodeReference(field.type),
      "isDeprecated": .bool(field.isDeprecated),
      "deprecationReason": field.deprecationReason.map(KaibaJSONValue.string) ?? .null
    ])
  }

  private static func encodeInputValue(_ value: KaibaSchemaInputValue) -> KaibaJSONValue {
    .object([
      "name": .string(value.name),
      "description": value.description.map(KaibaJSONValue.string) ?? .null,
      "type": encodeReference(value.type)
    ])
  }

  private static func encodeEnumValue(_ value: KaibaSchemaEnumValue) -> KaibaJSONValue {
    .object([
      "name": .string(value.name),
      "description": value.description.map(KaibaJSONValue.string) ?? .null,
      "isDeprecated": .bool(value.isDeprecated),
      "deprecationReason": value.deprecationReason.map(KaibaJSONValue.string) ?? .null
    ])
  }

  private static func encodeReference(_ reference: KaibaSchemaTypeReference) -> KaibaJSONValue {
    switch reference {
    case let .named(kind, name):
      return .object(["kind": .string(kind.rawValue), "name": .string(name), "ofType": .null])
    case let .list(nested):
      return .object(["kind": .string("LIST"), "name": .null, "ofType": encodeReference(nested)])
    case let .nonNull(nested):
      return .object(["kind": .string("NON_NULL"), "name": .null, "ofType": encodeReference(nested)])
    }
  }
}
