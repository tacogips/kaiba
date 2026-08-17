import Foundation
import AppCore

public enum NoteGraphQLDocumentLimits {
  public static let maximumDocumentUTF8Bytes = 512 * 1024
  static let maximumSelectionDepth = 20
  static let maximumFragmentExpansionDepth = 20
  static let maximumFragmentExpansionCount = 1_024
  static let maximumValueDepth = 10
  static let maximumBalancedBlockDepth = 64
}

enum GraphQLDocumentOperationType: Equatable, Sendable {
  case query
  case mutation
}

struct ParsedNoteGraphQLRootField: Equatable, Sendable {
  var operationType: GraphQLDocumentOperationType
  var fieldName: String
  var responseKey: String
  var arguments: JSONObject
  var selections: [ParsedNoteGraphQLSelectionField]
  var variableDefinitions: [String: ParsedGraphQLVariableDefinition]
  var variableUsages: [ParsedGraphQLVariableUsage]
}

struct ParsedNoteGraphQLSelectionField: Equatable, Sendable {
  var fieldName: String
  var responseKey: String
  var arguments: JSONObject
  var fragmentTypeConditions: [String]
  var selections: [ParsedNoteGraphQLSelectionField]
}

func parseNoteGraphQLRootFields(
  in query: String,
  operationName: String?,
  variables: JSONObject,
  parseArguments: Bool
) throws -> [ParsedNoteGraphQLRootField]? {
  let operations = try parseNoteGraphQLOperations(
    in: query,
    operationName: operationName,
    variables: variables,
    parseArguments: parseArguments
  )
  return try selectNoteGraphQLOperation(
    operations,
    operationName: operationName
  )?.rootFields
}

public func noteGraphQLNamedOperationNames(in query: String) -> Set<String> {
  guard query.utf8.count <= NoteGraphQLDocumentLimits.maximumDocumentUTF8Bytes else {
    return []
  }
  var index = query.startIndex
  var names = Set<String>()
  while index < query.endIndex {
    skipGraphQLIgnored(in: query, index: &index)
    guard index < query.endIndex else {
      return names
    }
    if query[index] == "\"" {
      try? skipGraphQLStringLiteral(in: query, index: &index)
      continue
    }
    guard let operation = readGraphQLIdentifier(in: query, index: &index) else {
      index = query.index(after: index)
      continue
    }
    guard ["query", "mutation", "subscription"].contains(operation) else {
      continue
    }
    if let name = readOptionalGraphQLIdentifier(in: query, index: &index) {
      names.insert(name)
    }
    skipGraphQLIgnored(in: query, index: &index)
    if index < query.endIndex, query[index] == "(" {
      try? skipGraphQLBalanced(in: query, index: &index, open: "(", close: ")")
    }
    if (try? advanceToGraphQLSelectionSet(in: query, index: &index)) == true {
      try? skipGraphQLBalanced(in: query, index: &index, open: "{", close: "}")
    }
  }
  return names
}

func validateNoteGraphQLDocumentLength(_ query: String) throws {
  guard query.utf8.count <= NoteGraphQLDocumentLimits.maximumDocumentUTF8Bytes else {
    throw NoteGraphQLDocumentExecutorError.invalidSelection("GraphQL document size limit exceeded")
  }
}

