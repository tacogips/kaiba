import AppCore
import Foundation

public extension GraphQLNoteGraphQLService {
  /// Original bytes and write authority come from the scoped store, never a
  /// client path or URL. forceOCR allows replacing existing extracted text.
  func recognizeDocumentPage(noteId: NoteID, forceOCR: Bool = false) async -> GraphQLNoteMutationResult {
    guard let lease = service.agentExecutionAdmission.acquire(principalId: service.agentExecutionPrincipalId()) else {
      return .init(result: .init(accepted: false, status: "overloaded", diagnostics: ["OCR is busy; try again shortly."]))
    }
    defer { service.agentExecutionAdmission.release(lease) }
    return await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: noteMutation {
          let note = try service.recognizeDocumentPage(
            noteId: noteId, recognizer: documentPageRecognizer, analyzer: documentPageAnalyzer, forceOCR: forceOCR
          )
          return .init(result: .init(accepted: true, status: "ok"), note: GraphQLNoteDTO(note: note))
        })
      }
    }
  }
}

public extension GraphQLNoteGraphQLService {
  func documentPageText(noteId: NoteID) -> GraphQLNoteQueryResult<DocumentPageText> {
    noteResult { try service.documentPageText(noteId: noteId) }
  }
}

public extension GraphQLNoteGraphQLService {
  func noteTranslations(noteId: NoteID) -> GraphQLNoteQueryResult<[NoteTranslation]> {
    noteResult { try service.noteTranslations(noteId: noteId) }
  }

  func translationJobs(notebookId: NotebookID) -> GraphQLNoteQueryResult<[TranslationJob]> {
    noteResult { try service.translationJobs(notebookId: notebookId) }
  }
}
