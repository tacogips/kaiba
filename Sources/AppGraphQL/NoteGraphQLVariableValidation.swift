import Foundation

indirect enum ParsedGraphQLTypeReference: Equatable, Sendable {
  case named(String)
  case list(ParsedGraphQLTypeReference)
  case nonNull(ParsedGraphQLTypeReference)

  var namedType: String {
    switch self {
    case let .named(name):
      return name
    case let .list(element), let .nonNull(element):
      return element.namedType
    }
  }

  func isAllowed(at expected: ParsedGraphQLTypeReference, hasNonNullDefault: Bool) -> Bool {
    switch expected {
    case let .nonNull(expectedValue):
      if case let .nonNull(variableValue) = self {
        return variableValue.isAllowed(at: expectedValue, hasNonNullDefault: false)
      }
      return hasNonNullDefault && isAllowed(at: expectedValue, hasNonNullDefault: false)
    case let .list(expectedElement):
      let variableValue: ParsedGraphQLTypeReference
      if case let .nonNull(nonNullValue) = self {
        variableValue = nonNullValue
      } else {
        variableValue = self
      }
      guard case let .list(variableElement) = variableValue else {
        return false
      }
      return variableElement.isAllowed(at: expectedElement, hasNonNullDefault: false)
    case let .named(expectedName):
      let variableValue: ParsedGraphQLTypeReference
      if case let .nonNull(nonNullValue) = self {
        variableValue = nonNullValue
      } else {
        variableValue = self
      }
      guard case let .named(variableName) = variableValue else {
        return false
      }
      return variableName == expectedName
    }
  }
}

struct ParsedGraphQLVariableDefinition: Equatable, Sendable {
  var type: ParsedGraphQLTypeReference
  var defaultValue: JSONValue?

  var hasNonNullDefault: Bool {
    guard let defaultValue else { return false }
    return defaultValue != .null
  }
}

struct ParsedGraphQLVariableDefinitions: Equatable, Sendable {
  var values: [String: ParsedGraphQLVariableDefinition] = [:]

  var defaults: JSONObject {
    values.reduce(into: [:]) { result, element in
      if let defaultValue = element.value.defaultValue {
        result[element.key] = defaultValue
      }
    }
  }
}

enum ParsedGraphQLInputPathComponent: Equatable, Hashable, Sendable {
  case field(String)
  case listElement
}

struct ParsedGraphQLVariableUsage: Equatable, Sendable {
  var name: String
  var path: [ParsedGraphQLInputPathComponent]
}

final class GraphQLVariableUsageCollector {
  private(set) var usages: [ParsedGraphQLVariableUsage] = []

  func record(name: String, path: [ParsedGraphQLInputPathComponent]) {
    usages.append(ParsedGraphQLVariableUsage(name: name, path: path))
  }
}

private indirect enum ParsedGraphQLConstantValue {
  case null
  case boolean(Bool)
  case integer(Int64)
  case number(Double)
  case string(String)
  case enumValue(String)
  case list([ParsedGraphQLConstantValue])
  case object([String: ParsedGraphQLConstantValue])

  var jsonValue: JSONValue {
    switch self {
    case .null:
      return .null
    case let .boolean(value):
      return .bool(value)
    case let .integer(value):
      return .integer(value)
    case let .number(value):
      return .number(value)
    case let .string(value), let .enumValue(value):
      return .string(value)
    case let .list(values):
      return .array(values.map(\.jsonValue))
    case let .object(object):
      return .object(object.mapValues(\.jsonValue))
    }
  }
}