func parseGraphQLRootSelections(
  in query: String,
  index: inout String.Index,
  operationType: GraphQLDocumentOperationType,
  variables: JSONObject,
  variableDefinitions: [String: ParsedGraphQLVariableDefinition],
  parseArguments: Bool,
  fragments: [String: ParsedGraphQLFragment],
  fragmentStack: Set<String>,
  fragmentBudget: GraphQLFragmentExpansionBudget,
  allowUnresolvedVariables: Bool
) throws -> [ParsedNoteGraphQLRootField] {
  guard index < query.endIndex, query[index] == "{" else {
    return []
  }
  index = query.index(after: index)
  var fields: [ParsedNoteGraphQLRootField] = []
  while index < query.endIndex {
    skipGraphQLIgnored(in: query, index: &index)
    if index < query.endIndex, query[index] == "}" {
      index = query.index(after: index)
      return fields
    }
    if query[index...].hasPrefix("...") {
      let name = try parseGraphQLFragmentSpreadName(
        in: query,
        index: &index,
        rejectDirectives: parseArguments
      )
      guard let fragment = fragments[name] else {
        throw NoteGraphQLDocumentExecutorError.invalidSelection("unknown GraphQL fragment '\(name)'")
      }
      let expectedType = operationType == .query ? "Query" : "Mutation"
      guard fragment.typeCondition == expectedType else {
        throw NoteGraphQLDocumentExecutorError.invalidSelection(
          "GraphQL fragment '\(name)' cannot be used on \(expectedType)"
        )
      }
      guard !fragmentStack.contains(name) else {
        throw NoteGraphQLDocumentExecutorError.invalidSelection("cyclic GraphQL fragment '\(name)'")
      }
      try fragmentBudget.consume(name: name, depth: fragmentStack.count)
      var fragmentIndex = fragment.selectionSource.startIndex
      fields += try parseGraphQLRootSelections(
        in: fragment.selectionSource,
        index: &fragmentIndex,
        operationType: operationType,
        variables: variables,
        variableDefinitions: variableDefinitions,
        parseArguments: parseArguments,
        fragments: fragments,
        fragmentStack: fragmentStack.union([name]),
        fragmentBudget: fragmentBudget,
        allowUnresolvedVariables: allowUnresolvedVariables
      )
      continue
    }
    guard let first = readGraphQLIdentifier(in: query, index: &index) else {
      throw NoteGraphQLDocumentExecutorError.invalidSelection("GraphQL root selection is missing a field name")
    }
    var responseKey = first
    var fieldName = first
    skipGraphQLIgnored(in: query, index: &index)
    if index < query.endIndex, query[index] == ":" {
      index = query.index(after: index)
      guard let aliasedFieldName = readGraphQLIdentifier(in: query, index: &index) else {
        throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL alias is missing a field name")
      }
      responseKey = first
      fieldName = aliasedFieldName
    }
    var arguments: JSONObject = [:]
    let usageCollector = GraphQLVariableUsageCollector()
    skipGraphQLIgnored(in: query, index: &index)
    if index < query.endIndex, query[index] == "(" {
      if parseArguments {
        arguments = try parseGraphQLArguments(
          in: query,
          index: &index,
          variables: variables,
          variableDefinitions: variableDefinitions,
          allowUnresolvedVariables: allowUnresolvedVariables,
          usageCollector: usageCollector
        )
      } else {
        try skipGraphQLBalanced(in: query, index: &index, open: "(", close: ")")
      }
    }
    try rejectGraphQLDirectives(in: query, index: &index, reject: parseArguments)
    let selections: [ParsedNoteGraphQLSelectionField]
    skipGraphQLIgnored(in: query, index: &index)
    if index < query.endIndex, query[index] == "{" {
      let selectionContext = GraphQLSelectionParsingContext(
        variables: variables,
        variableDefinitions: variableDefinitions,
        parseArguments: parseArguments,
        fragments: fragments,
        fragmentBudget: fragmentBudget,
        allowUnresolvedVariables: allowUnresolvedVariables,
        usageCollector: usageCollector
      )
      selections = try parseGraphQLSelectionSet(
        in: query,
        index: &index,
        depth: 1,
        context: selectionContext,
        fragmentStack: fragmentStack,
        fragmentTypeConditions: []
      )
    } else {
      selections = []
    }
    fields.append(ParsedNoteGraphQLRootField(
      operationType: operationType,
      fieldName: fieldName,
      responseKey: responseKey,
      arguments: arguments,
      selections: selections,
      variableDefinitions: variableDefinitions,
      variableUsages: usageCollector.usages
    ))
  }
  throw NoteGraphQLDocumentExecutorError.invalidSelection("GraphQL root selection set was not closed")
}

