import Foundation

public struct DocumentImportResult: Equatable, Sendable {
  public var notebook: Notebook
  public var notes: [Note]
  public var sourceFile: NotebookFileAttachment

  public init(notebook: Notebook, notes: [Note], sourceFile: NotebookFileAttachment) {
    self.notebook = notebook
    self.notes = notes
    self.sourceFile = sourceFile
  }
}

public extension NoteService {
  /// Imports a source document as an imported-material notebook: converts it
  /// to markdown, splits into per-section notes (`MarkdownHeadingSplitter`),
  /// and attaches the original file with the `source-document` role. See
  /// `design-docs/specs/document-import.md`.
  @discardableResult
  func importDocument(
    at path: String,
    title: String? = nil,
    kindTagName: String = NoteStoreSchema.importedMaterialNotebookKindTag,
    converter: DocumentConverting
  ) throws -> DocumentImportResult {
    let expandedPath = (path as NSString).expandingTildeInPath
    guard FileManager.default.fileExists(atPath: expandedPath) else {
      throw NoteServiceError.invalidInput("import source not found: \(expandedPath)")
    }
    let conversion = try converter.convert(inputPath: expandedPath)
    let pages = MarkdownHeadingSplitter.split(markdown: conversion.markdown)
    guard !pages.isEmpty else {
      throw NoteServiceError.invalidInput(
        "conversion produced no markdown content: \(expandedPath)"
      )
    }
    let originalFilename = (expandedPath as NSString).lastPathComponent
    let notebookTitle = title
      ?? pages.first.flatMap { NoteTitleDerivation.title(from: $0.bodyMarkdown) }
      ?? (originalFilename as NSString).deletingPathExtension
    let metaJSON = try Self.importMetaJSON(
      originalFilename: originalFilename,
      format: conversion.sourceFormat,
      toolName: conversion.toolName,
      toolVersion: conversion.toolVersion
    )
    let ingest = try createNotebookWithNotes(
      title: notebookTitle,
      kindTagName: kindTagName,
      metaJSON: metaJSON,
      pages: pages
    )
    let attachment = try attachNotebookFile(
      notebookId: ingest.notebook.notebookId,
      fileURL: URL(fileURLWithPath: expandedPath),
      role: .sourceDocument,
      mediaType: Self.mediaType(forSourceFormat: conversion.sourceFormat),
      originalFilename: originalFilename
    )
    return DocumentImportResult(
      notebook: ingest.notebook,
      notes: ingest.notes,
      sourceFile: attachment
    )
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
