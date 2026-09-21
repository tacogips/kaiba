import Foundation
@testable import AppCore
import XCTest
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

final class DocumentVisualProviderTests: XCTestCase {
  func testStructuredAnalysisPreservesDocumentLayoutAndTitle() throws {
    let analyzer = StructuredDocumentPageAnalyzer(converter: VisualResponse(markdown: """
    ```json
    {"isDocument":true,"language":"ja","writingMode":"vertical","binding":"right","title":"Book title"}
    ```
    """))
    let result = try analyzer.analyze(imageURL: URL(fileURLWithPath: "/page.png"))
    XCTAssertEqual(result, DocumentPageAnalysis(isDocument: true, language: "ja", writingMode: .vertical, binding: .right, title: "Book title"))
    let photo = StructuredDocumentPageAnalyzer(converter: VisualResponse(markdown: """
    {"isDocument":false,"language":null,"writingMode":"unknown","binding":"unknown","title":null}
    """))
    XCTAssertEqual(try photo.analyze(imageURL: URL(fileURLWithPath: "/photo.png")).isDocument, false)
  }

  func testInvalidAnalysisAndRegionsFailInsteadOfGuessing() {
    let analyzer = StructuredDocumentPageAnalyzer(converter: VisualResponse(markdown: "Some prose {\"isDocument\":true}"))
    XCTAssertThrowsError(try analyzer.analyze(imageURL: URL(fileURLWithPath: "/page.png")))
    for response in ["[{\"x\":-0.1,\"y\":0,\"width\":0.5,\"height\":1}]", "[{\"x\":0.8,\"y\":0,\"width\":0.5,\"height\":1}]", "[{\"x\":0,\"y\":0,\"width\":0,\"height\":1}]"] {
      let locator = StructuredDocumentFigureLocator(converter: VisualResponse(markdown: response))
      XCTAssertThrowsError(try locator.regions(imageURL: URL(fileURLWithPath: "/page.png")))
    }
    XCTAssertFalse(DocumentFigureRegion(x: .nan, y: 0, width: 1, height: 1).isValid)
  }

  func testIndependentGatewayConfigurationsRoundTrip() throws {
    let settings = KaibaImportConfiguration(
      ocrEngine: .vision, maximumOCRPages: .first(2),
      analysis: KaibaOCRConfiguration(vendor: "codex", model: "analysis-model"),
      figures: KaibaOCRConfiguration(vendor: "anthropic", model: "figure-model")
    )
    XCTAssertEqual(try JSONDecoder().decode(KaibaImportConfiguration.self, from: JSONEncoder().encode(settings)), settings)
    XCTAssertNotNil(settings.makePageAnalyzer(environment: [:]))
    XCTAssertNotNil(settings.makeFigureExtractor(environment: [:]))
    XCTAssertNil(KaibaImportConfiguration().makePageAnalyzer())
    XCTAssertNil(KaibaImportConfiguration().makeFigureExtractor())
  }

  func testCropUsesTopLeftCoordinatesAndPreservesActualPixels() throws {
    #if canImport(ImageIO)
    let raw = Data((0..<16).flatMap { index -> [UInt8] in index < 8 ? [255, 0, 0, 255] : [0, 0, 255, 255] })
    let provider = try XCTUnwrap(CGDataProvider(data: raw as CFData))
    let image = try XCTUnwrap(CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: source) }
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let extractor = CroppingDocumentPageFigureExtractor(locator: FixedRegions(regions: [.init(x: 0, y: 0, width: 1, height: 0.5)]), paddingFraction: 0)
    let figure = try XCTUnwrap(extractor.extractFigures(imageURL: source, pageNumber: 7).first)
    XCTAssertEqual(figure.pageNumber, 7)
    XCTAssertEqual(figure.kind, .embedded)
    let decoded = try XCTUnwrap(CGImageSourceCreateWithData(figure.data as CFData, nil))
    let crop = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
    XCTAssertEqual(crop.width, 4)
    XCTAssertEqual(crop.height, 2)
    let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let pixel = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    XCTAssertGreaterThan(pixel[0], 240)
    XCTAssertLessThan(pixel[2], 10)
    #else
    throw XCTSkip("ImageIO is unavailable")
    #endif
  }
}

private struct VisualResponse: DocumentConverting {
  var markdown: String
  func convert(inputPath: String) throws -> DocumentConversionResult { DocumentConversionResult(markdown: markdown, sourceFormat: "png") }
}

private struct FixedRegions: DocumentFigureLocating {
  var regions: [DocumentFigureRegion]
  func regions(imageURL: URL) throws -> [DocumentFigureRegion] { regions }
}
