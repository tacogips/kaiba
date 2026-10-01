import Foundation

extension AppCommand {
  func runImport(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let title = try cursor.extractOption("--title")
    let kindTag = try cursor.extractOption("--kind-tag")
      ?? NoteStoreSchema.importedMaterialNotebookKindTag
    let limitOption = try cursor.extractOption("--max-ocr-pages")
    let engineOption = try cursor.extractOption("--ocr-engine")
    let output = try cursor.extractOutputMode()
    guard let path = cursor.next() else {
      throw Error.invalidUsage("import requires <file-path>")
    }
    try cursor.finish()

    let importSettings = context.configuration.importSettings
    let ocr = importSettings?.ocr.map {
      AgentGatewayImageOCRConverter(
        commandPath: $0.commandPath,
        vendor: $0.vendor,
        model: $0.model,
        apiKeyEnvironment: $0.apiKeyEnvironmentVariable,
        environment: environment
      )
    }
    let converter = ImportDocumentConverter(
      ocr: ocr
    )
    let service = try makeService(context)
    let result: DocumentImportResult
    do {
      let format = URL(fileURLWithPath: path).pathExtension.lowercased()
      if ["pdf", "png", "jpg", "jpeg", "gif", "webp"].contains(format) {
        let limit = try limitOption.map(DocumentOCRPageLimit.parse)
          ?? importSettings?.maximumOCRPages ?? .first(3)
        let engine = try engineOption.map { value in
          guard let engine = DocumentOCREngine(rawValue: value) else {
            throw Error.invalidUsage("--ocr-engine must be vision, agent-gateway, or google-document-ai")
          }
          return engine
        } ?? importSettings?.resolvedOCREngine ?? .vision
        var pageSettings = importSettings ?? KaibaImportConfiguration()
        pageSettings.ocrEngine = engine
        let recognizer = try pageSettings.makePageRecognizer(environment: environment)
        result = try service.importDocumentPages(
          at: path, title: title, kindTagName: kindTag,
          processor: DocumentPageProcessor(
            recognizer: recognizer, analyzer: importSettings?.makePageAnalyzer(environment: environment)
          ), maximumOCRPages: limit.maximum
        )
      } else {
        result = try service.importDocument(
          at: path, title: title, kindTagName: kindTag, converter: converter
        )
      }
    } catch let error as DocumentConversionError {
      throw Error.invalidUsage(Self.describeConversionError(error))
    }

    let taggingWarnings = try tagImportedPages(
      context: context, service: service, notebookId: result.notebook.notebookId,
      noteIds: result.notes.map(\.noteId)
    )
    switch output {
    case .json:
      return try renderJSON([
        "notebookId": .id(result.notebook.notebookId),
        "title": .string(result.notebook.title),
        "noteCount": .integer(Int64(result.notes.count)),
        "sourceFileId": .id(result.sourceFile.file.fileId),
        "taggingWarnings": .array(taggingWarnings.map(JSONValue.string))
      ])
    case .text:
      var lines = """
      Imported \(result.notebook.title)
      notebook \(result.notebook.notebookId)  (\(result.notes.count) notes)
      source file \(result.sourceFile.file.fileId)  \
      (\(result.sourceFile.file.mediaType), \(result.sourceFile.file.byteSize) bytes)
      """
      if let warning = result.imageWarning {
        lines += "\nwarning: \(warning)"
      }
      for warning in taggingWarnings { lines += "\nwarning: \(warning)" }
      return lines
    }
  }

  func runDocumentPageOCR(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let output = try cursor.extractOutputMode()
    guard let value = cursor.next() else { throw Error.invalidUsage("page-ocr requires <note-id>") }
    try cursor.finish()
    let settings = context.configuration.importSettings
    let recognizer = try (settings ?? KaibaImportConfiguration()).makePageRecognizer(environment: environment)
    let service = try makeService(context)
    let note = try service.recognizeDocumentPage(
      noteId: NoteID(value), recognizer: recognizer,
      analyzer: settings?.makePageAnalyzer(environment: environment)
    )
    let warnings = try tagImportedPages(
      context: context, service: service, notebookId: note.notebookId, noteIds: [note.noteId]
    )
    switch output {
    case .json: return try renderJSON([
      "noteId": .id(note.noteId), "ocrState": .string("complete"),
      "taggingWarnings": .array(warnings.map(JSONValue.string))
    ])
    case .text:
      return (["OCR completed for page \(note.noteNumber) (\(note.noteId))"]
        + warnings.map { "warning: \($0)" }).joined(separator: "\n")
    }
  }

  private func tagImportedPages(
    context: CommandContext, service: NoteService, notebookId: NotebookID, noteIds: [NoteID]
  ) throws -> [String] {
    guard context.configuration.ai?.autoTagEnabled == true else { return [] }
    let tagging = DocumentAutoTagging(
      service: service, configuration: context.configuration.ai,
      invoker: AgentInvokerFactory.makeInvoker(configuration: context.configuration.ai, environment: environment)
    )
    return try runBlocking { await tagging.tag(notebookId: notebookId, noteIds: noteIds) }
  }

  static func describeConversionError(_ error: DocumentConversionError) -> String {
    switch error {
    case .unsupported(let kind, let message):
      return "document not convertible (\(kind)): \(message)"
    case .failed(let message):
      return "conversion failed: \(message)"
    }
  }
}