private struct GraphQLSelectionParsingContext {
  var variables: JSONObject
  var variableDefinitions: [String: ParsedGraphQLVariableDefinition]
  var parseArguments: Bool
  var fragments: [String: ParsedGraphQLFragment]
  var fragmentBudget: GraphQLFragmentExpansionBudget
  var allowUnresolvedVariables: Bool
  var usageCollector: GraphQLVariableUsageCollector
}

private func parseGraphQLSelectionSet(
  in query: String,
  index: inout String.Index,
  depth: Int,
  context: GraphQLSelectionParsingContext,
  fragmentStack: Set<String>,
  fragmentTypeConditions: [String]
) throws -> [ParsedNoteGraphQLSelectionField] {
  guard index < query.endIndex, query[index] == "{" else {
    return []
  }
  guard depth <= NoteGraphQLDocumentLimits.maximumSelectionDepth else {
    throw NoteGraphQLDocumentExecutorError.invalidSelection("GraphQL selection depth limit exceeded")
  }
  index = query.index(after: index)
  var selections: [ParsedNoteGraphQLSelectionField] = []
  while index < query.endIndex {
    skipGraphQLIgnored(in: query, index: &index)
    if index < query.endIndex, query[index] == "}" {
      index = query.index(after: index)
      return selections
    }
    if query[index...].hasPrefix("...") {
      let name = try parseGraphQLFragmentSpreadName(
        in: query,
        index: &index,
        rejectDirectives: context.parseArguments
      )
      guard let fragment = context.fragments[name] else {
        throw NoteGraphQLDocumentExecutorError.invalidSelection("unknown GraphQL fragment '\(name)'")
      }
      guard !fragmentStack.contains(name) else {
        throw NoteGraphQLDocumentExecutorError.invalidSelection("cyclic GraphQL fragment '\(name)'")
      }
      try context.fragmentBudget.consume(name: name, depth: fragmentStack.count)
      var fragmentIndex = fragment.selectionSource.startIndex
      selections += try parseGraphQLSelectionSet(
        in: fragment.selectionSource,
        index: &fragmentIndex,
        depth: depth,
        context: context,
        fragmentStack: fragmentStack.union([name]),
        fragmentTypeConditions: fragmentTypeConditions + [fragment.typeCondition]
      )
      continue
    }
    guard let first = readGraphQLIdentifier(in: query, index: &index) else {
      throw NoteGraphQLDocumentExecutorError.invalidSelection("GraphQL selection is missing a field name")
    }
    var responseKey = first
    var fieldName = first
    skipGraphQLIgnored(in: query, index: &index)
    if index < query.endIndex, query[index] == ":" {
      index = query.index(after: index)
      guard let aliasedFieldName = readGraphQLIdentifier(in: query, index: &index) else {
        throw NoteGraphQLDocumentExecutorError.invalidSelection("GraphQL alias is missing a field name")
      }
      responseKey = first
      fieldName = aliasedFieldName
    }
    var arguments: JSONObject = [:]
    skipGraphQLIgnored(in: query, index: &index)
    if index < query.endIndex, query[index] == "(" {
      if context.parseArguments {
        arguments = try parseGraphQLArguments(
          in: query,
          index: &index,
          variables: context.variables,
          variableDefinitions: context.variableDefinitions,
          allowUnresolvedVariables: context.allowUnresolvedVariables,
          usageCollector: context.usageCollector
        )
      } else {
        try skipGraphQLBalanced(in: query, index: &index, open: "(", close: ")")
      }
    }
    try rejectGraphQLDirectives(in: query, index: &index, reject: context.parseArguments)
    let nestedSelections: [ParsedNoteGraphQLSelectionField]
    skipGraphQLIgnored(in: query, index: &index)
    if index < query.endIndex, query[index] == "{" {
      nestedSelections = try parseGraphQLSelectionSet(
        in: query,
        index: &index,
        depth: depth + 1,
        context: context,
        fragmentStack: fragmentStack,
        fragmentTypeConditions: []
      )
    } else {
      nestedSelections = []
    }
    selections.append(ParsedNoteGraphQLSelectionField(
      fieldName: fieldName,
      responseKey: responseKey,
      arguments: arguments,
      fragmentTypeConditions: fragmentTypeConditions,
      selections: nestedSelections
    ))
  }
  throw NoteGraphQLDocumentExecutorError.invalidSelection("GraphQL selection set was not closed")
}