private func parseGraphQLConstantValue(
  in query: String,
  index: inout String.Index,
  depth: Int
) throws -> ParsedGraphQLConstantValue {
  guard depth <= NoteGraphQLDocumentLimits.maximumValueDepth else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable(
      "GraphQL default value depth limit exceeded"
    )
  }
  skipGraphQLIgnored(in: query, index: &index)
  guard index < query.endIndex else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable(
      "GraphQL variable default value is missing"
    )
  }
  switch query[index] {
  case "$":
    throw NoteGraphQLDocumentExecutorError.invalidVariable(
      "GraphQL variable defaults must be constant values"
    )
  case "\"":
    return .string(try readGraphQLString(in: query, index: &index))
  case "[":
    index = query.index(after: index)
    var values: [ParsedGraphQLConstantValue] = []
    while index < query.endIndex {
      skipGraphQLIgnored(in: query, index: &index)
      guard index < query.endIndex else { break }
      if query[index] == "]" {
        index = query.index(after: index)
        return .list(values)
      }
      values.append(try parseGraphQLConstantValue(
        in: query,
        index: &index,
        depth: depth + 1
      ))
    }
    throw NoteGraphQLDocumentExecutorError.invalidVariable(
      "GraphQL default list was not closed"
    )
  case "{":
    index = query.index(after: index)
    var object: [String: ParsedGraphQLConstantValue] = [:]
    while index < query.endIndex {
      skipGraphQLIgnored(in: query, index: &index)
      guard index < query.endIndex else { break }
      if query[index] == "}" {
        index = query.index(after: index)
        return .object(object)
      }
      guard let key = readGraphQLIdentifier(in: query, index: &index) else {
        throw NoteGraphQLDocumentExecutorError.invalidVariable(
          "GraphQL default object key is missing"
        )
      }
      skipGraphQLIgnored(in: query, index: &index)
      guard index < query.endIndex, query[index] == ":" else {
        throw NoteGraphQLDocumentExecutorError.invalidVariable(
          "GraphQL default object key '\(key)' is missing ':'"
        )
      }
      index = query.index(after: index)
      guard object[key] == nil else {
        throw NoteGraphQLDocumentExecutorError.invalidVariable(
          "duplicate GraphQL default input field '\(key)'"
        )
      }
      object[key] = try parseGraphQLConstantValue(
        in: query,
        index: &index,
        depth: depth + 1
      )
    }
    throw NoteGraphQLDocumentExecutorError.invalidVariable(
      "GraphQL default object was not closed"
    )
  default:
    if query[index] == "-" || query[index].isNumber {
      switch try parseGraphQLNumber(in: query, index: &index) {
      case let .integer(value):
        return .integer(value)
      case let .number(value):
        return .number(value)
      default:
        throw NoteGraphQLDocumentExecutorError.invalidVariable(
          "GraphQL variable default number is invalid"
        )
      }
    }
    guard let identifier = readGraphQLIdentifier(in: query, index: &index) else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable(
        "unsupported GraphQL variable default value"
      )
    }
    switch identifier {
    case "true":
      return .boolean(true)
    case "false":
      return .boolean(false)
    case "null":
      return .null
    default:
      return .enumValue(identifier)
    }
  }
}

func parseGraphQLVariableDefinitions(
  in query: String,
  index: inout String.Index
) throws -> ParsedGraphQLVariableDefinitions {
  guard index < query.endIndex, query[index] == "(" else {
    return ParsedGraphQLVariableDefinitions()
  }
  index = query.index(after: index)
  var result = ParsedGraphQLVariableDefinitions()
  while index < query.endIndex {
    skipGraphQLIgnored(in: query, index: &index)
    if index < query.endIndex, query[index] == ")" {
      index = query.index(after: index)
      try validateGraphQLVariableDefinitionTypes(result)
      return result
    }
    guard index < query.endIndex, query[index] == "$" else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable(
        "GraphQL variable definition is missing '$'"
      )
    }
    index = query.index(after: index)
    guard let variableName = readGraphQLIdentifier(in: query, index: &index) else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable(
        "GraphQL variable definition is missing a name"
      )
    }
    guard result.values[variableName] == nil else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable(
        "duplicate GraphQL variable definition '$\(variableName)'"
      )
    }
    skipGraphQLIgnored(in: query, index: &index)
    guard index < query.endIndex, query[index] == ":" else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable(
        "GraphQL variable '\(variableName)' is missing a type"
      )
    }
    index = query.index(after: index)
    let type = try parseGraphQLTypeReference(in: query, index: &index)
    skipGraphQLIgnored(in: query, index: &index)
    var defaultValue: JSONValue?
    if index < query.endIndex, query[index] == "=" {
      index = query.index(after: index)
      let constant = try parseGraphQLConstantValue(in: query, index: &index, depth: 1)
      try validateGraphQLConstantValue(constant, as: type, variableName: variableName)
      defaultValue = constant.jsonValue
    }
    result.values[variableName] = ParsedGraphQLVariableDefinition(
      type: type,
      defaultValue: defaultValue
    )
  }
  throw NoteGraphQLDocumentExecutorError.invalidVariable(
    "GraphQL variable definitions were not closed"
  )
}

