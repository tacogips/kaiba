package enum NotebookIngestAutoActionPolicy: Sendable {
  case immediate
  case deferredUntilFinalized
}

package extension NoteService {
  /// Atomically consumes a package-owned deferred-ingest lifecycle marker,
  /// makes its auto-actions eligible, and publishes one terminal change.
  func finalizeDeferredNotebookIngestAutoActions(
    _ ingest: NotebookIngestResult,
    originatingActionId: AutoActionID? = nil
  ) throws {
    let outcome = try driver.withDatabase { database in
      try database.transaction { db -> (Notebook, [QueuedAutoActionDispatch]) in
        let notebook = try requireNotebook(ingest.notebook.notebookId, in: db)
        var metadata = try deferredNotebookIngestMetadata(notebook.metaJSON, ingest: ingest)
        let notes = try ingest.notes.map { note in
          let current = try requireNote(note.noteId, in: db)
          guard current.notebookId == notebook.notebookId else {
            throw NoteServiceError.invalidInput("deferred ingest note does not belong to its notebook")
          }
          return current
        }
        var queued = try enqueueAutoActions(
          for: makeAutoActionEvent(
            trigger: .notebookCreated,
            notebookId: notebook.notebookId,
            originatingActionId: originatingActionId
          ),
          in: db
        )
        for note in notes {
          queued.append(contentsOf: try enqueueAutoActions(
            for: makeAutoActionEvent(
              trigger: .noteCreated,
              notebookId: notebook.notebookId,
              noteId: note.noteId,
              noteBodyMarkdown: note.bodyMarkdown,
              originatingActionId: originatingActionId
            ),
            in: db
          ))
        }
        metadata.removeValue(forKey: Self.deferredIngestLifecycleMetadataKey)
        let cleanMetadata = metadata.isEmpty ? nil : try JSONValue.object(metadata).encodedString()
        if let cleanMetadata {
          try db.execute(
            "UPDATE notebooks SET meta_json = jsonb(?) WHERE notebook_id = ?",
            bindings: [.text(cleanMetadata), .id(notebook.notebookId)]
          )
        } else {
          try db.execute(
            "UPDATE notebooks SET meta_json = NULL WHERE notebook_id = ?",
            bindings: [.id(notebook.notebookId)]
          )
        }
        var terminalRecorder = self
        terminalRecorder.suppressesActionHistory = false
        try terminalRecorder.recordAction(
          NoteActionRecord(
            kind: .notebookIngested,
            provenance: .system,
            entityType: .notebook,
            entityId: notebook.notebookId.rawValue,
            notebookId: notebook.notebookId,
            display: [
              "title": .string(notebook.title),
              "noteCount": .integer(Int64(notes.count))
            ],
            undoable: false
          ),
          in: db
        )
        var finalized = notebook
        finalized.metaJSON = cleanMetadata
        return (finalized, queued)
      }
    }
    dispatchQueuedAutoActions(outcome.1)
    changeObserver?.noteStoreDidChange(NoteChangeEvent(
      kind: NoteChangeEventKind.notebookCreated,
      notebookId: outcome.0.notebookId,
      tagNames: folderTagNames(of: outcome.0)
    ))
  }
}

extension NoteService {
  static let deferredIngestLifecycleMetadataKey = "_kaibaDeferredNotebookIngestAutoActions"

  func markDeferredNotebookIngestAutoActions(
    _ ingest: NotebookIngestResult,
    callerMetadataJSON: String?,
    in db: SQLiteDatabase
  ) throws -> NotebookIngestResult {
    var metadata: JSONObject
    if let callerMetadataJSON {
      guard let object = (try? JSONValue(parsing: callerMetadataJSON))?.asObject else {
        throw NoteServiceError.invalidInput("notebook ingest metaJSON must encode a JSON object")
      }
      metadata = object
    } else {
      metadata = [:]
    }
    guard metadata[Self.deferredIngestLifecycleMetadataKey] == nil else {
      throw NoteServiceError.invalidInput("deferred notebook ingest metadata is server-managed")
    }
    metadata[Self.deferredIngestLifecycleMetadataKey] = .object([
      "noteIds": .array(ingest.notes.map { .string($0.noteId.rawValue) }),
      "state": .string("pending")
    ])
    let markedMetadata = try JSONValue.object(metadata).encodedString()
    try db.execute(
      "UPDATE notebooks SET meta_json = jsonb(?) WHERE notebook_id = ?",
      bindings: [.text(markedMetadata), .id(ingest.notebook.notebookId)]
    )
    var marked = ingest
    marked.notebook.metaJSON = markedMetadata
    return marked
  }
}

private extension NoteService {
  func deferredNotebookIngestMetadata(
    _ metaJSON: String?,
    ingest: NotebookIngestResult
  ) throws -> JSONObject {
    guard let metaJSON,
          let metadata = (try? JSONValue(parsing: metaJSON))?.asObject,
          let lifecycle = metadata[Self.deferredIngestLifecycleMetadataKey]?.asObject,
          lifecycle["state"]?.asString == "pending",
          let noteIdValues = lifecycle["noteIds"]?.asArray,
          noteIdValues.allSatisfy({ $0.asString != nil }) else {
      throw NoteServiceError.conflict("notebook ingest auto-actions are not pending finalization")
    }
    let expectedNoteIds = noteIdValues.compactMap(\.asString).map(NoteID.init)
    guard expectedNoteIds == ingest.notes.map(\.noteId) else {
      throw NoteServiceError.invalidInput("deferred ingest notes do not match the pending lifecycle")
    }
    return metadata
  }
}
