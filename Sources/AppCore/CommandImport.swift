import Foundation

extension AppCommand {
  func runImport(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let title = try cursor.extractOption("--title")
    let kindTag = try cursor.extractOption("--kind-tag")
      ?? NoteStoreSchema.importedMaterialNotebookKindTag
    let anydocPathOverride = try cursor.extractOption("--anydoc-path")
    let output = try cursor.extractOutputMode()
    guard let path = cursor.next() else {
      throw Error.invalidUsage("import requires <file-path>")
    }
    try cursor.finish()

    let converter = AnydocCLIDocumentConverter(
      binaryPath: anydocPathOverride ?? context.configuration.importSettings?.anydocPath,
      environment: environment
    )
    let service = try makeService(context)
    let result: DocumentImportResult
    do {
      result = try service.importDocument(
        at: path,
        title: title,
        kindTagName: kindTag,
        converter: converter
      )
    } catch let error as DocumentConversionError {
      throw Error.invalidUsage(Self.describeConversionError(error))
    }

    switch output {
    case .json:
      return try renderJSON([
        "notebookId": result.notebook.notebookId,
        "title": result.notebook.title,
        "noteCount": result.notes.count,
        "sourceFileId": result.sourceFile.file.fileId
      ] as [String: Any])
    case .text:
      return """
      Imported \(result.notebook.title)
      notebook \(result.notebook.notebookId)  (\(result.notes.count) notes)
      source file \(result.sourceFile.file.fileId)  \
      (\(result.sourceFile.file.mediaType), \(result.sourceFile.file.byteSize) bytes)
      """
    }
  }

  static func describeConversionError(_ error: DocumentConversionError) -> String {
    switch error {
    case .toolNotFound(let path):
      return "anydoc-swift not found (tried: \(path)). Install it "
        + "(brew install tacogips/tap/anydoc-swift) or set import.anydocPath "
        + "in config.json / pass --anydoc-path."
    case .unsupported(let kind, let message):
      return "document not convertible (\(kind)): \(message)"
    case .failed(let message):
      return "conversion failed: \(message)"
    }
  }
}
