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

  public init(hit: NoteEngineSearchHit) {
    note = GraphQLNoteDTO(note: hit.note)
    snippet = hit.snippet
    score = hit.score
  }
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
    limit: Int,
    offset: Int
  ) async -> GraphQLNoteQueryResult<[GraphQLEngineNoteHitDTO]> {
    do {
      let hits = try await service.engineSearchNotes(
        query: query, notebookId: notebookId, tagFilter: tagFilter, limit: limit, offset: offset
      )
      return GraphQLNoteQueryResult(result: GraphQLControlPlaneResult(accepted: true, status: "ok"), value: hits.map(GraphQLEngineNoteHitDTO.init))
    } catch SearchEngineError.notConfigured {
      return GraphQLNoteQueryResult(result: searchEngineDisabledResult())
    } catch is SearchEngineError {
      return GraphQLNoteQueryResult(result: searchEngineUnavailableResult())
    } catch {
      return GraphQLNoteQueryResult(result: graphQLNoteResult(for: error))
    }
  }

  func relatedNotes(
    noteId: NoteID,
    limit: Int
  ) async -> GraphQLNoteQueryResult<[GraphQLEngineNoteHitDTO]> {
    do {
      let hits = try await service.relatedNotes(noteId: noteId, limit: limit)
      return GraphQLNoteQueryResult(result: GraphQLControlPlaneResult(accepted: true, status: "ok"), value: hits.map(GraphQLEngineNoteHitDTO.init))
    } catch SearchEngineError.notConfigured {
      return GraphQLNoteQueryResult(result: searchEngineDisabledResult())
    } catch is SearchEngineError {
      return GraphQLNoteQueryResult(result: searchEngineUnavailableResult())
    } catch {
      return GraphQLNoteQueryResult(result: graphQLNoteResult(for: error))
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
