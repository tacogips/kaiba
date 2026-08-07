import Foundation

struct ParsedNoteGraphQLOperation: Equatable, Sendable {
  var name: String?
  var rootFields: [ParsedNoteGraphQLRootField]
}

func parseNoteGraphQLOperations(
  in query: String,
  operationName requestedOperationName: String?,
  variables: JSONObject,
  parseArguments: Bool
) throws -> [ParsedNoteGraphQLOperation] {
  try validateNoteGraphQLDocumentLength(query)
  let fragments = try parseGraphQLFragmentDefinitions(in: query)
  let operationCount = try graphQLExecutableOperationCount(in: query)
  let fragmentBudget = GraphQLFragmentExpansionBudget()
  var index = query.startIndex
  var operations: [ParsedNoteGraphQLOperation] = []
  while index < query.endIndex {
    skipGraphQLIgnored(in: query, index: &index)
    guard index < query.endIndex else { break }
    if query[index] == "{" {
      let isSelected = requestedOperationName == nil && operationCount == 1
      let rootFields = try parseGraphQLRootSelections(
        in: query,
        index: &index,
        operationType: .query,
        variables: isSelected ? variables : [:],
        variableDefinitions: [:],
        parseArguments: parseArguments,
        fragments: fragments,
        fragmentStack: [],
        fragmentBudget: fragmentBudget,
        allowUnresolvedVariables: !isSelected
      )
      try rootFields.forEach(validateGraphQLVariableUsages)
      if parseArguments {
        try validateGraphQLVariableDeclarations([:], usedBy: rootFields)
      }
      operations.append(ParsedNoteGraphQLOperation(
        name: nil,
        rootFields: rootFields
      ))
      continue
    }
    guard let operation = readGraphQLIdentifier(in: query, index: &index) else {
      throw NoteGraphQLDocumentExecutorError.invalidSelection(
        "GraphQL document contains an invalid top-level definition"
      )
    }
    if operation == "fragment" {
      try skipGraphQLDefinition(in: query, index: &index)
      continue
    }
    let operationType: GraphQLDocumentOperationType
    switch operation {
    case "query":
      operationType = .query
    case "mutation":
      operationType = .mutation
    default:
      throw NoteGraphQLDocumentExecutorError.invalidSelection(
        "unsupported GraphQL operation '\(operation)'"
      )
    }
    let operationName = readOptionalGraphQLIdentifier(in: query, index: &index)
    let isSelected = requestedOperationName.map { $0 == operationName }
      ?? (operationCount == 1)
    skipGraphQLIgnored(in: query, index: &index)
    var operationVariables = isSelected ? variables : [:]
    var variableDefinitions: [String: ParsedGraphQLVariableDefinition] = [:]
    if index < query.endIndex, query[index] == "(" {
      let definitions = try parseGraphQLVariableDefinitions(in: query, index: &index)
      variableDefinitions = definitions.values
      operationVariables = definitions.defaults.merging(operationVariables) { _, provided in provided }
    }
    try rejectGraphQLDirectives(in: query, index: &index, reject: parseArguments)
    skipGraphQLIgnored(in: query, index: &index)
    guard index < query.endIndex, query[index] == "{" else {
      throw NoteGraphQLDocumentExecutorError.invalidSelection(
        "GraphQL operation is missing a selection set"
      )
    }
    let rootFields = try parseGraphQLRootSelections(
      in: query,
      index: &index,
      operationType: operationType,
      variables: operationVariables,
      variableDefinitions: variableDefinitions,
      parseArguments: parseArguments,
      fragments: fragments,
      fragmentStack: [],
      fragmentBudget: fragmentBudget,
      allowUnresolvedVariables: !isSelected
    )
    try rootFields.forEach(validateGraphQLVariableUsages)
    if parseArguments {
      try validateGraphQLVariableDeclarations(variableDefinitions, usedBy: rootFields)
    }
    operations.append(ParsedNoteGraphQLOperation(
      name: operationName,
      rootFields: rootFields
    ))
  }
  let unusedFragments = Set(fragments.keys).subtracting(fragmentBudget.expandedFragmentNames)
  guard unusedFragments.isEmpty else {
    throw NoteGraphQLDocumentExecutorError.invalidSelection(
      "unused GraphQL fragment(s): \(unusedFragments.sorted().joined(separator: ", "))"
    )
  }
  return operations
}

func selectNoteGraphQLOperation(
  _ operations: [ParsedNoteGraphQLOperation],
  operationName: String?
) throws -> ParsedNoteGraphQLOperation? {
  if let operationName {
    return operations.first { $0.name == operationName }
  }
  guard operations.count <= 1 else {
    throw NoteGraphQLDocumentExecutorError.invalidSelection(
      "GraphQL operationName is required when a document contains multiple operations"
    )
  }
  return operations.first
}

func graphQLExecutableOperationCount(in query: String) throws -> Int {
  var index = query.startIndex
  var count = 0
  var anonymousOperationCount = 0
  var operationNames = Set<String>()
  while index < query.endIndex {
    skipGraphQLIgnored(in: query, index: &index)
    guard index < query.endIndex else { break }
    if query[index] == "{" {
      count += 1
      anonymousOperationCount += 1
      try skipGraphQLBalanced(in: query, index: &index, open: "{", close: "}")
      continue
    }
    guard let operation = readGraphQLIdentifier(in: query, index: &index) else {
      throw NoteGraphQLDocumentExecutorError.invalidSelection(
        "GraphQL document contains an invalid top-level definition"
      )
    }
    if operation == "fragment" {
      try skipGraphQLDefinition(in: query, index: &index)
      continue
    }
    guard ["query", "mutation", "subscription"].contains(operation) else {
      throw NoteGraphQLDocumentExecutorError.invalidSelection(
        "unsupported GraphQL top-level definition '\(operation)'"
      )
    }
    count += 1
    if let operationName = readOptionalGraphQLIdentifier(in: query, index: &index) {
      guard operationNames.insert(operationName).inserted else {
        throw NoteGraphQLDocumentExecutorError.invalidSelection(
          "duplicate GraphQL operation name '\(operationName)'"
        )
      }
    } else {
      anonymousOperationCount += 1
    }
    skipGraphQLIgnored(in: query, index: &index)
    if index < query.endIndex, query[index] == "(" {
      _ = try parseGraphQLVariableDefinitions(in: query, index: &index)
    }
    try rejectGraphQLDirectives(in: query, index: &index, reject: false)
    skipGraphQLIgnored(in: query, index: &index)
    guard index < query.endIndex, query[index] == "{" else {
      throw NoteGraphQLDocumentExecutorError.invalidSelection(
        "GraphQL operation is missing a selection set"
      )
    }
    try skipGraphQLBalanced(in: query, index: &index, open: "{", close: "}")
  }
  guard anonymousOperationCount == 0 || count == 1 else {
    throw NoteGraphQLDocumentExecutorError.invalidSelection(
      "an anonymous GraphQL operation must be the document's only operation"
    )
  }
  return count
}
