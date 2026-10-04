import Foundation

public extension KaibaClient {
  func searchEngineCapability() async throws -> KaibaSearchEngineCapabilityPayload {
    try await operation(
      "query KaibaSearchEngineCapability { root: searchEngineCapability { result { accepted status diagnostics } enabled } }",
      as: KaibaSearchEngineCapabilityPayload.self
    )
  }

  func engineSearchNotes(
    query: String,
    notebookId: KaibaNotebookID? = nil,
    tagFilter: [String] = [],
    limit: Int = 20,
    offset: Int = 0
  ) async throws -> KaibaValuePayload<[KaibaEngineNoteHit]> {
    var variables: [String: KaibaJSONValue] = [
      "query": .string(query), "limit": .integer(limit), "offset": .integer(offset)
    ]
    if let notebookId { variables["notebookId"] = .string(notebookId.rawValue) }
    if !tagFilter.isEmpty { variables["tagFilter"] = .array(tagFilter.map(KaibaJSONValue.string)) }
    return try await operation(
      """
      query KaibaEngineSearchNotes($query: String!, $notebookId: String, $tagFilter: [String!], $limit: Int, $offset: Int) {
        root: engineSearchNotes(query: $query, notebookId: $notebookId, tagFilter: $tagFilter, limit: $limit, offset: $offset) {
          result { accepted status diagnostics }
          value { note { \(Self.noteFields) } snippet score }
        }
      }
      """,
      variables: variables,
      as: KaibaValuePayload<[KaibaEngineNoteHit]>.self
    )
  }

  func relatedNotes(
    noteId: KaibaNoteID,
    limit: Int = 8
  ) async throws -> KaibaValuePayload<[KaibaEngineNoteHit]> {
    try await operation(
      """
      query KaibaRelatedNotes($noteId: String!, $limit: Int) {
        root: relatedNotes(noteId: $noteId, limit: $limit) {
          result { accepted status diagnostics }
          value { note { \(Self.noteFields) } snippet score }
        }
      }
      """,
      variables: ["noteId": .string(noteId.rawValue), "limit": .integer(limit)],
      as: KaibaValuePayload<[KaibaEngineNoteHit]>.self
    )
  }
}

extension KaibaSearchEngineCapabilityPayload: KaibaControlPlaneDiagnosticsSanitizable {
  func sanitizingDiagnostics(_ sanitizer: (String) -> String) -> Self {
    var copy = self
    copy.result = result.sanitizingDiagnostics(sanitizer)
    return copy
  }
}
