import Foundation

extension AITranslationService {
  /// Runs synchronous callers through bounded durable chunks. Server and
  /// outbox dispatches call `runChunk` directly so one lease can never spend
  /// an unbounded provider budget.
  @discardableResult
  public func run(jobId: TranslationJobID) async throws -> TranslationJob {
    var reconciliationRounds = 0
    do {
      while true {
        switch try await runChunk(jobId: jobId) {
        case let .completed(job):
          return job
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
      try markFailedTranslationIfPossible(jobId: jobId, error: error)
      throw error
    }
  }

  private func markFailedTranslationIfPossible(jobId: TranslationJobID, error: Error) throws {
    do {
      guard try service.getTranslationJob(jobId).status == .pending else { return }
      _ = try service.setTranslationJobStatus(jobId, status: .failed, errorMessage: "\(error)")
    } catch let statusError as NoteServiceError {
      if case .accountUnavailable = statusError {
        throw statusError
      }
    } catch {
      // Keep the original provider/persistence failure.
    }
  }
}
