import AppCore

public extension GraphQLNoteGraphQLService {
  func fastNotes(query: String = "", limit: Int = 50, offset: Int = 0) async -> GraphQLNoteQueryResult<[GraphQLNoteDTO]> {
    noteResult { try service.fastNotes(query: query, limit: limit, offset: offset).map(GraphQLNoteDTO.init) }
  }
}
