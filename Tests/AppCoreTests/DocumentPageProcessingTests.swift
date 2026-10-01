import Foundation
@testable import AppCore
import XCTest

final class DocumentPageProcessingTests: XCTestCase {
  func testDownloadedPDFWithLocalOCR() throws {
    guard let path = ProcessInfo.processInfo.environment["KAIBA_TEST_IMPORT_PDF"] else {
      throw XCTSkip("Set KAIBA_TEST_IMPORT_PDF to run local OCR on a real PDF")
    }
    let pages = try DocumentPageProcessor(recognizer: VisionDocumentPageRecognizer())
      .prepare(fileURL: URL(fileURLWithPath: path), maximumOCRPages: 2)
    XCTAssertGreaterThan(pages.count, 2)
    XCTAssertTrue(pages.prefix(2).allSatisfy { !($0.markdown ?? "").isEmpty })
    XCTAssertTrue(pages.dropFirst(2).allSatisfy { $0.markdown == nil })
    XCTAssertTrue(pages.allSatisfy { !$0.origin.data.isEmpty })
    print("Real PDF verification: \(pages.count) page originals, 2 OCR pages, \(pages.count - 2) pending")
  }

  func testLimitPreservesEveryOriginAndLeavesLaterPagesPending() throws {
    let processor = DocumentPageProcessor(recognizer: PageRecognizer(), analyzer: PageAnalyzer(), extractor: PageExtractor())
    let pages = try processor.prepare(fileURL: URL(fileURLWithPath: "/fixture.pdf"), maximumOCRPages: 1)
    XCTAssertEqual(pages.map(\.pageNumber), [1, 2, 3])
    XCTAssertEqual(pages.map(\.markdown), ["page 1", nil, nil])
    XCTAssertEqual(pages[0].analysis.title, "Extracted title")
    XCTAssertEqual(pages[0].analysis.binding, .right)
    XCTAssertEqual(pages[0].analysis.writingMode, .vertical)
    XCTAssertEqual(pages[1].analysis, DocumentPageAnalysis())
    XCTAssertEqual(pages[1].origin.data, Data("2".utf8))
  }

  func testEmbeddedExtractionResultsAreIgnoredAndProvidersDoNotChangeOrigins() throws {
    let url = URL(fileURLWithPath: "/fixture.pdf")
    let limitedRecognizer = CountingRecognizer()
    let limitedAnalyzer = CountingAnalyzer()
    let extractor = PageExtractor()
    let pending = try DocumentPageProcessor(
      recognizer: limitedRecognizer, analyzer: limitedAnalyzer, extractor: extractor
    ).prepare(fileURL: url, maximumOCRPages: 0)
    XCTAssertEqual(limitedRecognizer.calls, 0)
    XCTAssertEqual(limitedAnalyzer.calls, 0)
    XCTAssertEqual(pending.map(\.origin.data), [Data("1".utf8), Data("2".utf8), Data("3".utf8)])
    XCTAssertTrue(pending.allSatisfy { $0.markdown == nil })

    let recognizer = CountingRecognizer()
    let analyzer = CountingAnalyzer()
    let processed = try DocumentPageProcessor(recognizer: recognizer, analyzer: analyzer, extractor: extractor)
      .prepare(fileURL: url, maximumOCRPages: nil)
    XCTAssertEqual(recognizer.calls, 3)
    XCTAssertEqual(analyzer.calls, 3)
    XCTAssertEqual(processed.map(\.origin.data), pending.map(\.origin.data))
  }

  func testAllAndZeroLimits() throws {
    let processor = DocumentPageProcessor(recognizer: PageRecognizer(), extractor: PageExtractor())
    let url = URL(fileURLWithPath: "/fixture.pdf")
    XCTAssertEqual(try processor.prepare(fileURL: url, maximumOCRPages: nil).map(\.markdown), ["page 1", "page 2", "page 3"])
    XCTAssertTrue(try processor.prepare(fileURL: url, maximumOCRPages: 0).allSatisfy { $0.markdown == nil })
    XCTAssertThrowsError(try processor.prepare(fileURL: url, maximumOCRPages: -1))
  }

  func testMissingCaptureFailsInsteadOfRenumberingPages() {
    let processor = DocumentPageProcessor(recognizer: PageRecognizer(), extractor: PageExtractor(missingPage: true))
    XCTAssertThrowsError(try processor.prepare(fileURL: URL(fileURLWithPath: "/fixture.pdf")))
  }

  func testStandaloneImageIsItsOwnOrigin() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
    try Data("image".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let pages = try DocumentPageProcessor(recognizer: PageRecognizer()).prepare(fileURL: url)
    XCTAssertEqual(pages.count, 1)
    XCTAssertEqual(pages[0].markdown, "page image")
    XCTAssertEqual(pages[0].origin.data, Data("image".utf8))
  }
}

private struct PageRecognizer: DocumentPageRecognizing {
  func recognize(imageURL: URL) throws -> String {
    "page " + (try String(contentsOf: imageURL, encoding: .utf8))
  }
}

private struct PageAnalyzer: DocumentPageAnalyzing {
  func analyze(imageURL: URL) throws -> DocumentPageAnalysis {
    DocumentPageAnalysis(isDocument: true, language: "ja", writingMode: .vertical, binding: .right, title: "Extracted title")
  }
}

private struct PageExtractor: DocumentImageExtracting {
  var missingPage = false

  func extractImages(fileURL: URL, sourceFormat: String) throws -> DocumentImageExtractionResult {
    var images = (1...3).filter { !missingPage || $0 != 2 }.map {
      DocumentExtractedImage(pageNumber: $0, kind: .pageCapture, data: Data(String($0).utf8),
                             mediaType: "image/png", suggestedFilename: "\($0).png")
    }
    images.append(DocumentExtractedImage(pageNumber: 2, kind: .embedded, data: Data("figure".utf8),
                                         mediaType: "image/png", suggestedFilename: "figure.png"))
    return DocumentImageExtractionResult(images: images, pageTexts: ["", "", ""])
  }
}

private final class CountingRecognizer: DocumentPageRecognizing, @unchecked Sendable {
  private(set) var calls = 0
  func recognize(imageURL: URL) throws -> String {
    calls += 1
    return "recognized"
  }
}

private final class CountingAnalyzer: DocumentPageAnalyzing, @unchecked Sendable {
  private(set) var calls = 0
  func analyze(imageURL: URL) throws -> DocumentPageAnalysis {
    calls += 1
    return DocumentPageAnalysis()
  }
}
