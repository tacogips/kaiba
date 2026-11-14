import Foundation

import AppCore

extension GraphQLNoteGraphQLService {
  func engineSeededSearchNotes(
    query: String,
    tagFilter: [String],
    classFilter: [String],
    notebookId: NotebookID?,
    sort: NoteListSort,
    createdAfter: String?,
    createdBefore: String?,
    depth: Int,
    limit: Int,
    offset: Int
  ) async -> GraphQLNoteQueryResult<[GraphQLNoteSearchResultDTO]> {
    do {
      let outcome = try await service.retrieveNotes(
        query: query,
        tagFilter: tagFilter,
        classFilter: classFilter,
        notebookId: notebookId,
        sort: sort,
        createdAfter: createdAfter,
        createdBefore: createdBefore,
        includeLinked: true,
        depth: depth,
        limit: limit,
        offset: offset
      )
      return GraphQLNoteQueryResult(
        result: GraphQLControlPlaneResult(accepted: true, status: "ok"),
        value: outcome.results.map(GraphQLNoteSearchResultDTO.init)
      )
    } catch {
      return GraphQLNoteQueryResult(result: graphQLNoteResult(for: error))
    }
  }
}
