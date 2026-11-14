import Foundation

struct ParsedGraphQLFragment: Equatable, Sendable {
  var typeCondition: String
  var selectionSource: String
}

final class GraphQLFragmentExpansionBudget {
  private var expansionCount = 0
  private(set) var expandedFragmentNames = Set<String>()

  func consume(name: String, depth: Int) throws {
    guard depth < NoteGraphQLDocumentLimits.maximumFragmentExpansionDepth else {
      throw NoteGraphQLDocumentExecutorError.invalidSelection(
        "GraphQL fragment expansion depth limit exceeded"
      )
    }
    expansionCount += 1
    expandedFragmentNames.insert(name)
    guard expansionCount <= NoteGraphQLDocumentLimits.maximumFragmentExpansionCount else {
      throw NoteGraphQLDocumentExecutorError.invalidSelection(
        "GraphQL fragment expansion count limit exceeded"
      )
    }
  }
}

func parseGraphQLFragmentDefinitions(
  in query: String
) throws -> [String: ParsedGraphQLFragment] {
  var fragments: [String: ParsedGraphQLFragment] = [:]
  var index = query.startIndex
  while index < query.endIndex {
    skipGraphQLIgnored(in: query, index: &index)
    guard index < query.endIndex else { return fragments }
    if query[index] == "{" {
      try skipGraphQLBalanced(in: query, index: &index, open: "{", close: "}")
      continue
    }
    let definitionStart = index
    guard let definition = readGraphQLIdentifier(in: query, index: &index) else {
      index = query.index(after: index)
      continue
    }
    guard definition == "fragment" else {
      index = definitionStart
      try skipGraphQLDefinition(in: query, index: &index)
      continue
    }
    guard let name = readOptionalGraphQLIdentifier(in: query, index: &index),
          name != "on",
          readOptionalGraphQLIdentifier(in: query, index: &index) == "on",
          let typeCondition = readOptionalGraphQLIdentifier(in: query, index: &index) else {
      throw NoteGraphQLDocumentExecutorError.invalidSelection("GraphQL fragment definition is malformed")
    }
    guard fragments[name] == nil else {
      throw NoteGraphQLDocumentExecutorError.invalidSelection(
        "duplicate GraphQL fragment definition '\(name)'"
      )
    }
    skipGraphQLIgnored(in: query, index: &index)
    if index < query.endIndex, query[index] == "@" {
      throw NoteGraphQLDocumentExecutorError.invalidSelection(
        "GraphQL directives are not supported on fragment definitions"
      )
    }
    guard index < query.endIndex, query[index] == "{" else {
      throw NoteGraphQLDocumentExecutorError.invalidSelection(
        "GraphQL fragment '\(name)' has an invalid definition"
      )
    }
    let selectionStart = index
    try skipGraphQLBalanced(in: query, index: &index, open: "{", close: "}")
    fragments[name] = ParsedGraphQLFragment(
      typeCondition: typeCondition,
      selectionSource: String(query[selectionStart..<index])
    )
  }
  return fragments
}
