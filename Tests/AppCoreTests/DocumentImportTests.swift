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

final class DocumentConverterRoutingTests: NoteTestCase {
  func testPDFAndEPUBFixturesConvertInProcessWithAnydocKit() throws {
    let fixtureRoot = try XCTUnwrap(Bundle.module.resourceURL)
      .appendingPathComponent("Fixtures", isDirectory: true)
    let converter = ImportDocumentConverter()

    let pdf = try converter.convert(inputPath: fixtureRoot.appendingPathComponent("sample.pdf").path)
    let epub = try converter.convert(inputPath: fixtureRoot.appendingPathComponent("sample.epub").path)

    XCTAssertEqual(pdf.sourceFormat, "pdf")
    XCTAssertTrue(pdf.markdown.contains("Fixture Document"))
    XCTAssertEqual(pdf.toolName, "AnydocKit")
    XCTAssertEqual(pdf.toolVersion, "0.1.6")
    XCTAssertEqual(epub.sourceFormat, "epub")
    XCTAssertFalse(epub.markdown.isEmpty)
    XCTAssertEqual(epub.toolName, "AnydocKit")
  }

  func testImageUsesConfiguredLunaCodexOCRAgent() throws {
    let scriptURL = try makeExecutableScript("""
    #!/bin/sh
    if [ "$1" != "client" ] || [ "$2" != "--vendor" ] || [ "$3" != "codex" ] || \
       [ "$4" != "--model" ] || [ "$5" != "gpt-5.6-luna" ] || \
       [ "$6" != "--prompt" ] || [ "$7" != "-" ] || \
       [ "$8" != "--api-key-environment" ] || [ "$9" != "CODEX_TOKEN" ] || \
       [ "${10}" != "--" ] || [ "${11}" != "--image" ] || [ -z "${12}" ]; then
      echo 'unexpected OCR arguments' >&2
      exit 9
    fi
    /bin/cat >/dev/null
    printf '%s\n' '{"id":3,"jsonrpc":"2.0","result":{"stopReason":"end_turn","_meta":{"agentGateway":{"resultText":"# Scanned title\\nOCR body"}}}}'
    """)
    defer { try? FileManager.default.removeItem(at: scriptURL) }
    let imageURL = try writeFixture(
      named: "mock.png",
      data: Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    )
    defer { try? FileManager.default.removeItem(at: imageURL) }
    let converter = ImportDocumentConverter(
      ocr: AgentGatewayImageOCRConverter(
        commandPath: scriptURL.path,
        vendor: "codex",
        model: "gpt-5.6-luna",
        apiKeyEnvironment: "CODEX_TOKEN",
        environment: [:]
      )
    )

    let result = try converter.convert(inputPath: imageURL.path)

    XCTAssertEqual(result.sourceFormat, "png")
    XCTAssertEqual(result.markdown, "# Scanned title\nOCR body")
    XCTAssertEqual(result.toolName, "agent-gateway")
  }

  func testImageWithoutOCRConfigurationFailsBeforeAnydoc() throws {
    let imageURL = try writeFixture(named: "mock.jpg", data: Data([0xff, 0xd8, 0xff]))
    defer { try? FileManager.default.removeItem(at: imageURL) }
    let converter = ImportDocumentConverter()

    XCTAssertThrowsError(try converter.convert(inputPath: imageURL.path)) { error in
      guard case .failed(let message) = error as? DocumentConversionError else {
        return XCTFail("expected DocumentConversionError.failed")
      }
      XCTAssertTrue(message.contains("import.ocr.vendor"))
    }
  }

  func testUnsupportedCLIVendorFailsClearly() throws {
    let converter = AgentGatewayImageOCRConverter(
      commandPath: "/not-used",
      vendor: "claude-code",
      model: "claude-test",
      environment: [:]
    )

    XCTAssertThrowsError(try converter.convert(inputPath: "/tmp/mock.png")) { error in
      guard case .failed(let message) = error as? DocumentConversionError else {
        return XCTFail("expected DocumentConversionError.failed")
      }
      XCTAssertTrue(message.contains("not image-capable"))
    }
  }

  private func writeFixture(named name: String, data: Data) throws -> URL {
    let directory = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath,
      isDirectory: true
    ).appendingPathComponent("tmp/AppCoreTests", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
    try data.write(to: url)
    return url
  }

  private func makeExecutableScript(_ script: String) throws -> URL {
    let url = try writeFixture(named: "mock-tool.sh", data: Data(script.utf8))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: url.path
    )
    return url
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
    XCTAssertTrue(result.notebook.readOnly)
    XCTAssertTrue(result.notes.allSatisfy { !$0.readOnly })
    XCTAssertTrue(result.notebook.tags.contains {
      $0.tag.name == NoteStoreSchema.importedMaterialNotebookKindTag
    })

    let attachments = try service.listFiles(notebookId: result.notebook.notebookId)
    XCTAssertEqual(attachments.count, 1)
    XCTAssertEqual(attachments[0].role, .sourceDocument)
    XCTAssertEqual(attachments[0].file.mediaType, "application/pdf")
    XCTAssertEqual(attachments[0].file.originalFilename, "sample.pdf")

    let notebook = try service.getNotebook(result.notebook.notebookId)
    XCTAssertTrue(notebook.readOnly)
    let meta = try XCTUnwrap(fetchNotebookMetaJSON(
      service: service,
      notebookId: result.notebook.notebookId
    ))
    XCTAssertTrue(meta.contains("\"originalFilename\":\"sample.pdf\""))
    XCTAssertTrue(meta.contains("\"format\":\"pdf\""))
    XCTAssertTrue(meta.contains("\"toolVersion\":\"0.1.2\""))
  }

  func testImportedNotebookCanBecomeWritableWithoutUnlockingEachNote() throws {
    let service = try makeService()
    let sourcePath = try writeTemporarySource(named: "writable.pdf", contents: "fake-pdf-bytes")
    defer { try? FileManager.default.removeItem(atPath: sourcePath) }

    let result = try service.importDocument(
      at: sourcePath,
      converter: StubConverter(result: DocumentConversionResult(
        markdown: "# Imported\nOriginal body",
        sourceFormat: "pdf"
      ))
    )
    let note = try XCTUnwrap(result.notes.first)

    XCTAssertThrowsError(
      try service.updateNoteBody(noteId: note.noteId, bodyMarkdown: "Blocked while imported")
    )

    let writable = try service.setNotebookReadOnly(
      notebookId: result.notebook.notebookId,
      readOnly: false
    )
    let updated = try service.updateNoteBody(
      noteId: note.noteId,
      bodyMarkdown: "User-approved edit"
    )

    XCTAssertFalse(writable.readOnly)
    XCTAssertEqual(updated.bodyMarkdown, "User-approved edit")
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
    notebookId: NotebookID
  ) throws -> String? {
    try service.driver.withDatabase { database in
      try database.query(
        "SELECT json(meta_json) AS meta FROM notebooks WHERE notebook_id = ?",
        bindings: [.id(notebookId)]
      ).first?["meta"]
    }
  }
}
