import Foundation

public struct ImportedPageMetadata: Codable, Equatable, Sendable {
  public var pageNumber: Int
  public var ocrState: String
  public var analysis: DocumentPageAnalysis
  public var originFileId: String
  public var pendingBodySHA256: String?
}

private struct StagedImportFile {
  var id: FileID
  var stored: StoredNoteFile
  var mediaType: String
  var filename: String
  var pageIndex: Int?
  var role: NoteFileRole
  var position: Int

  var record: FileRecord {
    storedFileRecord(fileId: id, stored: stored, mediaType: mediaType, originalFilename: filename)
  }
}

public extension NoteService {
  /// Stores one note for every physical page, including pages whose OCR is pending.
  /// All database writes are atomic; files staged before a failed commit are removed.
  func importDocumentPages(
    at path: String,
    title: String? = nil,
    kindTagName: String = NoteStoreSchema.importedMaterialNotebookKindTag,
    processor: DocumentPageProcessor,
    maximumOCRPages: Int? = 3,
    enqueueAutoActions: Bool = true
  ) throws -> DocumentImportResult {
    let sourceURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    let pages = try processor.prepare(fileURL: sourceURL, maximumOCRPages: maximumOCRPages)
    let notebookTitle = title ?? pages.compactMap(\.analysis.title).first
      ?? pages.first?.markdown.flatMap { NoteTitleDerivation.title(from: $0) }
      ?? sourceURL.deletingPathExtension().lastPathComponent
    let store = LocalNoteFileStore(noteRoot: noteRootPath())
    var staged: [StagedImportFile] = []
    var committed = false
    defer {
      if !committed {
        for file in staged { try? store.delete(record: file.record) }
      }
    }
    let sourceId = FileID.generate()
    staged.append(StagedImportFile(
      id: sourceId, stored: try store.store(fileURL: sourceURL, fileId: sourceId),
      mediaType: Self.mediaType(forSourceFormat: sourceURL.pathExtension.lowercased()),
      filename: sourceURL.lastPathComponent, pageIndex: nil, role: .related, position: 0
    ))
    var drafts: [NotePageDraft] = []
    for (index, page) in pages.enumerated() {
      let originId = FileID.generate()
      staged.append(StagedImportFile(
        id: originId, stored: try store.store(data: page.origin.data, fileId: originId),
        mediaType: page.origin.mediaType, filename: page.origin.suggestedFilename, pageIndex: index,
        role: .sourcePageImage, position: page.pageNumber
      ))
      let metadata = ImportedPageMetadata(
        pageNumber: page.pageNumber, ocrState: page.markdown == nil ? "pending" : "complete",
        analysis: page.analysis, originFileId: originId.rawValue, pendingBodySHA256: nil
      )
      let pageJSON = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(metadata))
      drafts.append(NotePageDraft(
        bodyMarkdown: "", readOnly: false,
        metaJSON: try JSONValue.object(["documentPage": pageJSON]).encodedString(), noteNumber: page.pageNumber,
        searchText: page.markdown ?? ""
      ))
    }
    let metaJSON = try Self.importMetaJSON(
      originalFilename: sourceURL.lastPathComponent, format: sourceURL.pathExtension.lowercased(),
      toolName: "kaiba-page-import", toolVersion: nil
    )
    let outcome = try driver.withDatabase { database in
      try database.transaction { db in
        try requireEnabledActingUser(in: db)
        let inserted = try insertNotebookWithNotes(
          title: notebookTitle, kindTagName: kindTagName, metaJSON: metaJSON, pages: drafts,
          notebookReadOnly: true, provenance: .system, assignedBy: "kaiba-page-import",
          originatingActionId: nil, enqueueAutoActions: enqueueAutoActions, in: db
        )
        var images: [NoteFileAttachment] = []
        var source: NotebookFileAttachment?
        for file in staged {
          let record = try insertFileRecord(
            fileId: file.id, stored: file.stored, mediaType: file.mediaType, originalFilename: file.filename, in: db
          )
          if let pageIndex = file.pageIndex {
            let noteId = inserted.ingestResult.notes[pageIndex].noteId
            try db.execute(
              "INSERT INTO note_files (note_id, file_id, role, position) VALUES (?, ?, ?, ?)",
              bindings: [.id(noteId), .id(file.id), .text(file.role.rawValue), .int(Int64(file.position))]
            )
            images.append(NoteFileAttachment(noteId: noteId, file: record, role: file.role, position: file.position))
          } else {
            let notebookId = inserted.ingestResult.notebook.notebookId
            try db.execute(
              "INSERT INTO notebook_files (notebook_id, file_id, role) VALUES (?, ?, ?)",
              bindings: [.id(notebookId), .id(file.id), .text(NotebookFileRole.sourceDocument.rawValue)]
            )
            source = NotebookFileAttachment(notebookId: notebookId, file: record, role: .sourceDocument)
          }
        }
        guard let source else { throw NoteServiceError.invalidInput("import has no source document") }
        return (DocumentImportResult(
          notebook: inserted.ingestResult.notebook, notes: inserted.ingestResult.notes,
          sourceFile: source, imageFiles: images
        ), inserted.dispatches)
      }
    }
    committed = true
    dispatchQueuedAutoActions(outcome.1)
    publishChange(NoteChangeEvent(kind: NoteChangeEventKind.notebookCreated, notebookId: outcome.0.notebook.notebookId))
    return outcome.0
  }
}
