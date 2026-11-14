import Foundation
import AppCore
import KaibaClient

func graphQLIntrospectionResponse(for request: GraphQLDocumentRequest) -> GraphQLDocumentExecutionResponse? {
  let rootFields: [ParsedNoteGraphQLRootField]
  do {
    rootFields = try parseNoteGraphQLRootFields(
      in: request.query,
      operationName: request.operationName,
      variables: request.variables,
      parseArguments: true
    ) ?? []
  } catch {
    return nil
  }
  let introspectionFields = rootFields.filter { introspectionRootFields.contains($0.fieldName) }
  guard !introspectionFields.isEmpty else { return nil }

  do {
    guard introspectionFields.count == rootFields.count else {
      throw IntrospectionSelectionError.invalid("mixed introspection and application fields are not supported")
    }
    guard introspectionFields.count == 1, let rootField = introspectionFields.first else {
      throw IntrospectionSelectionError.invalid("exactly one introspection root field is supported")
    }
    guard rootField.operationType == .query else {
      throw IntrospectionSelectionError.invalid("introspection requires a query operation")
    }
    try validateIntrospectionRoot(rootField)
    try validateIntrospectionSelectionNodeBudget(rootField.selections)

    let schema = try KaibaGraphQLSchema.parseSDL(GraphQLContractProjector.schemaContract)
    let fullSchema = try requiredObject(schema.introspectionData(), key: "__schema")
    let source: KaibaJSONValue
    let typeName: String
    switch rootField.fieldName {
    case "__schema":
      source = .object(fullSchema)
      typeName = "__Schema"
    case "__type":
      let name = try requiredTypeName(rootField.arguments)
      source = fullSchema["types"]?.arrayValue?.first {
        $0.objectValue?["name"]?.stringValue == name
      } ?? .null
      typeName = "__Type"
    default:
      throw IntrospectionSelectionError.invalid("unsupported introspection root field")
    }
    try validateIntrospectionSelections(
      rootField.selections,
      typeName: typeName,
      path: rootField.fieldName
    )
    try validateIntrospectionProjectionComplexity(
      source,
      selections: rootField.selections,
      typeName: typeName,
      path: rootField.fieldName
    )
    let projected = try projectIntrospectionValue(
      source,
      selections: rootField.selections,
      typeName: typeName,
      path: rootField.fieldName
    )
    let body: JSONObject = ["data": .object([rootField.responseKey: convert(projected)])]
    try validateIntrospectionResponseSize(body)
    return GraphQLDocumentExecutionResponse(handled: true, body: body)
  } catch {
    return introspectionError(publicIntrospectionDiagnostic(error))
  }
}

private let introspectionRootFields: Set<String> = ["__schema", "__type"]

enum GraphQLIntrospectionLimits {
  static let maximumSelectionNodes = 512
  static let maximumProjectionComplexity = 20_000
  static let maximumSerializedResponseBytes = 8 * 1_024 * 1_024
}

private let introspectionSelectionFields: [String: [String: String?]] = [
  "__Schema": [
    "queryType": "__Type",
    "mutationType": "__Type",
    "types": "__Type"
  ],
  "__Type": [
    "kind": nil,
    "name": nil,
    "description": nil,
    "fields": "__Field",
    "inputFields": "__InputValue",
    "enumValues": "__EnumValue",
    "interfaces": "__Type",
    "possibleTypes": "__Type",
    "ofType": "__Type"
  ],
  "__Field": [
    "name": nil,
    "description": nil,
    "args": "__InputValue",
    "type": "__Type",
    "isDeprecated": nil,
    "deprecationReason": nil
  ],
  "__InputValue": [
    "name": nil,
    "description": nil,
    "type": "__Type"
  ],
  "__EnumValue": [
    "name": nil,
    "description": nil,
    "isDeprecated": nil,
    "deprecationReason": nil
  ]
]

private enum IntrospectionSelectionError: Error {
  case invalid(String)
}

private func validateIntrospectionSelectionNodeBudget(
  _ selections: [ParsedNoteGraphQLSelectionField]
) throws {
  var remaining = GraphQLIntrospectionLimits.maximumSelectionNodes
  func consume(_ fields: [ParsedNoteGraphQLSelectionField]) throws {
    for field in fields {
      remaining -= 1
      guard remaining >= 0 else {
        throw IntrospectionSelectionError.invalid(
          "introspection query exceeds the selection limit"
        )
      }
      try consume(field.selections)
    }
  }
  try consume(selections)
}

