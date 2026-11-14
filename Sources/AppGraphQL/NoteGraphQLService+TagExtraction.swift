import AppCore

public extension GraphQLNoteGraphQLService {
  func requestTagExtraction(
    _ input: GraphQLRequestTagExtractionInput
  ) async -> GraphQLTagExtractionRequestResult {
    do {
      let subject: AITagExtractionSubject
      switch (input.noteId, input.notebookId) {
      case (let noteId?, nil):
        subject = .note(noteId)
      case (nil, let notebookId?):
        subject = .notebook(notebookId)
      default:
        throw GraphQLNoteServiceError.invalidRequest(
          "requestTagExtraction requires exactly one of noteId or notebookId"
        )
      }
      let queued = try service.requestManualTagExtraction(subject: subject)
      return GraphQLTagExtractionRequestResult(
        result: GraphQLControlPlaneResult(accepted: true, status: "ok"),
        status: queued ? "queued" : "agent-unavailable"
      )
    } catch {
      return GraphQLTagExtractionRequestResult(
        result: graphQLNoteResult(for: error),
        status: "error"
      )
    }
  }

  func tagExtractionStatus(noteId: NoteID) -> GraphQLTagExtractionRequestResult {
    do {
      return .init(result: .init(accepted: true, status: "ok"), status: try service.tagExtractionStatus(noteId: noteId).rawValue)
    } catch {
      return .init(result: graphQLNoteResult(for: error), status: "error")
    }
  }
}
