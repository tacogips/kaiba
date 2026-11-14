import Foundation
@testable import AppCore
import XCTest

private struct FixedConverter: DocumentConverting {
  var markdown: String
  var sourceFormat: String

  func convert(inputPath: String) throws -> DocumentConversionResult {
    DocumentConversionResult(markdown: markdown, sourceFormat: sourceFormat)
  }
}

private struct StubImageExtractor: DocumentImageExtracting {
  var result: DocumentImageExtractionResult

  func extractImages(fileURL: URL, sourceFormat: String) throws -> DocumentImageExtractionResult {
    result
  }
}

private struct FailingImageExtractor: DocumentImageExtracting {
  func extractImages(fileURL: URL, sourceFormat: String) throws -> DocumentImageExtractionResult {
    throw DocumentConversionError.failed("image extraction exploded")
  }
}

private func stubImage(
  page: Int,
  kind: DocumentPageImageKind,
  byte: UInt8
) -> DocumentExtractedImage {
  DocumentExtractedImage(
    pageNumber: page,
    kind: kind,
    data: Data([byte, byte, byte, byte]),
    mediaType: "image/png",
    suggestedFilename: "page-\(page)-\(kind.rawValue).png"
  )
}

final class DocumentImportImageAttachmentTests: NoteTestCase {
  func testAttachesPageCapturesAndEmbeddedImagesToTheMappedNotes() throws {
    let service = try makeService()
    let sourcePath = try writeTemporarySource(named: "mapped.pdf")
    defer { try? FileManager.default.removeItem(atPath: sourcePath) }

    let extraction = DocumentImageExtractionResult(
      images: [
        stubImage(page: 1, kind: .pageCapture, byte: 1),
        stubImage(page: 1, kind: .embedded, byte: 2),
        stubImage(page: 2, kind: .pageCapture, byte: 3),
        stubImage(page: 2, kind: .embedded, byte: 4),
        stubImage(page: 2, kind: .embedded, byte: 5)
      ],
      pageTexts: ["Alpha chapter body", "Beta chapter body"]
    )
    let result = try service.importDocument(
      at: sourcePath,
      converter: FixedConverter(
        markdown: "# Alpha\nfirst body\n\n# Beta\nsecond body",
        sourceFormat: "pdf"
      ),
      imageExtractor: StubImageExtractor(result: extraction)
    )

    XCTAssertNil(result.imageWarning)
    XCTAssertEqual(result.imageFiles.count, 5)
    XCTAssertEqual(result.notes.map(\.title), ["Alpha", "Beta"])

    let alpha = try service.listFiles(noteId: result.notes[0].noteId)
    XCTAssertEqual(alpha.map(\.role), [.embedded, .sourcePageImage])
    XCTAssertEqual(alpha.map(\.position), [0, 1])
    XCTAssertEqual(alpha.first(where: { $0.role == .sourcePageImage })?.file.byteSize, 4)

    let beta = try service.listFiles(noteId: result.notes[1].noteId)
    XCTAssertEqual(beta.map(\.role), [.embedded, .embedded, .sourcePageImage])
    // Page captures carry the page number; embedded images count per note.
    XCTAssertEqual(beta.map(\.position), [0, 1, 2])
    XCTAssertEqual(beta.map(\.file.mediaType), ["image/png", "image/png", "image/png"])
    XCTAssertEqual(
      beta.first(where: { $0.role == .sourcePageImage })?.file.originalFilename,
      "page-2-page-capture.png"
    )
  }

  func testImagesForPagesWithoutTextFallBackToTheFirstNote() throws {
    let service = try makeService()
    let sourcePath = try writeTemporarySource(named: "untexted.epub")
    defer { try? FileManager.default.removeItem(atPath: sourcePath) }

    let result = try service.importDocument(
      at: sourcePath,
      converter: FixedConverter(
        markdown: "# Alpha\nfirst body\n\n# Beta\nsecond body",
        sourceFormat: "epub"
      ),
      imageExtractor: StubImageExtractor(result: DocumentImageExtractionResult(
        images: [stubImage(page: 7, kind: .embedded, byte: 9)],
        pageTexts: []
      ))
    )

    XCTAssertEqual(try service.listFiles(noteId: result.notes[0].noteId).count, 1)
    XCTAssertEqual(try service.listFiles(noteId: result.notes[1].noteId).count, 0)
  }

