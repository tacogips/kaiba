import AppCore

public extension GraphQLNoteGraphQLService {
  func rebuildNotebookSearchIndex(notebookId: NotebookID) async -> GraphQLNoteMutationResult {
    noteMutation {
      let report = try service.rebuildNotebookSearchIndex(notebookId: notebookId)
      let message = "Rebuilt \(report.notes) notes/pages and \(report.conversationTurns) AI conversation turns. "
        + (report.engineQueued ? "Search engine refresh queued." : "Local search rebuilt; external search engine is not active.")
      return .init(result: .init(accepted: true, status: report.engineQueued ? "queued" : "local-only", diagnostics: [message]))
    }
  }
}
