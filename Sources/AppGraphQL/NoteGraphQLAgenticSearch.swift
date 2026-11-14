import Foundation

import AppCore

extension GraphQLNoteGraphQLService {
  /// Agentic search: the configured agent answers a search question over the
  /// store, with the kaiba CLI usage in its prompt and a grep pass as
  /// grounding context. `status` is "ok", "agent-unavailable", or "failed".
  public func agenticSearch(
    query: String,
    notebookId: NotebookID? = nil,
    limit: Int = 20
  ) async -> GraphQLAgenticSearchResult {
    guard let agentInvoker else {
      return GraphQLAgenticSearchResult(
        result: GraphQLControlPlaneResult(accepted: true, status: "ok"),
        status: "agent-unavailable"
      )
    }
    do {
      let search = AIAgenticSearchService(
        service: service,
        invoker: agentInvoker,
        provider: agentProvider,
        model: agentModel
      )
      let outcome = try await search.search(query: query, notebookId: notebookId, limit: limit)
      return GraphQLAgenticSearchResult(
        result: GraphQLControlPlaneResult(accepted: true, status: "ok"),
        status: "ok",
        answerMarkdown: outcome.answerMarkdown
      )
    } catch {
      let result: GraphQLControlPlaneResult
      let reason: String
      if let invocationError = error as? AgentInvocationError {
        reason = invocationError.publicDiagnostic
        result = GraphQLControlPlaneResult(accepted: false, status: "error", diagnostics: [reason])
      } else {
        result = graphQLNoteResult(for: error)
        reason = result.diagnostics.first ?? "note operation failed"
      }
      agenticSearchFailureLog("kaiba: agenticSearch failed: \(reason)")
      return GraphQLAgenticSearchResult(result: result, status: "failed")
    }
  }
}
