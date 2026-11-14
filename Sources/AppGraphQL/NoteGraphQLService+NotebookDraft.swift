import AppCore
import Foundation

public struct GraphQLSaveNotebookDraftInput: Codable, Sendable {
  public var notebookId: NotebookID
  public var title: String
  public var bodies: [String]
}

public extension GraphQLNoteGraphQLService {
  func saveNotebookDraft(_ input: GraphQLSaveNotebookDraftInput) async -> GraphQLNoteMutationResult {
    noteMutation {
      let notebook = try service.saveNotebookDraft(notebookId: input.notebookId, title: input.title, bodies: input.bodies)
      return .init(result: .init(accepted: true, status: "ok"), notebook: GraphQLNotebookDTO(notebook: notebook))
    }
  }
}
