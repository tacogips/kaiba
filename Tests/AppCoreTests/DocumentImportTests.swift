import Foundation
@testable import AppCore
import XCTest

final class MarkdownHeadingSplitterTests: NoteTestCase {
  func testSplitsAtH1WithPreamblePage() {
    let markdown = """
    Cover text before the first chapter.

    # Chapter One
    Body one.

    ## Section 1.1
    Deep body.

    # Chapter Two
    Body two.
    """
    let pages = MarkdownHeadingSplitter.split(markdown: markdown)
    XCTAssertEqual(pages.count, 3)
    XCTAssertEqual(pages.map(\.noteNumber), [1, 2, 3])
    XCTAssertTrue(pages[0].bodyMarkdown.hasPrefix("Cover text"))
    XCTAssertTrue(pages[1].bodyMarkdown.hasPrefix("# Chapter One"))
    XCTAssertTrue(pages[1].bodyMarkdown.contains("## Section 1.1"))
    XCTAssertTrue(pages[2].bodyMarkdown.hasPrefix("# Chapter Two"))
  }

  func testFallsBackToH2WhenNoH1() {
    let markdown = """
    ## Alpha
    a

    ## Beta
    b
    """
    let pages = MarkdownHeadingSplitter.split(markdown: markdown)
    XCTAssertEqual(pages.count, 2)
    XCTAssertTrue(pages[0].bodyMarkdown.hasPrefix("## Alpha"))
    XCTAssertTrue(pages[1].bodyMarkdown.hasPrefix("## Beta"))
  }

  func testSingleNoteWhenNoHeadings() {
    let pages = MarkdownHeadingSplitter.split(markdown: "just text\n\nmore text")
    XCTAssertEqual(pages.count, 1)
    XCTAssertEqual(pages[0].bodyMarkdown, "just text\n\nmore text")
  }

  func testEmptyMarkdownYieldsNoPages() {
    XCTAssertTrue(MarkdownHeadingSplitter.split(markdown: "  \n\n").isEmpty)
  }

  func testIgnoresHeadingsInsideFencedCodeBlocks() {
    let markdown = """
    # Real Chapter
    intro

    ```markdown
    # not a heading
    ## also not
    ```

    # Second Chapter
    body
    """
    let pages = MarkdownHeadingSplitter.split(markdown: markdown)
    XCTAssertEqual(pages.count, 2)
    XCTAssertTrue(pages[0].bodyMarkdown.contains("# not a heading"))
  }

  func testOversizedSectionSplitsAtNextHeadingLevel() {
    let bigBody = String(repeating: "word ", count: 90_000) // ~450 KiB
    let markdown = """
    # Big Chapter

    ## Part A
    \(bigBody)

    ## Part B
    small
    """
    let pages = MarkdownHeadingSplitter.split(markdown: markdown)
    XCTAssertTrue(pages.count >= 2)
    XCTAssertTrue(pages.contains { $0.bodyMarkdown.hasPrefix("## Part B") })
  }
}

final class AnydocEnvelopeParsingTests: NoteTestCase {
  private func data(_ json: String) -> Data {
    Data(json.utf8)
  }

  func testParsesOkEnvelope() throws {
    let result = try AnydocCLIDocumentConverter.parseEnvelope(data(
      """
      {"schemaVersion":1,"status":"ok","tool":{"version":"0.1.2","anydoc":"0.1.6"},
       "input":{"source":"file","path":"/tmp/x.pdf","byteCount":10},
       "format":"pdf","markdown":"# Title\\nBody","markdownByteCount":12}
      """
    ))
    XCTAssertEqual(result.markdown, "# Title\nBody")
    XCTAssertEqual(result.sourceFormat, "pdf")
    XCTAssertEqual(result.toolVersion, "0.1.2")
  }

  func testMapsUnsupportedErrorKind() {
    XCTAssertThrowsError(try AnydocCLIDocumentConverter.parseEnvelope(data(
      """
      {"status":"error","error":{"kind":"unsupported","message":"OCR is required"}}
      """
    ))) { error in
      XCTAssertEqual(
        error as? DocumentConversionError,
        .unsupported(kind: "unsupported", message: "OCR is required")
      )
    }
  }

  func testMapsOtherErrorKindsToFailed() {
    XCTAssertThrowsError(try AnydocCLIDocumentConverter.parseEnvelope(data(
      """
      {"status":"error","error":{"kind":"malformed","message":"broken xref"}}
      """
    ))) { error in
      XCTAssertEqual(error as? DocumentConversionError, .failed("malformed: broken xref"))
    }
  }

  func testRejectsInvalidJSON() {
    XCTAssertThrowsError(try AnydocCLIDocumentConverter.parseEnvelope(data("not json"))) { error in
      guard case .failed = error as? DocumentConversionError else {
        return XCTFail("expected .failed, got \(error)")
      }
    }
  }