private func parseGraphQLFragmentSpreadName(
  in query: String,
  index: inout String.Index,
  rejectDirectives: Bool
) throws -> String {
  guard query[index...].hasPrefix("...") else {
    throw NoteGraphQLDocumentExecutorError.invalidSelection("GraphQL fragment spread is malformed")
  }
  for _ in 0..<3 {
    index = query.index(after: index)
  }
  skipGraphQLIgnored(in: query, index: &index)
  guard let name = readGraphQLIdentifier(in: query, index: &index), name != "on" else {
    throw NoteGraphQLDocumentExecutorError.invalidSelection(
      "inline GraphQL fragments are not supported"
    )
  }
  try rejectGraphQLDirectives(in: query, index: &index, reject: rejectDirectives)
  return name
}

/// Directives (`@skip`, `@include`, or any other) are not supported by the note
/// GraphQL surface. During execution (`reject == true`) encountering one is a
/// parse error at operation, root, and nested levels. During directive-tolerant
/// scans (route detection / field-name extraction) the directive is skipped so
/// the note field can still be identified and the execution path can report the
/// explicit error.
func rejectGraphQLDirectives(in query: String, index: inout String.Index, reject: Bool) throws {
  skipGraphQLIgnored(in: query, index: &index)
  while index < query.endIndex, query[index] == "@" {
    if reject {
      throw NoteGraphQLDocumentExecutorError.invalidSelection("GraphQL directives are not supported")
    }
    index = query.index(after: index)
    guard readGraphQLIdentifier(in: query, index: &index) != nil else {
      throw NoteGraphQLDocumentExecutorError.invalidSelection("GraphQL directive is missing a name")
    }
    skipGraphQLIgnored(in: query, index: &index)
    if index < query.endIndex, query[index] == "(" {
      try skipGraphQLBalanced(in: query, index: &index, open: "(", close: ")")
    }
    skipGraphQLIgnored(in: query, index: &index)
  }
}

private func parseGraphQLArguments(
  in query: String,
  index: inout String.Index,
  variables: JSONObject,
  variableDefinitions: [String: ParsedGraphQLVariableDefinition],
  allowUnresolvedVariables: Bool,
  usageCollector: GraphQLVariableUsageCollector
) throws -> JSONObject {
  guard index < query.endIndex, query[index] == "(" else {
    return [:]
  }
  index = query.index(after: index)
  var arguments: JSONObject = [:]
  while index < query.endIndex {
    skipGraphQLIgnored(in: query, index: &index)
    if index < query.endIndex, query[index] == ")" {
      index = query.index(after: index)
      return arguments
    }
    guard let name = readGraphQLIdentifier(in: query, index: &index) else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL argument is missing a name")
    }
    skipGraphQLIgnored(in: query, index: &index)
    guard index < query.endIndex, query[index] == ":" else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL argument '\(name)' is missing ':'")
    }
    index = query.index(after: index)
    guard arguments[name] == nil else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable(
        "duplicate GraphQL argument '\(name)'"
      )
    }
    arguments[name] = try parseGraphQLValue(
      in: query,
      index: &index,
      variables: variables,
      variableDefinitions: variableDefinitions,
      depth: 1,
      allowUnresolvedVariables: allowUnresolvedVariables,
      usageCollector: usageCollector,
      path: [.field(name)]
    )
  }
  throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL arguments were not closed")
}

