import Foundation

public extension NoteService {
  func getNotebookForExpansion(_ notebookId: NotebookID) throws -> Notebook {
    try driver.withDatabase { database in
      var notebook = try requireNotebook(notebookId, in: database)
      try enrichNotebookListMetadata(&notebook, in: database)
      return notebook
    }
  }

  @discardableResult
  func updateNotebookCompactMetadata(
    notebookId: NotebookID,
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
        guard existingKaibaNote == nil || existingKaibaNote?.asObject != nil else {
          throw NoteServiceError.invalidInput("notebook metadata kaibaNote value must be a JSON object")
        }
        var kaibaNote = existingKaibaNote?.asObject ?? [:]
        kaibaNote["notebookCompact"] = .object(compactMetadata)
        root["kaibaNote"] = .object(kaibaNote)
        let mergedJSON: String
        do {
          mergedJSON = try JSONValue.object(root).encodedString()
        } catch {
          throw NoteServiceError.invalidInput("notebook metadata must be UTF-8 JSON")
        }
        try db.execute(
          "UPDATE notebooks SET meta_json = jsonb(?), updated_by = owner_user_id WHERE notebook_id = ?",
          bindings: [.text(mergedJSON), .id(notebookId)]
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
) throws -> JSONObject {
  guard let object = (try? JSONValue(parsing: json))?.asObject else {
    throw NoteServiceError.invalidInput("\(fieldName) must be a JSON object")
  }
  return object
}
