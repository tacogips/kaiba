import AppCore
import Foundation

public extension GraphQLNoteGraphQLService {
  func renameNotebook(notebookId: NotebookID, title: String) async -> GraphQLNoteMutationResult {
    noteMutation {
      let notebook = try service.renameNotebook(notebookId: notebookId, title: title)
      return .init(result: .init(accepted: true, status: "ok"), notebook: GraphQLNotebookDTO(notebook: notebook))
    }
  }
}