func parseGraphQLValue(
  in query: String,
  index: inout String.Index,
  variables: JSONObject,
  variableDefinitions: [String: ParsedGraphQLVariableDefinition],
  depth: Int,
  allowUnresolvedVariables: Bool,
  usageCollector: GraphQLVariableUsageCollector?,
  path: [ParsedGraphQLInputPathComponent]
) throws -> JSONValue {
  guard depth <= NoteGraphQLDocumentLimits.maximumValueDepth else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL value depth limit exceeded")
  }
  skipGraphQLIgnored(in: query, index: &index)
  guard index < query.endIndex else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL value is missing")
  }
  switch query[index] {
  case "$":
    index = query.index(after: index)
    guard let variableName = readGraphQLIdentifier(in: query, index: &index) else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL variable is missing a name")
    }
    guard let definition = variableDefinitions[variableName] else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable(
        "GraphQL variable '$\(variableName)' is not defined by the operation"
      )
    }
    usageCollector?.record(name: variableName, path: path)
    if let value = variables[variableName] {
      return value
    }
    guard allowUnresolvedVariables else {
      if case .nonNull = definition.type {
        throw NoteGraphQLDocumentExecutorError.missingVariable(variableName)
      }
      return .null
    }
    return .null
  case "\"":
    return .string(try readGraphQLString(in: query, index: &index))
  case "[":
    return try parseGraphQLArray(
      in: query,
      index: &index,
      variables: variables,
      variableDefinitions: variableDefinitions,
      depth: depth,
      allowUnresolvedVariables: allowUnresolvedVariables,
      usageCollector: usageCollector,
      path: path
    )
  case "{":
    return try parseGraphQLObject(
      in: query,
      index: &index,
      variables: variables,
      variableDefinitions: variableDefinitions,
      depth: depth,
      allowUnresolvedVariables: allowUnresolvedVariables,
      usageCollector: usageCollector,
      path: path
    )
  default:
    if query[index] == "-" || query[index].isNumber {
      return try parseGraphQLNumber(in: query, index: &index)
    }
    guard let identifier = readGraphQLIdentifier(in: query, index: &index) else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("unsupported GraphQL value")
    }
    switch identifier {
    case "true":
      return .bool(true)
    case "false":
      return .bool(false)
    case "null":
      return .null
    default:
      return .string(identifier)
    }
  }
}

private func parseGraphQLArray(
  in query: String,
  index: inout String.Index,
  variables: JSONObject,
  variableDefinitions: [String: ParsedGraphQLVariableDefinition],
  depth: Int,
  allowUnresolvedVariables: Bool,
  usageCollector: GraphQLVariableUsageCollector?,
  path: [ParsedGraphQLInputPathComponent]
) throws -> JSONValue {
  index = query.index(after: index)
  var values: [JSONValue] = []
  while index < query.endIndex {
    skipGraphQLIgnored(in: query, index: &index)
    if index < query.endIndex, query[index] == "]" {
      index = query.index(after: index)
      return .array(values)
    }
    values.append(try parseGraphQLValue(
      in: query,
      index: &index,
      variables: variables,
      variableDefinitions: variableDefinitions,
      depth: depth + 1,
      allowUnresolvedVariables: allowUnresolvedVariables,
      usageCollector: usageCollector,
      path: path + [.listElement]
    ))
  }
  throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL array was not closed")
}

