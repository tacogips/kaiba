import Foundation

public struct DocumentImportResult: Equatable, Sendable {
  public var notebook: Notebook
  public var notes: [Note]
  public var sourceFile: NotebookFileAttachment
  /// Page captures and embedded images attached to the imported notes.
  public var imageFiles: [NoteFileAttachment]
  /// Set when image extraction failed. The import itself still succeeded.
  public var imageWarning: String?

  public init(
    notebook: Notebook,
    notes: [Note],
    sourceFile: NotebookFileAttachment,
    imageFiles: [NoteFileAttachment] = [],
    imageWarning: String? = nil
  ) {
    self.notebook = notebook
    self.notes = notes
    self.sourceFile = sourceFile
    self.imageFiles = imageFiles
    self.imageWarning = imageWarning
  }
}

public extension NoteService {
  /// Imports a source document as an imported-material notebook: converts it
  /// to markdown, splits into per-section notes (`MarkdownHeadingSplitter`),
  /// attaches the original file with the `source-document` role, and attaches
  /// the page captures and embedded images the source carries to the notes they
  /// belong to. See `design-docs/specs/document-import.md`.
  @discardableResult
  func importDocument(
    at path: String,
    title: String? = nil,
    kindTagName: String = NoteStoreSchema.importedMaterialNotebookKindTag,
    converter: DocumentConverting,
    imageExtractor: any DocumentImageExtracting = DocumentImageExtractor()
  ) throws -> DocumentImportResult {
    let expandedPath = (path as NSString).expandingTildeInPath
    guard FileManager.default.fileExists(atPath: expandedPath) else {
      throw NoteServiceError.invalidInput("import source not found: \(expandedPath)")
    }
    let conversion = try converter.convert(inputPath: expandedPath)
    let importedPages = MarkdownHeadingSplitter.split(markdown: conversion.markdown)
    guard !importedPages.isEmpty else {
      throw NoteServiceError.invalidInput(
        "conversion produced no markdown content: \(expandedPath)"
      )
    }
    let originalFilename = (expandedPath as NSString).lastPathComponent
    let notebookTitle = title
      ?? importedPages.first.flatMap { NoteTitleDerivation.title(from: $0.bodyMarkdown) }
      ?? (originalFilename as NSString).deletingPathExtension
    let metaJSON = try Self.importMetaJSON(
      originalFilename: originalFilename,
      format: conversion.sourceFormat,
      toolName: conversion.toolName,
      toolVersion: conversion.toolVersion
    )
    // The notebook owns the imported material's access mode. Its notes stay
    // independently writable so changing the notebook to writable actually
    // restores edits without erasing deliberate per-note locks.
    let pages = importedPages.map {
      NotePageDraft(
        bodyMarkdown: $0.bodyMarkdown,
        readOnly: false,
        tags: $0.tags,
        metaJSON: $0.metaJSON,
        noteNumber: $0.noteNumber
      )
    }
    let ingest = try createNotebookWithNotes(
      title: notebookTitle,
      kindTagName: kindTagName,
      metaJSON: metaJSON,
      pages: pages,
      notebookReadOnly: true
    )
    let attachment = try storeNotebookFileAttachment(
      notebookId: ingest.notebook.notebookId,
      fileURL: URL(fileURLWithPath: expandedPath),
      role: .sourceDocument,
      mediaType: Self.mediaType(forSourceFormat: conversion.sourceFormat),
      originalFilename: originalFilename,
      requiresWritableNotebook: false
    )
    // Images are additive: a document whose rasters cannot be read still
    // imports as markdown, with the reason reported back to the caller.
    var imageFiles: [NoteFileAttachment] = []
    var imageWarning: String?
    do {
      let extraction = try imageExtractor.extractImages(
        fileURL: URL(fileURLWithPath: expandedPath),
        sourceFormat: conversion.sourceFormat
      )
      imageFiles = try attachExtractedImages(extraction, to: ingest.notes)
    } catch {
      imageWarning = "image extraction skipped: \(error)"
    }
    return DocumentImportResult(
      notebook: ingest.notebook,
      notes: ingest.notes,
      sourceFile: attachment,
      imageFiles: imageFiles,
      imageWarning: imageWarning
    )
  }

  /// Attaches every extracted image to the note that owns its page. Page
  /// captures keep the page number as their position so a note's captures stay
  /// in reading order; embedded images are numbered per note in emission order.
  @discardableResult
  internal func attachExtractedImages(
    _ extraction: DocumentImageExtractionResult,
    to notes: [Note]
  ) throws -> [NoteFileAttachment] {
    guard !notes.isEmpty, !extraction.images.isEmpty else {
      return []
    }
    let noteIndexByPage = DocumentPageNoteMapper.noteIndexByPage(
      pageTexts: extraction.pageTexts,
      noteTitles: notes.map(\.title)
    )
    var embeddedPositionByNote: [Int: Int] = [:]
    var attachments: [NoteFileAttachment] = []
    for image in extraction.images {
      let pageIndex = image.pageNumber - 1
      // Without per-page text there is nothing to map against, so the whole
      // document belongs to its first note.
      let noteIndex = noteIndexByPage.indices.contains(pageIndex)
        ? min(noteIndexByPage[pageIndex], notes.count - 1)
        : 0
      let noteId = notes[noteIndex].noteId
      let position: Int
      let role: NoteFileRole
      switch image.kind {
      case .pageCapture:
        role = .sourcePageImage
        position = image.pageNumber
      case .embedded:
        role = .embedded
        position = embeddedPositionByNote[noteIndex, default: 0]
        embeddedPositionByNote[noteIndex] = position + 1
      }
      // Import setup finishes before the notebook receives its default
      // read-only mode, so extracted source images remain part of the import.
      attachments.append(try storeNoteFileAttachment(
        noteId: noteId,
        data: image.data,
        role: role,
        mediaType: image.mediaType,
        originalFilename: image.suggestedFilename,
        position: position,
        requiresWritableNote: false
      ))
    }
    return attachments
  }

  internal static func importMetaJSON(
    originalFilename: String,
    format: String,
    toolName: String = AnydocKitDocumentConverter.toolName,
    toolVersion: String?
  ) throws -> String {
    var source: [String: Any] = [
      "originalFilename": originalFilename,
      "format": format,
      "tool": toolName,
      "importedAt": NoteStoreClock.system.now()
    ]
    source["toolVersion"] = toolVersion
    let data = try JSONSerialization.data(
      withJSONObject: ["source": source],
      options: [.sortedKeys]
    )
    guard let json = String(data: data, encoding: .utf8) else {
      throw NoteServiceError.invalidInput("import meta JSON is not UTF-8")
    }
    return json
  }

  internal static func mediaType(forSourceFormat format: String) -> String {
    switch format {
    case "pdf": return "application/pdf"
    case "doc": return "application/msword"
    case "docx":
      return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    case "ppt": return "application/vnd.ms-powerpoint"
    case "pptx":
      return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
    case "excel": return "application/vnd.ms-excel"
    case "odt": return "application/vnd.oasis.opendocument.text"
    case "ods": return "application/vnd.oasis.opendocument.spreadsheet"
    case "odp": return "application/vnd.oasis.opendocument.presentation"
    case "rtf": return "application/rtf"
    case "epub": return "application/epub+zip"
    case "csv": return "text/csv"
    case "gif": return "image/gif"
    case "jpeg", "jpg": return "image/jpeg"
    case "png": return "image/png"
    case "webp": return "image/webp"
    default: return "application/octet-stream"
    }
  }
}