private func validateIntrospectionProjectionComplexity(
  _ value: KaibaJSONValue,
  selections: [ParsedNoteGraphQLSelectionField],
  typeName: String,
  path: String
) throws {
  var remaining = GraphQLIntrospectionLimits.maximumProjectionComplexity
  try consumeIntrospectionProjectionComplexity(
    value,
    selections: selections,
    typeName: typeName,
    path: path,
    remaining: &remaining
  )
}

private func consumeIntrospectionProjectionComplexity(
  _ value: KaibaJSONValue,
  selections: [ParsedNoteGraphQLSelectionField],
  typeName: String,
  path: String,
  remaining: inout Int
) throws {
  switch value {
  case let .array(values):
    for value in values {
      try consumeIntrospectionProjectionComplexity(
        value,
        selections: selections,
        typeName: typeName,
        path: path,
        remaining: &remaining
      )
    }
  case let .object(object):
    remaining -= selections.count
    guard remaining >= 0 else {
      throw IntrospectionSelectionError.invalid(
        "introspection query exceeds the complexity limit"
      )
    }
    guard let fields = introspectionSelectionFields[typeName] else { return }
    for selection in selections where selection.fieldName != "__typename" {
      guard let childType = fields[selection.fieldName] ?? nil else { continue }
      try consumeIntrospectionProjectionComplexity(
        object[selection.fieldName] ?? .null,
        selections: selection.selections,
        typeName: childType,
        path: "\(path).\(selection.fieldName)",
        remaining: &remaining
      )
    }
  case .null, .bool, .integer, .double, .string:
    return
  }
}

func validateIntrospectionResponseSize(
  _ body: JSONObject,
  maximumBytes: Int = GraphQLIntrospectionLimits.maximumSerializedResponseBytes
) throws {
  let size = try JSONValue.object(body).encodedData().count
  guard size <= maximumBytes else {
    throw IntrospectionSelectionError.invalid(
      "introspection response exceeds the serialized response limit"
    )
  }
}

private func validateIntrospectionRoot(_ rootField: ParsedNoteGraphQLRootField) throws {
  guard !rootField.selections.isEmpty else {
    throw IntrospectionSelectionError.invalid("\(rootField.fieldName) requires a selection set")
  }
  switch rootField.fieldName {
  case "__schema":
    guard rootField.arguments.isEmpty else {
      throw IntrospectionSelectionError.invalid("__schema does not accept arguments")
    }
  case "__type":
    _ = try requiredTypeName(rootField.arguments)
  default:
    throw IntrospectionSelectionError.invalid("unsupported introspection root field")
  }
}

private func requiredTypeName(_ arguments: JSONObject) throws -> String {
  guard arguments.count == 1,
        let name = arguments["name"]?.asString,
        !name.isEmpty else {
    throw IntrospectionSelectionError.invalid("__type requires exactly one non-empty string name")
  }
  return name
}

private func projectIntrospectionValue(
  _ value: KaibaJSONValue,
  selections: [ParsedNoteGraphQLSelectionField],
  typeName: String,
  path: String
) throws -> KaibaJSONValue {
  switch value {
  case let .array(values):
    return .array(try values.map {
      try projectIntrospectionValue($0, selections: selections, typeName: typeName, path: path)
    })
  case let .object(object):
    guard let fields = introspectionSelectionFields[typeName] else {
      throw IntrospectionSelectionError.invalid("unsupported introspection type \(typeName)")
    }
    guard !selections.isEmpty else {
      throw IntrospectionSelectionError.invalid("\(path) requires a selection set")
    }
    var projected: [String: KaibaJSONValue] = [:]
    for selection in selections {
      guard selection.fragmentTypeConditions.allSatisfy({ $0 == typeName }) else {
        throw IntrospectionSelectionError.invalid("incompatible fragment type at \(path)")
      }
      guard projected[selection.responseKey] == nil else {
        throw IntrospectionSelectionError.invalid("duplicate response key at \(path).\(selection.responseKey)")
      }
      if selection.fieldName == "__typename" {
        guard selection.arguments.isEmpty, selection.selections.isEmpty else {
          throw IntrospectionSelectionError.invalid("\(path).__typename does not accept arguments or selections")
        }
        projected[selection.responseKey] = .string(typeName)
        continue
      }
      guard let childType = fields[selection.fieldName] else {
        throw IntrospectionSelectionError.invalid("unsupported introspection field \(path).\(selection.fieldName)")
      }
      try validateIntrospectionArguments(selection, parentType: typeName, path: path)
      let childValue = object[selection.fieldName] ?? .null
      if let childType {
        guard !selection.selections.isEmpty else {
          throw IntrospectionSelectionError.invalid("\(path).\(selection.fieldName) requires a selection set")
        }
        projected[selection.responseKey] = try projectIntrospectionValue(
          childValue,
          selections: selection.selections,
          typeName: childType,
          path: "\(path).\(selection.fieldName)"
        )
      } else {
        guard selection.selections.isEmpty else {
          throw IntrospectionSelectionError.invalid("\(path).\(selection.fieldName) does not support selections")
        }
        projected[selection.responseKey] = childValue
      }
    }
    return .object(projected)
  case .null:
    return .null
  case .bool, .integer, .double, .string:
    throw IntrospectionSelectionError.invalid("\(path) returned an invalid introspection value")
  }
}