private func parseGraphQLObject(
  in query: String,
  index: inout String.Index,
  variables: JSONObject,
  variableDefinitions: [String: ParsedGraphQLVariableDefinition],
  depth: Int,
  allowUnresolvedVariables: Bool,
  usageCollector: GraphQLVariableUsageCollector?,
  path: [ParsedGraphQLInputPathComponent]
) throws -> JSONValue {
  index = query.index(after: index)
  var object: JSONObject = [:]
  while index < query.endIndex {
    skipGraphQLIgnored(in: query, index: &index)
    if index < query.endIndex, query[index] == "}" {
      index = query.index(after: index)
      return .object(object)
    }
    guard let key = readGraphQLIdentifier(in: query, index: &index) else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL object key is missing")
    }
    skipGraphQLIgnored(in: query, index: &index)
    guard index < query.endIndex, query[index] == ":" else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL object key '\(key)' is missing ':'")
    }
    index = query.index(after: index)
    guard object[key] == nil else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable(
        "duplicate GraphQL input field '\(key)'"
      )
    }
    object[key] = try parseGraphQLValue(
      in: query,
      index: &index,
      variables: variables,
      variableDefinitions: variableDefinitions,
      depth: depth + 1,
      allowUnresolvedVariables: allowUnresolvedVariables,
      usageCollector: usageCollector,
      path: path + [.field(key)]
    )
  }
  throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL object was not closed")
}

func parseGraphQLNumber(in query: String, index: inout String.Index) throws -> JSONValue {
  let start = index
  var isFloatingPoint = false
  if index < query.endIndex, query[index] == "-" {
    index = query.index(after: index)
  }
  while index < query.endIndex, query[index].isNumber {
    index = query.index(after: index)
  }
  if index < query.endIndex, query[index] == "." {
    isFloatingPoint = true
    index = query.index(after: index)
    while index < query.endIndex, query[index].isNumber {
      index = query.index(after: index)
    }
  }
  if index < query.endIndex, query[index] == "e" || query[index] == "E" {
    isFloatingPoint = true
    index = query.index(after: index)
    if index < query.endIndex, query[index] == "-" || query[index] == "+" {
      index = query.index(after: index)
    }
    while index < query.endIndex, query[index].isNumber {
      index = query.index(after: index)
    }
  }
  let raw = String(query[start..<index])
  if isFloatingPoint, let value = Double(raw) {
    return .number(value)
  }
  if let value = Int64(raw) {
    return .integer(value)
  }
  throw NoteGraphQLDocumentExecutorError.invalidVariable("invalid GraphQL number: \(raw)")
}

func readGraphQLIdentifier(in query: String, index: inout String.Index) -> String? {
  skipGraphQLIgnored(in: query, index: &index)
  return readOptionalGraphQLIdentifier(in: query, index: &index)
}

func readOptionalGraphQLIdentifier(in query: String, index: inout String.Index) -> String? {
  skipGraphQLIgnored(in: query, index: &index)
  guard index < query.endIndex, isGraphQLNameStart(query[index]) else {
    return nil
  }
  let start = index
  index = query.index(after: index)
  while index < query.endIndex, isGraphQLNameContinue(query[index]) {
    index = query.index(after: index)
  }
  return String(query[start..<index])
}

func readGraphQLString(in query: String, index: inout String.Index) throws -> String {
  guard index < query.endIndex, query[index] == "\"" else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL string is missing opening quote")
  }
  if query[index...].hasPrefix("\"\"\"") {
    return try readGraphQLBlockString(in: query, index: &index)
  }
  index = query.index(after: index)
  var result = ""
  while index < query.endIndex {
    let character = query[index]
    index = query.index(after: index)
    if character == "\"" {
      return result
    }
    if character == "\\" {
      guard index < query.endIndex else {
        throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL string escape is incomplete")
      }
      let escaped = query[index]
      index = query.index(after: index)
      switch escaped {
      case "\"", "\\", "/":
        result.append(escaped)
      case "b":
        result.append("\u{8}")
      case "f":
        result.append("\u{c}")
      case "n":
        result.append("\n")
      case "r":
        result.append("\r")
      case "t":
        result.append("\t")
      case "u":
        result.append(try readGraphQLUnicodeEscape(in: query, index: &index))
      default:
        throw NoteGraphQLDocumentExecutorError.invalidVariable("unsupported GraphQL string escape: \\\(escaped)")
      }
    } else if character.isNewline {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL string contains an unescaped newline")
    } else {
      result.append(character)
    }
  }
  throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL string was not closed")
}