func parseGraphQLTypeReference(
  in query: String,
  index: inout String.Index,
  depth: Int = 1
) throws -> ParsedGraphQLTypeReference {
  guard depth <= NoteGraphQLDocumentLimits.maximumValueDepth else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable(
      "GraphQL variable type depth limit exceeded"
    )
  }
  skipGraphQLIgnored(in: query, index: &index)
  guard index < query.endIndex else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable(
      "GraphQL variable type is missing"
    )
  }
  let value: ParsedGraphQLTypeReference
  if query[index] == "[" {
    index = query.index(after: index)
    let element = try parseGraphQLTypeReference(in: query, index: &index, depth: depth + 1)
    skipGraphQLIgnored(in: query, index: &index)
    guard index < query.endIndex, query[index] == "]" else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable(
        "GraphQL list variable type is missing ']'"
      )
    }
    index = query.index(after: index)
    value = .list(element)
  } else {
    guard let name = readGraphQLIdentifier(in: query, index: &index) else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable(
        "GraphQL variable type is invalid"
      )
    }
    value = .named(name)
  }
  skipGraphQLIgnored(in: query, index: &index)
  if index < query.endIndex, query[index] == "!" {
    index = query.index(after: index)
    return .nonNull(value)
  }
  return value
}

private func validateGraphQLConstantValue(
  _ value: ParsedGraphQLConstantValue,
  as type: ParsedGraphQLTypeReference,
  variableName: String
) throws {
  guard graphQLConstantValue(value, isValidFor: type) else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable(
      "GraphQL variable '$\(variableName)' default is incompatible with its declared type"
    )
  }
}

private func graphQLConstantValue(
  _ value: ParsedGraphQLConstantValue,
  isValidFor type: ParsedGraphQLTypeReference
) -> Bool {
  switch type {
  case let .nonNull(wrapped):
    guard case .null = value else {
      return graphQLConstantValue(value, isValidFor: wrapped)
    }
    return false
  case let .list(element):
    if case .null = value {
      return true
    }
    if case let .list(values) = value {
      return values.allSatisfy { graphQLConstantValue($0, isValidFor: element) }
    }
    return graphQLConstantValue(value, isValidFor: element)
  case let .named(name):
    if case .null = value {
      return true
    }
    switch name {
    case "Boolean":
      if case .boolean = value { return true }
    case "Float":
      if case .integer = value { return true }
      if case .number = value { return true }
    case "ID":
      if case .integer = value { return true }
      if case .string = value { return true }
    case "Int":
      if case .integer = value { return true }
    case "String":
      if case .string = value { return true }
    default:
      if let allowedValues = graphQLInputSchemaIndex.enumValues[name] {
        guard case let .enumValue(rawValue) = value else { return false }
        return allowedValues.contains(rawValue)
      }
      if let fields = graphQLInputSchemaIndex.inputFields[name] {
        return graphQLInputObject(value, isValidFor: fields)
      }
      if graphQLInputSchemaIndex.scalarNames.contains(name) {
        return true
      }
    }
    return false
  }
}

private func graphQLInputObject(
  _ value: ParsedGraphQLConstantValue,
  isValidFor fields: [String: ParsedGraphQLTypeReference]
) -> Bool {
  guard case let .object(object) = value,
        Set(object.keys).isSubset(of: fields.keys) else {
    return false
  }
  for (name, type) in fields {
    if let fieldValue = object[name] {
      guard graphQLConstantValue(fieldValue, isValidFor: type) else {
        return false
      }
    } else if case .nonNull = type {
      return false
    }
  }
  return true
}

private func validateGraphQLVariableDefinitionTypes(
  _ definitions: ParsedGraphQLVariableDefinitions
) throws {
  for (name, definition) in definitions.values {
    guard graphQLInputTypeNames.contains(definition.type.namedType) else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable(
        "GraphQL variable '$\(name)' uses unknown or non-input type '\(definition.type.namedType)'"
      )
    }
  }
}

