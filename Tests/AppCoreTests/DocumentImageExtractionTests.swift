import Foundation
@testable import AppCore
import XCTest

final class PDFDocumentImageExtractionTests: XCTestCase {
  func testCapturesEveryPageOfTheSampleFixture() throws {
    let result = try PDFDocumentImageExtractor().extractImages(
      fileURL: try fixtureURL(named: "sample.pdf"),
      sourceFormat: "pdf"
    )

    let captures = result.images.filter { $0.kind == .pageCapture }
    XCTAssertEqual(captures.count, 2)
    XCTAssertEqual(captures.map(\.pageNumber), [1, 2])
    XCTAssertEqual(captures.map(\.suggestedFilename), ["page-0001.jpg", "page-0002.jpg"])
    for capture in captures {
      XCTAssertEqual(capture.mediaType, "image/jpeg")
      XCTAssertGreaterThan(capture.data.count, 0)
      XCTAssertEqual([UInt8](capture.data.prefix(3)), [0xFF, 0xD8, 0xFF], "expected JPEG bytes")
    }
  }

  /// The fixture only embeds two 1x1 pixels (an image and its soft mask), which
  /// are exactly the page furniture the size filter is meant to drop.
  func testSkipsEmbeddedImagesBelowTheSizeFloor() throws {
    let result = try PDFDocumentImageExtractor().extractImages(
      fileURL: try fixtureURL(named: "sample.pdf"),
      sourceFormat: "pdf"
    )
    XCTAssertTrue(result.images.allSatisfy { $0.kind == .pageCapture })
  }

  func testReportsPerPageTextForNoteMapping() throws {
    let result = try PDFDocumentImageExtractor().extractImages(
      fileURL: try fixtureURL(named: "sample.pdf"),
      sourceFormat: "pdf"
    )
    XCTAssertEqual(result.pageTexts.count, 2)
    XCTAssertTrue(result.pageTexts[0].contains("Fixture Document"))
    XCTAssertTrue(result.pageTexts[1].contains("Endnote"))
  }

  func testUnreadablePDFThrows() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("\(UUID().uuidString).pdf")
    try Data("not a pdf".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    XCTAssertThrowsError(
      try PDFDocumentImageExtractor().extractImages(fileURL: url, sourceFormat: "pdf")
    )
  }
}

final class EPUBDocumentImageExtractionTests: XCTestCase {
  func testExtractsSpineImageWithSpinePositionAsPageNumber() throws {
    let url = try fixtureURL(named: "sample.epub")
    let result = try EPUBDocumentImageExtractor().extractImages(fileURL: url, sourceFormat: "epub")

    XCTAssertEqual(result.images.count, 1)
    let image = try XCTUnwrap(result.images.first)
    // The image lives in ch001.xhtml, the second spine item.
    XCTAssertEqual(image.pageNumber, 2)
    XCTAssertEqual(image.kind, .embedded)
    XCTAssertEqual(image.mediaType, "image/png")
    XCTAssertEqual(image.suggestedFilename, "page-0002-image-1.png")
    XCTAssertEqual(image.data, try MinimalZipArchive(fileURL: url).data(forPath: "EPUB/media/file0.png"))
    XCTAssertEqual([UInt8](image.data.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "expected PNG bytes")
  }

  func testReportsPerSpineDocumentText() throws {
    let result = try EPUBDocumentImageExtractor().extractImages(
      fileURL: try fixtureURL(named: "sample.epub"),
      sourceFormat: "epub"
    )
    XCTAssertEqual(result.pageTexts.count, 3)
    XCTAssertTrue(result.pageTexts[0].contains("Fixture Book"))
    XCTAssertTrue(result.pageTexts[1].contains("Chapter One"))
    XCTAssertTrue(result.pageTexts[2].contains("Chapter Two"))
    XCTAssertFalse(result.pageTexts[1].contains("<h1>"))
  }

  func testResolvesReferencesRelativeToTheirDocument() {
    let resolve = EPUBDocumentImageExtractor.resolvePath
    XCTAssertEqual(resolve("../media/a.png", "EPUB/text/ch1.xhtml"), "EPUB/media/a.png")
    XCTAssertEqual(resolve("./a.png", "EPUB/text/ch1.xhtml"), "EPUB/text/a.png")
    XCTAssertEqual(resolve("a.png", "EPUB/text/ch1.xhtml"), "EPUB/text/a.png")
    XCTAssertEqual(resolve("/EPUB/a.png", "EPUB/text/ch1.xhtml"), "EPUB/a.png")
    XCTAssertEqual(resolve("my%20image.png", "text/ch1.xhtml"), "text/my image.png")
    XCTAssertEqual(resolve("a.png#frag", "ch1.xhtml"), "a.png")
    XCTAssertNil(resolve("https://example.com/a.png", "ch1.xhtml"))
    XCTAssertNil(resolve("data:image/png;base64,AAA", "ch1.xhtml"))
    XCTAssertNil(resolve("", "ch1.xhtml"))
  }

  func testScannerFindsImgAndSVGImageInDocumentOrder() {
    let markup = """
    <p><img src="one.png" alt="x" /></p>
    <svg><image xlink:href="two.jpg" /></svg>
    <svg><image href='three.gif'/></svg>
    <img class="late" src='four.webp'>
    """
    XCTAssertEqual(
      HTMLImageReferenceScanner.references(in: markup),
      ["one.png", "two.jpg", "three.gif", "four.webp"]
    )
  }

  func testPlainTextStripsTagsAndDecodesEntities() {
    let text = HTMLTextExtraction.plainText(
      "<style>h1 { color: red }</style><h1>Caf&#233; &amp; Bar</h1><p>body&nbsp;text</p>"
    )
    XCTAssertTrue(text.contains("Café & Bar"))
    XCTAssertTrue(text.contains("body text"))
    XCTAssertFalse(text.contains("color"))
  }

  func testUnsupportedImageTypesAreSkipped() {
    XCTAssertEqual(EPUBDocumentImageExtractor.mediaType(forPath: "a/b.JPEG"), "image/jpeg")
    XCTAssertEqual(EPUBDocumentImageExtractor.mediaType(forPath: "a/b.svg"), "image/svg+xml")
    XCTAssertNil(EPUBDocumentImageExtractor.mediaType(forPath: "a/b.css"))
  }
}

final class DocumentImageExtractorRoutingTests: XCTestCase {
  func testRoutesByDeclaredFormatAndFallsBackToTheExtension() {
    XCTAssertEqual(
      DocumentImageExtractor.normalizedFormat(
        sourceFormat: "PDF",
        fileURL: URL(fileURLWithPath: "/tmp/a.epub")
      ),
      "pdf"
    )
    XCTAssertEqual(
      DocumentImageExtractor.normalizedFormat(
        sourceFormat: "",
        fileURL: URL(fileURLWithPath: "/tmp/a.EPUB")
      ),
      "epub"
    )
  }

  func testUnsupportedFormatsExtractNothing() throws {
    let result = try DocumentImageExtractor().extractImages(
      fileURL: URL(fileURLWithPath: "/tmp/nonexistent.docx"),
      sourceFormat: "docx"
    )
    XCTAssertEqual(result, .empty)
  }
}

extension XCTestCase {
  func fixtureURL(named name: String) throws -> URL {
    try XCTUnwrap(Bundle.module.resourceURL)
      .appendingPathComponent("Fixtures", isDirectory: true)
      .appendingPathComponent(name)
  }
}
