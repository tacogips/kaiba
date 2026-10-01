import Foundation

public extension NoteService {
  /// Completes deferred OCR from the stored original. Recognition runs outside
  /// the transaction; concurrent note changes cause the final compare-and-write to fail.
  @discardableResult
  func recognizeDocumentPage(
    noteId: NoteID,
    recognizer: any DocumentPageRecognizing,
    analyzer: (any DocumentPageAnalyzing)? = nil
  ) throws -> Note {
    let snapshot = try driver.withDatabase { db in
      try requireEnabledActingUser(in: db)
      return try requirePendingDocumentOCRNote(noteId, in: db)
    }
    let metadata = try Self.importedPageMetadata(snapshot)
    let originId = FileID(metadata.originFileId)
    let record = try getFileRecord(fileId: originId)
    let content = try resolveFileContent(fileId: originId)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let imageURL = directory.appendingPathComponent("page")
      .appendingPathExtension(DocumentImageNaming.fileExtension(forMediaType: record.mediaType))
    try content.write(to: imageURL)
    let analysis = try analyzer?.analyze(imageURL: imageURL) ?? metadata.analysis
    let recognized = try recognizer.recognize(imageURL: imageURL)
    let outcome = try driver.withDatabase { database in
      try database.transaction { db in
        let current = try requirePendingDocumentOCRNote(noteId, in: db)
        guard current == snapshot else {
          throw NoteServiceError.conflict("page changed while OCR was running; no content was replaced")
        }
        let previous = try ftsPayload(noteId: noteId, in: db)
        let existing = try noteSearchText(noteId, in: db) ?? ""
        let newSearch = existing.isEmpty ? recognized : recognized + "\n\n" + existing
        let source = try noteTitleSource(noteId: noteId, in: db)
        let title = source == .derived ? (noteTitle(from: recognized) ?? current.title) : current.title
        let now = NoteStoreClock.system.now()
        var completed = metadata
        completed.ocrState = "complete"
        completed.pendingBodySHA256 = nil
        completed.analysis = analysis
        var object = try JSONValue(parsing: current.metaJSON ?? "{}").asObject ?? [:]
        object["documentPage"] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(completed))
        try db.execute(
          """
          UPDATE notes
          SET search_text = ?, title = ?, updated_at = ?,
            updated_by = (SELECT owner_user_id FROM notebooks WHERE notebook_id = notes.notebook_id),
            meta_json = jsonb(?)
          WHERE note_id = ?
          """,
          bindings: [
            .text(newSearch), .optionalText(title), .text(now),
            .text(try JSONValue.object(object).encodedString()), .id(noteId)
          ]
        )
        try db.execute(
          "UPDATE notebooks SET updated_at = ?, updated_by = owner_user_id WHERE notebook_id = ?",
          bindings: [.text(now), .id(current.notebookId)]
        )
        try refreshFTS(noteId: noteId, previous: previous, in: db)
        let note = try requireNote(noteId, in: db)
        let dispatches = try enqueueAutoActions(
          for: makeAutoActionEvent(
            trigger: .noteUpdated,
            notebookId: note.notebookId,
            noteId: note.noteId,
            noteBodyMarkdown: noteRetrievalText(bodyMarkdown: current.bodyMarkdown, searchText: newSearch),
            originatingActionId: nil
          ),
          in: db
        )
        return (note, dispatches)
      }
    }
    dispatchQueuedAutoActions(outcome.1)
    publishChange(NoteChangeEvent(kind: NoteChangeEventKind.noteUpdated, notebookId: outcome.0.notebookId))
    return outcome.0
  }
}

extension NoteService {
  static func importedPageMetadata(_ note: Note) throws -> ImportedPageMetadata {
    guard let json = note.metaJSON,
          let value = try JSONValue(parsing: json).asObject?["documentPage"] else {
      throw NoteServiceError.invalidInput("note is not an imported document page")
    }
    return try JSONDecoder().decode(ImportedPageMetadata.self, from: Data(value.encodedString().utf8))
  }

  /// The notebook import lock allows completing pending OCR; an explicit note
  /// lock still prevents it. Reachability and ownership checks are mandatory.
  func requirePendingDocumentOCRNote(_ noteId: NoteID, in db: SQLiteDatabase) throws -> Note {
    let note = try requireNote(noteId, in: db)
    try requireNotebookOwnership(note.notebookId, subject: noteId.rawValue, in: db)
    guard !note.readOnly else { throw NoteServiceError.invalidInput("page is read-only") }
    let metadata = try Self.importedPageMetadata(note)
    guard metadata.ocrState == "pending" else {
      throw NoteServiceError.conflict("page OCR is already complete")
    }
    let origin = try db.query(
      "SELECT file_id FROM note_files WHERE note_id = ? AND file_id = ? AND role = ?",
      bindings: [.id(noteId), .text(metadata.originFileId), .text(NoteFileRole.sourcePageImage.rawValue)]
    )
    guard origin.count == 1 else { throw NoteServiceError.conflict("page original is missing") }
    return note
  }
}
