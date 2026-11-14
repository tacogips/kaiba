import Foundation

public extension NoteService {
  func getNotebookForExpansion(_ notebookId: String) throws -> Notebook {
    try driver.withDatabase { database in
      var notebook = try requireNotebook(notebookId, in: database)
      try enrichNotebookListMetadata(&notebook, in: database)
      return notebook
    }
  }

  @discardableResult
  func updateNotebookCompactMetadata(
    notebookId: String,
    compactMetadataJSON: String,
    expectedUpdatedAt: String,
    expectedNoteCount: Int
  ) throws -> Notebook? {
    try driver.withDatabase { database in
      try database.transaction { db in
        let notebook = try requireNotebook(notebookId, in: db)
        guard notebook.updatedAt == expectedUpdatedAt,
              notebook.noteCount == expectedNoteCount else {
          return nil
        }
        let compactMetadata = try notebookJSONObject(
          from: compactMetadataJSON,
          fieldName: "notebook compact metadata"
        )
        var root = try notebookJSONObject(
          from: notebook.metaJSON ?? "{}",
          fieldName: "notebook metadata"
        )
        let existingKaibaNote = root["kaibaNote"]
        guard existingKaibaNote == nil || existingKaibaNote is [String: Any] else {
          throw NoteServiceError.invalidInput("notebook metadata kaibaNote value must be a JSON object")
        }
        var kaibaNote = existingKaibaNote as? [String: Any] ?? [:]
        kaibaNote["notebookCompact"] = compactMetadata
        root["kaibaNote"] = kaibaNote
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        guard let mergedJSON = String(data: data, encoding: .utf8) else {
          throw NoteServiceError.invalidInput("notebook metadata must be UTF-8 JSON")
        }
        try db.execute(
          "UPDATE notebooks SET meta_json = jsonb(?) WHERE notebook_id = ?",
          bindings: [.text(mergedJSON), .text(notebookId)]
        )
        var updated = try requireNotebook(notebookId, in: db)
        try enrichNotebookListMetadata(&updated, in: db)
        return updated
      }
    }
  }
}

private func notebookJSONObject(
  from json: String,
  fieldName: String
) throws -> [String: Any] {
  guard let data = json.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data),
        let dictionary = object as? [String: Any] else {
    throw NoteServiceError.invalidInput("\(fieldName) must be a JSON object")
  }
  return dictionary
}
