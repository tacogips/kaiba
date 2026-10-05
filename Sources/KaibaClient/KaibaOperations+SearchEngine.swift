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
          value { note { \(Self.noteFields) } snippet score reasons { kind tags } }
        }
      }
      """,
      variables: variables,
      as: KaibaValuePayload<[KaibaEngineNoteHit]>.self
    )
  }

  func engineSearchNotesPage(
    query: String,
    notebookId: KaibaNotebookID? = nil,
    tagFilter: [String] = [],
    tagClassFilter: [String] = [],
    expandOntology: Bool = true,
    facets: Bool = false,
    limit: Int = 20,
    offset: Int = 0
  ) async throws -> KaibaEngineSearchPagePayload {
    var variables: [String: KaibaJSONValue] = [
      "query": .string(query), "expandOntology": .bool(expandOntology), "facets": .bool(facets),
      "limit": .integer(limit), "offset": .integer(offset)
    ]
    if let notebookId { variables["notebookId"] = .string(notebookId.rawValue) }
    if !tagFilter.isEmpty { variables["tagFilter"] = .array(tagFilter.map(KaibaJSONValue.string)) }
    if !tagClassFilter.isEmpty { variables["tagClassFilter"] = .array(tagClassFilter.map(KaibaJSONValue.string)) }
    return try await operation(
      """
      query KaibaEngineSearchNotesPage($query: String!, $notebookId: String, $tagFilter: [String!], $tagClassFilter: [String!], $expandOntology: Boolean, $facets: Boolean, $limit: Int, $offset: Int) {
        root: engineSearchNotes(query: $query, notebookId: $notebookId, tagFilter: $tagFilter, tagClassFilter: $tagClassFilter, expandOntology: $expandOntology, facets: $facets, limit: $limit, offset: $offset) {
          result { accepted status diagnostics }
          value { note { \(Self.noteFields) } snippet score reasons { kind tags } }
          facets { tagClasses { value count } tags { tagId name tagClass count } }
        }
      }
      """,
      variables: variables,
      as: KaibaEngineSearchPagePayload.self
    )
  }

  func searchEngineSettings() async throws -> KaibaSearchEngineSettingsPayload {
    try await operation(
      """
      query KaibaSearchEngineSettings {
        root: searchEngineSettings {
          result { accepted status diagnostics }
          value {
            managedBy kind url indexPrefix authMode username hasSecret verifyTLS requestTimeoutSeconds
            adapters { kind displayName authModes defaultURL }
            active
          }
        }
      }
      """,
      as: KaibaSearchEngineSettingsPayload.self
    )
  }

  func updateSearchEngineSettings(
    _ input: KaibaSearchEngineSettingsInput
  ) async throws -> KaibaSearchEngineSettingsPayload {
    try await operation(
      """
      mutation KaibaUpdateSearchEngineSettings($input: SearchEngineSettingsInput!) {
        root: updateSearchEngineSettings(input: $input) {
          result { accepted status diagnostics }
          value {
            managedBy kind url indexPrefix authMode username hasSecret verifyTLS requestTimeoutSeconds
            adapters { kind displayName authModes defaultURL }
            active
          }
        }
      }
      """,
      variables: ["input": try Self.searchEngineInputValue(input)],
      as: KaibaSearchEngineSettingsPayload.self
    )
  }

  func testSearchEngineConnection(
    _ input: KaibaSearchEngineSettingsInput
  ) async throws -> KaibaSearchEngineConnectionTestPayload {
    try await operation(
      """
      mutation KaibaTestSearchEngineConnection($input: SearchEngineSettingsInput!) {
        root: testSearchEngineConnection(input: $input) {
          result { accepted status diagnostics }
          value { available status detail }
        }
      }
      """,
      variables: ["input": try Self.searchEngineInputValue(input)],
      as: KaibaSearchEngineConnectionTestPayload.self
    )
  }

  private static func searchEngineInputValue(_ input: KaibaSearchEngineSettingsInput) throws -> KaibaJSONValue {
    try JSONDecoder().decode(KaibaJSONValue.self, from: JSONEncoder().encode(input))
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
          value { note { \(Self.noteFields) } snippet score reasons { kind tags } }
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

extension KaibaEngineSearchPagePayload: KaibaControlPlaneDiagnosticsSanitizable {
  func sanitizingDiagnostics(_ sanitizer: (String) -> String) -> Self {
    var copy = self
    copy.result = result.sanitizingDiagnostics(sanitizer)
    return copy
  }
}

extension KaibaSearchEngineSettingsPayload: KaibaControlPlaneDiagnosticsSanitizable {
  func sanitizingDiagnostics(_ sanitizer: (String) -> String) -> Self {
    var copy = self
    copy.result = result.sanitizingDiagnostics(sanitizer)
    return copy
  }
}

extension KaibaSearchEngineConnectionTestPayload: KaibaControlPlaneDiagnosticsSanitizable {
  func sanitizingDiagnostics(_ sanitizer: (String) -> String) -> Self {
    var copy = self
    copy.result = result.sanitizingDiagnostics(sanitizer)
    return copy
  }
}
