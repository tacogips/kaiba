import Foundation

public extension NoteService {
  /// Completes deferred OCR from the stored original. Recognition runs outside
  /// the transaction; a concurrent edit, OCR completion, or ownership change
  /// causes the final compare-and-write to fail without replacing any content.
  @discardableResult
  func recognizeDocumentPage(
    noteId: NoteID,
    recognizer: any DocumentPageRecognizing,
    analyzer: (any DocumentPageAnalyzing)? = nil,
    figureExtractor: (any DocumentPageFigureExtracting)? = nil
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
    let markdown = try recognizer.recognize(imageURL: imageURL)
    let figures = try figureExtractor?.extractFigures(imageURL: imageURL, pageNumber: metadata.pageNumber) ?? []
    let store = LocalNoteFileStore(noteRoot: noteRootPath())
    var staged: [FileRecord] = []
    var committed = false
    defer {
      if !committed { for file in staged { try? store.delete(record: file) } }
    }
    for figure in figures {
      guard figure.pageNumber == metadata.pageNumber, figure.kind == .embedded else {
        throw NoteServiceError.invalidInput("figure extractor returned an image for a different page")
      }
      let id = FileID.generate()
      let stored = try store.store(data: figure.data, fileId: id)
      staged.append(storedFileRecord(fileId: id, stored: stored, mediaType: figure.mediaType, originalFilename: figure.suggestedFilename))
    }
    let figureMarkdown = staged.enumerated().map { "\n\n![Figure \($0.offset + 1)](/files/\($0.element.fileId.rawValue))" }.joined()
    let outcome = try driver.withDatabase { database in
      try database.transaction { db in
        let current = try requirePendingDocumentOCRNote(noteId, in: db)
        guard current == snapshot else {
          throw NoteServiceError.conflict("page changed while OCR was running; no content was replaced")
        }
        let lastPosition = try db.query(
          "SELECT MAX(position) AS position FROM note_files WHERE note_id = ? AND role = ?",
          bindings: [.id(noteId), .text(NoteFileRole.embedded.rawValue)]
        ).first?["position"].flatMap(Int.init) ?? 0
        for (index, file) in staged.enumerated() {
          let stored = StoredNoteFile(
            locator: NoteFileLocator(storageKind: .local, localPath: file.localPath), byteSize: file.byteSize, sha256: file.sha256
          )
          _ = try insertFileRecord(fileId: file.fileId, stored: stored, mediaType: file.mediaType, originalFilename: file.originalFilename, in: db)
          try db.execute(
            "INSERT INTO note_files (note_id, file_id, role, position) VALUES (?, ?, ?, ?)",
            bindings: [.id(noteId), .id(file.fileId), .text(NoteFileRole.embedded.rawValue), .int(Int64(lastPosition + index + 1))]
          )
        }
        let updated = try updateNoteBodyInDatabase(
          noteId: noteId, bodyMarkdown: markdown + snapshot.bodyMarkdown + figureMarkdown,
          provenance: .system, originatingActionId: nil, completingPendingDocumentOCR: true, in: db
        )
        var completed = metadata
        completed.ocrState = "complete"
        completed.pendingBodySHA256 = nil
        completed.analysis = analysis
        var object = try JSONValue(parsing: current.metaJSON ?? "{}").asObject ?? [:]
        object["documentPage"] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(completed))
        try db.execute(
          "UPDATE notes SET meta_json = jsonb(?) WHERE note_id = ?",
          bindings: [.text(try JSONValue.object(object).encodedString()), .id(noteId)]
        )
        return (try requireNote(noteId, in: db), updated.dispatches)
      }
    }
    committed = true
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
    guard metadata.pendingBodySHA256 == sha256Hex(Data(note.bodyMarkdown.utf8)) else {
      throw NoteServiceError.conflict("pending page has been edited; OCR would replace user content")
    }
    let origin = try db.query(
      "SELECT file_id FROM note_files WHERE note_id = ? AND file_id = ? AND role = ?",
      bindings: [.id(noteId), .text(metadata.originFileId), .text(NoteFileRole.sourcePageImage.rawValue)]
    )
    guard origin.count == 1 else { throw NoteServiceError.conflict("page original is missing") }
    return note
  }
}
