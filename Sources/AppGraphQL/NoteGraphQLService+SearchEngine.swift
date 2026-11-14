import Foundation

import AppCore

public struct GraphQLSearchEngineCapabilityPayload: Codable, Equatable, Sendable {
  public var result: GraphQLControlPlaneResult
  public var enabled: Bool
}

public struct GraphQLEngineNoteHitDTO: Codable, Equatable, Sendable {
  public var note: GraphQLNoteDTO
  public var snippet: String
  public var score: Double
  public var reasons: [GraphQLEngineHitReasonDTO]

  public init(hit: NoteEngineSearchHit) {
    note = GraphQLNoteDTO(note: hit.note)
    snippet = hit.snippet
    score = hit.score
    reasons = hit.reasons.map { GraphQLEngineHitReasonDTO(kind: $0.kind.rawValue, tags: $0.tagNames) }
  }
}

public struct GraphQLEngineHitReasonDTO: Codable, Equatable, Sendable {
  public var kind: String
  public var tags: [String]
}

public struct GraphQLEngineFacetBucketDTO: Codable, Equatable, Sendable {
  public var value: String
  public var count: Int
}

public struct GraphQLEngineTagFacetBucketDTO: Codable, Equatable, Sendable {
  public var tagId: String
  public var name: String
  public var tagClass: String?
  public var count: Int
}

public struct GraphQLEngineSearchFacetsDTO: Codable, Equatable, Sendable {
  public var tagClasses: [GraphQLEngineFacetBucketDTO]
  public var tags: [GraphQLEngineTagFacetBucketDTO]

  public init(facets: NoteEngineSearchFacets) {
    tagClasses = facets.tagClasses.map { .init(value: $0.value, count: $0.count) }
    tags = facets.tags.map {
      .init(tagId: $0.tagId.rawValue, name: $0.name, tagClass: $0.tagClass, count: $0.count)
    }
  }
}

public struct GraphQLEngineNoteSearchPage: Codable, Equatable, Sendable {
  public var result: GraphQLControlPlaneResult
  public var value: [GraphQLEngineNoteHitDTO]?
  public var facets: GraphQLEngineSearchFacetsDTO?
}

public extension GraphQLNoteGraphQLService {
  func searchEngineCapability() async -> GraphQLSearchEngineCapabilityPayload {
    GraphQLSearchEngineCapabilityPayload(
      result: .init(accepted: true, status: "ok"),
      enabled: service.isSearchEngineEnabled
    )
  }

  func engineSearchNotes(
    query: String,
    notebookId: NotebookID?,
    tagFilter: [String],
    tagClassFilter: [String] = [],
    expandOntology: Bool = true,
    facets: Bool = false,
    limit: Int,
    offset: Int
  ) async -> GraphQLEngineNoteSearchPage {
    do {
      let page = try await service.engineSearchNotesPage(
        query: query, notebookId: notebookId, tagFilter: tagFilter, tagClassFilter: tagClassFilter,
        expandOntology: expandOntology, includeFacets: facets, limit: limit, offset: offset
      )
      return GraphQLEngineNoteSearchPage(
        result: GraphQLControlPlaneResult(accepted: true, status: "ok"),
        value: page.hits.map(GraphQLEngineNoteHitDTO.init),
        facets: page.facets.map(GraphQLEngineSearchFacetsDTO.init)
      )
    } catch SearchEngineError.notConfigured {
      return GraphQLEngineNoteSearchPage(result: searchEngineDisabledResult(), value: nil, facets: nil)
    } catch is SearchEngineError {
      return GraphQLEngineNoteSearchPage(result: searchEngineUnavailableResult(), value: nil, facets: nil)
    } catch {
      return GraphQLEngineNoteSearchPage(result: graphQLNoteResult(for: error), value: nil, facets: nil)
    }
  }

  func relatedNotes(
    noteId: NoteID,
    limit: Int
  ) async -> GraphQLEngineNoteSearchPage {
    do {
      let hits = try await service.relatedNotes(noteId: noteId, limit: limit)
      return GraphQLEngineNoteSearchPage(
        result: GraphQLControlPlaneResult(accepted: true, status: "ok"),
        value: hits.map(GraphQLEngineNoteHitDTO.init), facets: nil
      )
    } catch SearchEngineError.notConfigured {
      return GraphQLEngineNoteSearchPage(result: searchEngineDisabledResult(), value: nil, facets: nil)
    } catch is SearchEngineError {
      return GraphQLEngineNoteSearchPage(result: searchEngineUnavailableResult(), value: nil, facets: nil)
    } catch {
      return GraphQLEngineNoteSearchPage(result: graphQLNoteResult(for: error), value: nil, facets: nil)
    }
  }
}

private func searchEngineDisabledResult() -> GraphQLControlPlaneResult {
  GraphQLControlPlaneResult(
    accepted: false, status: "feature-disabled", diagnostics: ["search engine is not configured"]
  )
}

private func searchEngineUnavailableResult() -> GraphQLControlPlaneResult {
  GraphQLControlPlaneResult(
    accepted: false, status: "search-engine-unavailable", diagnostics: ["search engine unavailable"]
  )
}