private let graphQLInputTypeNames: Set<String> = {
  var names: Set<String> = ["Boolean", "Float", "ID", "Int", "String"]
  let schema = GraphQLContractProjector.schemaContract
  let declarationKinds: Set<String> = ["enum", "input", "scalar"]
  let words = schema.split { $0.isWhitespace || $0 == "{" || $0 == "}" }
  for index in words.indices where declarationKinds.contains(String(words[index])) {
    let next = words.index(after: index)
    if next < words.endIndex {
      names.insert(String(words[next]))
    }
  }
  return names
}()

func validateGraphQLVariableUsages(
  in root: ParsedNoteGraphQLRootField
) throws {
  for usage in root.variableUsages {
    guard let definition = root.variableDefinitions[usage.name] else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable(
        "GraphQL variable '$\(usage.name)' is not defined by the operation"
      )
    }
    guard let expectedType = graphQLInputSchemaIndex.expectedType(
      operationType: root.operationType,
      rootFieldName: root.fieldName,
      path: usage.path
    ) else {
      continue
    }
    guard definition.type.isAllowed(
      at: expectedType,
      hasNonNullDefault: definition.hasNonNullDefault
    ) else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable(
        "GraphQL variable '$\(usage.name)' type is incompatible with its input position"
      )
    }
  }
}

func validateGraphQLVariableDeclarations(
  _ definitions: [String: ParsedGraphQLVariableDefinition],
  usedBy roots: [ParsedNoteGraphQLRootField]
) throws {
  let usedNames = Set(roots.flatMap(\.variableUsages).map(\.name))
  let unusedNames = Set(definitions.keys).subtracting(usedNames)
  guard unusedNames.isEmpty else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable(
      "unused GraphQL variable definition(s): \(unusedNames.sorted().map { "$\($0)" }.joined(separator: ", "))"
    )
  }
}

private struct GraphQLInputSchemaIndex {
  var queryArguments: [String: [String: ParsedGraphQLTypeReference]]
  var mutationArguments: [String: [String: ParsedGraphQLTypeReference]]
  var inputFields: [String: [String: ParsedGraphQLTypeReference]]
  var enumValues: [String: Set<String>]
  var scalarNames: Set<String>

  func expectedType(
    operationType: GraphQLDocumentOperationType,
    rootFieldName: String,
    path: [ParsedGraphQLInputPathComponent]
  ) -> ParsedGraphQLTypeReference? {
    guard case let .field(argumentName)? = path.first else {
      return nil
    }
    let rootArguments = operationType == .query ? queryArguments : mutationArguments
    guard var type = rootArguments[rootFieldName]?[argumentName] else {
      return nil
    }
    for component in path.dropFirst() {
      switch component {
      case .listElement:
        type = type.nullableValue
        guard case let .list(element) = type else {
          return nil
        }
        type = element
      case let .field(name):
        type = type.nullableValue
        guard case let .named(inputName) = type,
              let fieldType = inputFields[inputName]?[name] else {
          return nil
        }
        type = fieldType
      }
    }
    return type
  }
}

private extension ParsedGraphQLTypeReference {
  var nullableValue: ParsedGraphQLTypeReference {
    if case let .nonNull(value) = self {
      return value
    }
    return self
  }
}

private let graphQLInputSchemaIndex: GraphQLInputSchemaIndex = {
  let schema = GraphQLContractProjector.schemaContract
  return GraphQLInputSchemaIndex(
    queryArguments: graphQLRootArgumentTypes(in: schema, typeName: "Query"),
    mutationArguments: graphQLRootArgumentTypes(in: schema, typeName: "Mutation"),
    inputFields: graphQLInputFieldTypes(in: schema),
    enumValues: graphQLEnumValues(in: schema),
    scalarNames: graphQLScalarNames(in: schema)
  )
}()

private func graphQLRootArgumentTypes(
  in schema: String,
  typeName: String
) -> [String: [String: ParsedGraphQLTypeReference]] {
  guard let body = graphQLDefinitionBodies(
    in: schema,
    pattern: #"type\s+\#(typeName)\s*\{(.*?)\n\s*\}"#
  ).first else {
    return [:]
  }
  let fieldPattern = #"(?m)^\s*([_A-Za-z][_0-9A-Za-z]*)\s*(?:\(([^)]*)\))?\s*:"#
  guard let expression = try? NSRegularExpression(
    pattern: fieldPattern,
    options: [.dotMatchesLineSeparators]
  ) else {
    return [:]
  }
  let range = NSRange(body.startIndex..<body.endIndex, in: body)
  var result: [String: [String: ParsedGraphQLTypeReference]] = [:]
  for match in expression.matches(in: body, range: range) {
    guard let fieldName = graphQLCapture(match, index: 1, in: body) else {
      continue
    }
    let arguments = graphQLCapture(match, index: 2, in: body) ?? ""
    result[fieldName] = graphQLNamedTypeFields(in: arguments)
  }
  return result
}