private func readGraphQLBlockString(in query: String, index: inout String.Index) throws -> String {
  guard query[index...].hasPrefix("\"\"\"") else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL block string is missing opening quote")
  }
  index = query.index(index, offsetBy: 3)
  var result = ""
  while index < query.endIndex {
    if query[index...].hasPrefix("\\\"\"\"") {
      result.append("\"\"\"")
      index = query.index(index, offsetBy: 4)
      continue
    }
    if query[index...].hasPrefix("\"\"\"") {
      index = query.index(index, offsetBy: 3)
      return normalizedGraphQLBlockString(result)
    }
    result.append(query[index])
    index = query.index(after: index)
  }
  throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL block string was not closed")
}

private func normalizedGraphQLBlockString(_ raw: String) -> String {
  let normalized = raw
    .replacingOccurrences(of: "\r\n", with: "\n")
    .replacingOccurrences(of: "\r", with: "\n")
  var lines = normalized.components(separatedBy: "\n")
  while lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
    lines.removeFirst()
  }
  while lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
    lines.removeLast()
  }
  guard !lines.isEmpty else {
    return ""
  }
  let firstIndent = graphQLBlockStringIndent(lines[0])
  let indentCandidates = firstIndent == 0 ? lines.dropFirst() : lines[...].dropLast(0)
  let commonIndent = indentCandidates
    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    .map(graphQLBlockStringIndent)
    .min() ?? 0
  guard commonIndent > 0 else {
    return lines.joined(separator: "\n")
  }
  return lines.enumerated().map { index, line in
    if firstIndent == 0, index == 0 {
      return line
    }
    return String(line.dropFirst(min(commonIndent, line.count)))
  }.joined(separator: "\n")
}

private func graphQLBlockStringIndent(_ line: String) -> Int {
  line.prefix { $0 == " " || $0 == "\t" }.count
}

private func readGraphQLUnicodeEscape(in query: String, index: inout String.Index) throws -> Character {
  if index < query.endIndex, query[index] == "{" {
    index = query.index(after: index)
    let start = index
    while index < query.endIndex, query[index] != "}" {
      index = query.index(after: index)
    }
    guard index < query.endIndex, query[index] == "}" else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL unicode escape was not closed")
    }
    let hex = String(query[start..<index])
    index = query.index(after: index)
    return try graphQLUnicodeScalar(from: hex)
  }
  let start = index
  for _ in 0..<4 {
    guard index < query.endIndex else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL unicode escape is incomplete")
    }
    index = query.index(after: index)
  }
  let value = try graphQLUnicodeScalarValue(from: String(query[start..<index]))
  if (0xD800...0xDBFF).contains(value) {
    guard
      index < query.endIndex,
      query[index] == "\\",
      query.index(after: index) < query.endIndex,
      query[query.index(after: index)] == "u"
    else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL unicode high surrogate is missing a low surrogate")
    }
    index = query.index(index, offsetBy: 2)
    let lowStart = index
    for _ in 0..<4 {
      guard index < query.endIndex else {
        throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL unicode low surrogate is incomplete")
      }
      index = query.index(after: index)
    }
    let low = try graphQLUnicodeScalarValue(from: String(query[lowStart..<index]))
    guard (0xDC00...0xDFFF).contains(low) else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL unicode high surrogate is missing a low surrogate")
    }
    let combined = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
    return try graphQLUnicodeScalar(from: combined)
  }
  guard !(0xDC00...0xDFFF).contains(value) else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL unicode low surrogate is missing a high surrogate")
  }
  return try graphQLUnicodeScalar(from: value)
}

private func graphQLUnicodeScalar(from hex: String) throws -> Character {
  try graphQLUnicodeScalar(from: graphQLUnicodeScalarValue(from: hex))
}

private func graphQLUnicodeScalarValue(from hex: String) throws -> UInt32 {
  guard
    !hex.isEmpty,
    hex.allSatisfy(\.isHexDigit),
    let value = UInt32(hex, radix: 16)
  else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL unicode escape is invalid")
  }
  return value
}

