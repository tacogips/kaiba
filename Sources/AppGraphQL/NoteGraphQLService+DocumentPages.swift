import AppCore
import Foundation

public extension GraphQLNoteGraphQLService {
  /// The caller supplies only a note ID. Original bytes and pending-state
  /// authority always come from the scoped store, never a client path or URL.
  func recognizeDocumentPage(noteId: NoteID) async -> GraphQLNoteMutationResult {
    guard let lease = service.agentExecutionAdmission.acquire(principalId: service.agentExecutionPrincipalId()) else {
      return .init(result: .init(accepted: false, status: "overloaded", diagnostics: ["OCR is busy; try again shortly."]))
    }
    defer { service.agentExecutionAdmission.release(lease) }
    return await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: noteMutation {
          let note = try service.recognizeDocumentPage(
            noteId: noteId, recognizer: documentPageRecognizer, analyzer: documentPageAnalyzer,
            figureExtractor: documentPageFigureExtractor
          )
          return .init(result: .init(accepted: true, status: "ok"), note: GraphQLNoteDTO(note: note))
        })
      }
    }
  }
}