  func testMissingBinaryPathThrowsToolNotFound() {
    let converter = AnydocCLIDocumentConverter(
      binaryPath: "/nonexistent/anydoc-swift",
      environment: [:]
    )
    XCTAssertThrowsError(try converter.convert(inputPath: "/tmp/doc.pdf")) { error in
      XCTAssertEqual(
        error as? DocumentConversionError,
        .toolNotFound("/nonexistent/anydoc-swift")
      )
    }
  }
}

private struct StubConverter: DocumentConverting {
  var result: DocumentConversionResult

  func convert(inputPath: String) throws -> DocumentConversionResult {
    result
  }
}

final class DocumentImportServiceTests: NoteTestCase {
  func testImportDocumentCreatesNotebookNotesAndSourceAttachment() throws {
    let service = try makeService()
    let sourcePath = try writeTemporarySource(named: "sample.pdf", contents: "fake-pdf-bytes")
    defer { try? FileManager.default.removeItem(atPath: sourcePath) }

    let markdown = """
    # My Book
    Intro paragraph.

    # Chapter Two
    Body.
    """
    let result = try service.importDocument(
      at: sourcePath,
      converter: StubConverter(result: DocumentConversionResult(
        markdown: markdown,
        sourceFormat: "pdf",
        toolVersion: "0.1.2"
      ))
    )

    XCTAssertEqual(result.notebook.title, "My Book")
    XCTAssertEqual(result.notes.count, 2)
    XCTAssertEqual(result.notes.map(\.noteNumber), [1, 2])
    XCTAssertTrue(result.notebook.tags.contains {
      $0.tag.name == NoteStoreSchema.importedMaterialNotebookKindTag
    })

    let attachments = try service.listFiles(notebookId: result.notebook.notebookId)
    XCTAssertEqual(attachments.count, 1)
    XCTAssertEqual(attachments[0].role, .sourceDocument)
    XCTAssertEqual(attachments[0].file.mediaType, "application/pdf")
    XCTAssertEqual(attachments[0].file.originalFilename, "sample.pdf")

    let notebook = try service.getNotebook(result.notebook.notebookId)
    XCTAssertNotNil(notebook)
    let meta = try XCTUnwrap(fetchNotebookMetaJSON(
      service: service,
      notebookId: result.notebook.notebookId
    ))
    XCTAssertTrue(meta.contains("\"originalFilename\":\"sample.pdf\""))
    XCTAssertTrue(meta.contains("\"format\":\"pdf\""))
    XCTAssertTrue(meta.contains("\"toolVersion\":\"0.1.2\""))
  }

  func testImportDocumentExplicitTitleWins() throws {
    let service = try makeService()
    let sourcePath = try writeTemporarySource(named: "raw.docx", contents: "x")
    defer { try? FileManager.default.removeItem(atPath: sourcePath) }

    let result = try service.importDocument(
      at: sourcePath,
      title: "Given Title",
      converter: StubConverter(result: DocumentConversionResult(
        markdown: "no headings here",
        sourceFormat: "docx"
      ))
    )
    XCTAssertEqual(result.notebook.title, "Given Title")
    XCTAssertEqual(result.notes.count, 1)
  }

  func testImportDocumentRejectsEmptyConversion() throws {
    let service = try makeService()
    let sourcePath = try writeTemporarySource(named: "empty.pdf", contents: "x")
    defer { try? FileManager.default.removeItem(atPath: sourcePath) }

    XCTAssertThrowsError(try service.importDocument(
      at: sourcePath,
      converter: StubConverter(result: DocumentConversionResult(
        markdown: "   \n",
        sourceFormat: "pdf"
      ))
    ))
  }

  func testImportDocumentRejectsMissingSource() throws {
    let service = try makeService()
    XCTAssertThrowsError(try service.importDocument(
      at: "/nonexistent/never.pdf",
      converter: StubConverter(result: DocumentConversionResult(
        markdown: "# X",
        sourceFormat: "pdf"
      ))
    ))
  }

  private func writeTemporarySource(named name: String, contents: String) throws -> String {
    let directory = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath,
      isDirectory: true
    )
    .appendingPathComponent("tmp/AppCoreTests", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try Data(contents.utf8).write(to: url)
    return url.path
  }

  private func fetchNotebookMetaJSON(
    service: NoteService,
    notebookId: String
  ) throws -> String? {
    try service.driver.withDatabase { database in
      try database.query(
        "SELECT json(meta_json) AS meta FROM notebooks WHERE notebook_id = ?",
        bindings: [.text(notebookId)]
      ).first?["meta"]
    }
  }
}
