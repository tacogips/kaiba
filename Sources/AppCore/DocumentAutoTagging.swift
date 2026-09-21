import Foundation

/// Post-commit tagging for synchronous imports. Provider failures leave imported
/// content intact and return actionable warnings instead of failing the import.
public struct DocumentAutoTagging: Sendable {
  public var service: NoteService
  public var configuration: KaibaAIConfiguration?
  public var invoker: (any AgentInvoking)?

  public init(service: NoteService, configuration: KaibaAIConfiguration?, invoker: (any AgentInvoking)?) {
    self.service = service
    self.configuration = configuration
    self.invoker = invoker
  }

  public func tag(notebookId: NotebookID, noteIds: [NoteID]) async -> [String] {
    guard configuration?.autoTagEnabled == true else { return [] }
    guard let invoker else {
      return ["Automatic tagging unavailable: configure ai.agent and its agent-gateway runtime."]
    }
    let extraction = AITagExtractionService(
      service: service, invoker: invoker,
      provider: configuration?.agent?.provider, model: configuration?.agent?.model,
      registrationPrompt: configuration?.autoTag?.prompt
    )
    var warnings: [String] = []
    let subjects: [AITagExtractionSubject] = [.notebook(notebookId)] + noteIds.map { .note($0) }
    for subject in subjects {
      do {
        if case .note(let id) = subject {
          let note = try service.getNote(id)
          guard note.notebookId == notebookId else {
            throw NoteServiceError.invalidInput("tagging page belongs to another notebook")
          }
          if let metadata = try? NoteService.importedPageMetadata(note), metadata.ocrState == "pending" {
            continue
          }
        }
        _ = try await extraction.extractTags(subject: subject)
      } catch {
        let target: String
        switch subject {
        case .notebook(let id): target = id.rawValue
        case .note(let id): target = id.rawValue
        }
        warnings.append("Automatic tagging failed for \(target); retry with ai tag after checking the provider.")
      }
    }
    return warnings
  }
}
