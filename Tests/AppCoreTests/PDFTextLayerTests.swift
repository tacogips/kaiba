import Foundation
@testable import AppCore
import XCTest
#if canImport(PDFKit)
import AppKit
import PDFKit
#endif

final class PDFTextLayerTests: NoteTestCase {
  func testTextPDFNeverInvokesOCREvenWithZeroBudget() throws {
    let source = try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("Fixtures/sample.pdf")
    let result = try makeService().importDocumentPages(
      at: source.path, processor: DocumentPageProcessor(recognizer: UnexpectedOCR()), maximumOCRPages: 0
    )
    XCTAssertEqual(result.notes.count, 2)
    for note in result.notes {
      let metadata = try NoteService.importedPageMetadata(note)
      XCTAssertEqual(metadata.ocrState, "complete")
      XCTAssertEqual(metadata.textSource, "pdf-text")
      XCTAssertEqual(note.bodyMarkdown, "")
    }
  }

  func testMixedPDFUsesTextLayerThenOCRBudgetOnlyForScannedPages() throws {
    let source = try makeMixedPDFTextFixture()
    defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
    let recognizer = ScannedPageOCR()
    let pages = try DocumentPageProcessor(recognizer: recognizer).prepare(fileURL: source, maximumOCRPages: 1)
    XCTAssertEqual(pages.count, 2)
    XCTAssertEqual(pages.map(\.textSource), ["pdf-text", "ocr"])
    XCTAssertTrue(try XCTUnwrap(pages[0].markdown).contains("Fixture Document"))
    XCTAssertEqual(pages[1].markdown, "Scanned page\n\nPlain search text")
    XCTAssertEqual(recognizer.calls, 1)
  }
}

func makeMixedPDFTextFixture() throws -> URL {
  #if canImport(PDFKit)
  let source = try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("Fixtures/sample.pdf")
  let original = try Data(contentsOf: source)
  let document = try XCTUnwrap(PDFDocument(data: original))
  let raster = try PDFDocumentImageExtractor.renderPage(pdfData: original, pageNumber: 2)
  let image = try XCTUnwrap(NSImage(data: raster.data))
  document.removePage(at: 1)
  document.insert(try XCTUnwrap(PDFPage(image: image)), at: 1)
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let result = directory.appendingPathComponent("mixed.pdf")
  guard document.write(to: result) else { throw DocumentConversionError.failed("test PDF creation failed") }
  return result
  #else
  throw XCTSkip("PDFKit is unavailable")
  #endif
}

private struct UnexpectedOCR: DocumentPageRecognizing {
  func recognize(imageURL: URL) throws -> String {
    XCTFail("A native text layer must not invoke OCR")
    throw DocumentConversionError.failed("Unexpected OCR")
  }
}

private final class ScannedPageOCR: DocumentPageRecognizing, @unchecked Sendable {
  var calls = 0
  func recognize(imageURL: URL) throws -> String {
    calls += 1
    return "Scanned page\n\nPlain search text"
  }
}

extension PDFTextLayerTests {
  func testOCROnlyModeIgnoresNativeTextAndHonorsZeroBudget() throws {
    let source = try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("Fixtures/sample.pdf")
    let recognizer = ScannedPageOCR()
    let processor = DocumentPageProcessor(recognizer: recognizer, textExtractionMode: .ocrOnly)
    let pending = try processor.prepare(fileURL: source, maximumOCRPages: 0)
    XCTAssertTrue(pending.allSatisfy { $0.markdown == nil })
    XCTAssertEqual(recognizer.calls, 0)
    let recognized = try processor.prepare(fileURL: source, maximumOCRPages: nil)
    XCTAssertEqual(recognizer.calls, 2)
    XCTAssertTrue(recognized.allSatisfy { $0.textSource == "ocr" && $0.markdown == "Scanned page\n\nPlain search text" })
  }

  func testStoreDefaultAndExplicitOverrideHaveDefinedPrecedence() throws {
    let service = try makeService()
    XCTAssertEqual(try service.resolvePDFTextMode(), .preferPDFText)
    _ = try service.setAppSetting(key: "web", valueJSON: #"{"pdfTextMode":"ocr-only"}"#)
    XCTAssertEqual(try service.resolvePDFTextMode(configuration: .preferPDFText), .ocrOnly)
    XCTAssertEqual(try service.resolvePDFTextMode(override: "prefer-pdf-text"), .preferPDFText)
    XCTAssertThrowsError(try service.resolvePDFTextMode(override: "unknown"))
  }
}