private func graphQLInputFieldTypes(
  in schema: String
) -> [String: [String: ParsedGraphQLTypeReference]] {
  let pattern = #"input\s+([_A-Za-z][_0-9A-Za-z]*)\s*\{(.*?)\}"#
  guard let expression = try? NSRegularExpression(
    pattern: pattern,
    options: [.dotMatchesLineSeparators]
  ) else {
    return [:]
  }
  let range = NSRange(schema.startIndex..<schema.endIndex, in: schema)
  var result: [String: [String: ParsedGraphQLTypeReference]] = [:]
  for match in expression.matches(in: schema, range: range) {
    guard let name = graphQLCapture(match, index: 1, in: schema),
          let body = graphQLCapture(match, index: 2, in: schema) else {
      continue
    }
    result[name] = graphQLNamedTypeFields(in: body)
  }
  return result
}

private func graphQLEnumValues(in schema: String) -> [String: Set<String>] {
  let pattern = #"enum\s+([_A-Za-z][_0-9A-Za-z]*)\s*\{(.*?)\}"#
  guard let expression = try? NSRegularExpression(
    pattern: pattern,
    options: [.dotMatchesLineSeparators]
  ) else {
    return [:]
  }
  let range = NSRange(schema.startIndex..<schema.endIndex, in: schema)
  var result: [String: Set<String>] = [:]
  for match in expression.matches(in: schema, range: range) {
    guard let name = graphQLCapture(match, index: 1, in: schema),
          let body = graphQLCapture(match, index: 2, in: schema) else {
      continue
    }
    result[name] = Set(body.split {
      $0.isWhitespace || $0 == ","
    }.map(String.init))
  }
  return result
}

private func graphQLScalarNames(in schema: String) -> Set<String> {
  let pattern = #"scalar\s+([_A-Za-z][_0-9A-Za-z]*)"#
  guard let expression = try? NSRegularExpression(pattern: pattern) else {
    return []
  }
  let range = NSRange(schema.startIndex..<schema.endIndex, in: schema)
  return Set(expression.matches(in: schema, range: range).compactMap {
    graphQLCapture($0, index: 1, in: schema)
  })
}

private func graphQLDefinitionBodies(
  in schema: String,
  pattern: String
) -> [String] {
  guard let expression = try? NSRegularExpression(
    pattern: pattern,
    options: [.dotMatchesLineSeparators]
  ) else {
    return []
  }
  let range = NSRange(schema.startIndex..<schema.endIndex, in: schema)
  return expression.matches(in: schema, range: range).compactMap {
    graphQLCapture($0, index: 1, in: schema)
  }
}

private func graphQLNamedTypeFields(
  in source: String
) -> [String: ParsedGraphQLTypeReference] {
  let pattern = #"([_A-Za-z][_0-9A-Za-z]*)\s*:\s*([_A-Za-z\[\]!][_0-9A-Za-z\[\]!]*)"#
  guard let expression = try? NSRegularExpression(pattern: pattern) else {
    return [:]
  }
  let range = NSRange(source.startIndex..<source.endIndex, in: source)
  var result: [String: ParsedGraphQLTypeReference] = [:]
  for match in expression.matches(in: source, range: range) {
    guard let name = graphQLCapture(match, index: 1, in: source),
          let rawType = graphQLCapture(match, index: 2, in: source) else {
      continue
    }
    var index = rawType.startIndex
    if let type = try? parseGraphQLTypeReference(in: rawType, index: &index) {
      result[name] = type
    }
  }
  return result
}

private func graphQLCapture(
  _ match: NSTextCheckingResult,
  index: Int,
  in source: String
) -> String? {
  let range = match.range(at: index)
  guard range.location != NSNotFound,
        let sourceRange = Range(range, in: source) else {
    return nil
  }
  return String(source[sourceRange])
}
