import Foundation

extension AITranslationService {
  /// Runs synchronous callers through bounded durable chunks. Server and
  /// outbox dispatches call `runChunk` directly so one lease can never spend
  /// an unbounded provider budget.
  @discardableResult
  public func run(
    translationNotebookId: NotebookID,
    originatingActionId: AutoActionID? = NoteService.manualTranslationActionId
  ) async throws -> Notebook {
    var reconciliationRounds = 0
    do {
      while true {
        switch try await runChunk(
          translationNotebookId: translationNotebookId,
          originatingActionId: originatingActionId
        ) {
        case let .completed(notebook):
          return notebook
        case let .pending(_, reconciliationRequired):
          if reconciliationRequired {
            reconciliationRounds += 1
            guard reconciliationRounds < AITranslationReconciliationLimits.maximumRounds else {
              throw AgentInvocationError.failed(
                "translation source set did not converge within the reconciliation budget"
              )
            }
          }
          await Task.yield()
        }
      }
    } catch {
      try markFailedTranslationIfPossible(translationNotebookId: translationNotebookId, error: error)
      throw error
    }
  }

  private func markFailedTranslationIfPossible(translationNotebookId: NotebookID, error: Error) throws {
    do {
      let notebook = try service.getNotebook(translationNotebookId)
      guard let state = NoteService.translationState(of: notebook) else { return }
      _ = try service.setNotebookTranslationStatus(
        translationNotebookId,
        status: .failed,
        errorMessage: "\(error)",
        expectedSourceNotebookId: state.sourceNotebookId,
        expectedLibraryId: notebook.libraryId
      )
    } catch let statusError as NoteServiceError {
      if case .accountUnavailable = statusError {
        throw statusError
      }
    } catch {
      // Keep the original provider/persistence failure. Boundary validation
      // deliberately leaves a moved translation pending.
    }
  }
}