  func testFailedExtractionWarnsWithoutFailingTheImport() throws {
    let service = try makeService()
    let sourcePath = try writeTemporarySource(named: "broken.pdf")
    defer { try? FileManager.default.removeItem(atPath: sourcePath) }

    let result = try service.importDocument(
      at: sourcePath,
      converter: FixedConverter(markdown: "# Alpha\nbody", sourceFormat: "pdf"),
      imageExtractor: FailingImageExtractor()
    )

    XCTAssertEqual(result.notes.count, 1)
    XCTAssertTrue(result.imageFiles.isEmpty)
    let warning = try XCTUnwrap(result.imageWarning)
    XCTAssertTrue(warning.contains("image extraction exploded"), warning)
    XCTAssertTrue(try service.listFiles(noteId: result.notes[0].noteId).isEmpty)
    XCTAssertEqual(try service.listFiles(notebookId: result.notebook.notebookId).count, 1)
  }

  func testImportsRealPDFPageCaptures() throws {
    let service = try makeService()
    let result = try service.importDocument(
      at: try fixtureURL(named: "sample.pdf").path,
      converter: FixedConverter(
        markdown: "# Fixture Document\nconverted body",
        sourceFormat: "pdf"
      )
    )

    XCTAssertNil(result.imageWarning)
    let attachments = try service.listFiles(noteId: result.notes[0].noteId)
    XCTAssertEqual(attachments.map(\.role), [.sourcePageImage, .sourcePageImage])
    XCTAssertEqual(attachments.map(\.position), [1, 2])
    XCTAssertEqual(attachments.map(\.file.mediaType), ["image/jpeg", "image/jpeg"])
    XCTAssertEqual(
      attachments.map(\.file.originalFilename),
      ["page-0001.jpg", "page-0002.jpg"]
    )
    XCTAssertTrue(attachments.allSatisfy { $0.file.byteSize > 0 })
    XCTAssertEqual(
      try service.resolveFileContent(fileId: attachments[0].file.fileId).count,
      Int(attachments[0].file.byteSize)
    )
  }

  func testImportsRealEPUBEmbeddedImageOntoItsChapterNote() throws {
    let service = try makeService()
    let url = try fixtureURL(named: "sample.epub")
    let result = try service.importDocument(
      at: url.path,
      converter: FixedConverter(
        markdown: """
        # Fixture Book

        # Chapter One
        first body

        # Chapter Two
        second body
        """,
        sourceFormat: "epub"
      )
    )

    XCTAssertNil(result.imageWarning)
    XCTAssertEqual(result.notes.map(\.title), ["Fixture Book", "Chapter One", "Chapter Two"])
    // The only image sits in the ch001 spine document, which is the page the
    // "Chapter One" note starts on.
    XCTAssertTrue(try service.listFiles(noteId: result.notes[0].noteId).isEmpty)
    let chapterOne = try service.listFiles(noteId: result.notes[1].noteId)
    XCTAssertEqual(chapterOne.count, 1)
    XCTAssertEqual(chapterOne[0].role, .embedded)
    XCTAssertEqual(chapterOne[0].position, 0)
    XCTAssertEqual(chapterOne[0].file.mediaType, "image/png")
    XCTAssertEqual(chapterOne[0].file.originalFilename, "page-0002-image-1.png")
    XCTAssertGreaterThan(chapterOne[0].file.byteSize, 0)
    XCTAssertTrue(try service.listFiles(noteId: result.notes[2].noteId).isEmpty)
  }

  private func writeTemporarySource(named name: String) throws -> String {
    let directory = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath,
      isDirectory: true
    ).appendingPathComponent("tmp/AppCoreTests", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
    try Data("placeholder source bytes".utf8).write(to: url)
    return url.path
  }
}