private func graphQLUnicodeScalar(from value: UInt32) throws -> Character {
  guard let scalar = UnicodeScalar(value) else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL unicode escape is invalid")
  }
  return Character(scalar)
}

func skipGraphQLIgnored(in query: String, index: inout String.Index) {
  while index < query.endIndex {
    if query[index].isWhitespace || query[index] == "," {
      index = query.index(after: index)
    } else if query[index] == "#" {
      skipGraphQLComment(in: query, index: &index)
    } else {
      break
    }
  }
}

private func skipGraphQLComment(in query: String, index: inout String.Index) {
  while index < query.endIndex, !query[index].isNewline {
    index = query.index(after: index)
  }
}

func skipGraphQLDefinition(in query: String, index: inout String.Index) throws {
  guard try advanceToGraphQLSelectionSet(in: query, index: &index) else {
    return
  }
  try skipGraphQLBalanced(in: query, index: &index, open: "{", close: "}")
}

func advanceToGraphQLSelectionSet(in query: String, index: inout String.Index) throws -> Bool {
  while index < query.endIndex {
    skipGraphQLIgnored(in: query, index: &index)
    guard index < query.endIndex else {
      return false
    }
    if query[index] == "{" {
      return true
    }
    if query[index] == "(" {
      try skipGraphQLBalanced(in: query, index: &index, open: "(", close: ")")
    } else if query[index] == "\"" {
      try skipGraphQLStringLiteral(in: query, index: &index)
    } else {
      index = query.index(after: index)
    }
  }
  return false
}

func skipGraphQLBalanced(
  in query: String,
  index: inout String.Index,
  open: Character,
  close: Character
) throws {
  guard index < query.endIndex, query[index] == open else {
    return
  }
  var depth = 0
  while index < query.endIndex {
    if query[index] == "\"" {
      try skipGraphQLStringLiteral(in: query, index: &index)
      continue
    }
    if query[index] == "#" {
      skipGraphQLComment(in: query, index: &index)
      continue
    }
    if query[index] == open {
      depth += 1
      if depth > NoteGraphQLDocumentLimits.maximumBalancedBlockDepth {
        throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL block depth limit exceeded")
      }
    } else if query[index] == close {
      depth -= 1
      index = query.index(after: index)
      if depth == 0 {
        return
      }
      continue
    }
    index = query.index(after: index)
  }
  throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL block was not closed")
}

private func skipGraphQLStringLiteral(in query: String, index: inout String.Index) throws {
  guard index < query.endIndex, query[index] == "\"" else {
    return
  }
  if query[index...].hasPrefix("\"\"\"") {
    index = query.index(index, offsetBy: 3)
    while index < query.endIndex {
      if query[index...].hasPrefix("\\\"\"\"") {
        index = query.index(index, offsetBy: 4)
      } else if query[index...].hasPrefix("\"\"\"") {
        index = query.index(index, offsetBy: 3)
        return
      } else {
        index = query.index(after: index)
      }
    }
    throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL block string was not closed")
  }
  index = query.index(after: index)
  while index < query.endIndex {
    if query[index] == "\\" {
      index = query.index(after: index)
      if index < query.endIndex {
        index = query.index(after: index)
      }
    } else if query[index] == "\"" {
      index = query.index(after: index)
      return
    } else {
      index = query.index(after: index)
    }
  }
  throw NoteGraphQLDocumentExecutorError.invalidVariable("GraphQL string was not closed")
}

private func isGraphQLNameStart(_ character: Character) -> Bool {
  guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
    return false
  }
  return scalar.value == 95
    || (65...90).contains(scalar.value)
    || (97...122).contains(scalar.value)
}

private func isGraphQLNameContinue(_ character: Character) -> Bool {
  guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
    return false
  }
  return isGraphQLNameStart(character) || (48...57).contains(scalar.value)
}