private func validateIntrospectionSelections(
  _ selections: [ParsedNoteGraphQLSelectionField],
  typeName: String,
  path: String
) throws {
  guard let fields = introspectionSelectionFields[typeName], !selections.isEmpty else {
    throw IntrospectionSelectionError.invalid("\(path) requires a supported selection set")
  }
  var responseKeys = Set<String>()
  for selection in selections {
    guard selection.fragmentTypeConditions.allSatisfy({ $0 == typeName }) else {
      throw IntrospectionSelectionError.invalid("incompatible fragment type at \(path)")
    }
    guard responseKeys.insert(selection.responseKey).inserted else {
      throw IntrospectionSelectionError.invalid("duplicate response key at \(path).\(selection.responseKey)")
    }
    if selection.fieldName == "__typename" {
      guard selection.arguments.isEmpty, selection.selections.isEmpty else {
        throw IntrospectionSelectionError.invalid("\(path).__typename does not accept arguments or selections")
      }
      continue
    }
    guard let childType = fields[selection.fieldName] else {
      throw IntrospectionSelectionError.invalid("unsupported introspection field \(path).\(selection.fieldName)")
    }
    try validateIntrospectionArguments(selection, parentType: typeName, path: path)
    if let childType {
      try validateIntrospectionSelections(
        selection.selections,
        typeName: childType,
        path: "\(path).\(selection.fieldName)"
      )
    } else if !selection.selections.isEmpty {
      throw IntrospectionSelectionError.invalid("\(path).\(selection.fieldName) does not support selections")
    }
  }
}

private func validateIntrospectionArguments(
  _ selection: ParsedNoteGraphQLSelectionField,
  parentType: String,
  path: String
) throws {
  let acceptsIncludeDeprecated = parentType == "__Type"
    && (selection.fieldName == "fields" || selection.fieldName == "enumValues")
  if acceptsIncludeDeprecated {
    guard selection.arguments.keys.allSatisfy({ $0 == "includeDeprecated" }),
          selection.arguments["includeDeprecated"].map({ $0.asBool != nil }) ?? true else {
      throw IntrospectionSelectionError.invalid("\(path).\(selection.fieldName) accepts only includeDeprecated: Boolean")
    }
  } else if !selection.arguments.isEmpty {
    throw IntrospectionSelectionError.invalid("\(path).\(selection.fieldName) does not accept arguments")
  }
}

private func requiredObject(_ value: KaibaJSONValue, key: String) throws -> [String: KaibaJSONValue] {
  guard let object = value.objectValue?[key]?.objectValue else {
    throw IntrospectionSelectionError.invalid("schema introspection projection failed")
  }
  return object
}

private func publicIntrospectionDiagnostic(_ error: Error) -> String {
  if case let IntrospectionSelectionError.invalid(message) = error {
    return message
  }
  return "schema introspection is unavailable"
}

private func introspectionError(_ message: String) -> GraphQLDocumentExecutionResponse {
  GraphQLDocumentExecutionResponse(
    handled: true,
    body: [
      "data": .null,
      "errors": .array([.object(["message": .string(message)])])
    ]
  )
}

private func convert(_ value: KaibaJSONValue) -> JSONValue {
  switch value {
  case .null: .null
  case let .bool(value): .bool(value)
  case let .integer(value): .integer(Int64(value))
  case let .double(value): .number(value)
  case let .string(value): .string(value)
  case let .array(value): .array(value.map(convert))
  case let .object(value): .object(value.mapValues(convert))
  }
}
