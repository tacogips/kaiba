import Foundation
@testable import AppCore
import XCTest
#if canImport(Vision)
import CoreGraphics
import ImageIO

final class DocumentFigureTextBoundsTests: XCTestCase {
  func testRetainsWholeIntersectedCaptionWithoutAbsorbingAdjacentProse() {
    let page = CGRect(x: 0, y: 0, width: 1000, height: 1500)
    let crop = CGRect(x: 250, y: 250, width: 600, height: 400)
    let caption = CGRect(x: 220, y: 600, width: 650, height: 20)
    let prose = CGRect(x: 200, y: 670, width: 700, height: 25)
    let result = DocumentFigureTextBounds.refine(crop, textLines: [caption, prose], page: page)
    XCTAssertTrue(result.contains(caption))
    XCTAssertFalse(result.intersects(prose))
    XCTAssertEqual(result.minY, crop.minY)
    XCTAssertEqual(result.maxY, crop.maxY)
  }

  func testExpansionDoesNotCascadeAndClampsToPage() {
    let page = CGRect(x: 0, y: 0, width: 100, height: 200)
    let crop = CGRect(x: 5, y: 5, width: 30, height: 30)
    let crossing = CGRect(x: 0, y: 25, width: 40, height: 15)
    let adjacent = CGRect(x: 0, y: 40, width: 90, height: 15)
    let result = DocumentFigureTextBounds.refine(crop, textLines: [crossing, adjacent], page: page)
    XCTAssertEqual(result.minX, 0)
    XCTAssertEqual(result.maxX, 42)
    XCTAssertEqual(result.maxY, 42)
  }

  func testSavedPDFPageCaptionRefinement() throws {
    guard let path = ProcessInfo.processInfo.environment["KAIBA_TEST_FIGURE_PAGE"] else {
      throw XCTSkip("Set KAIBA_TEST_FIGURE_PAGE to the saved page-8.jpg fixture")
    }
    let url = URL(fileURLWithPath: path)
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    let fullImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let image = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: max(fullImage.width, fullImage.height)
    ] as CFDictionary))
    let page = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    // Reproduce the clipped caption box observed in the live Claude output.
    let initial = CGRect(x: page.width * 0.235, y: page.height * 0.164,
                         width: page.width * 0.64, height: page.height * 0.2475)
    let originalPixels = Array(try XCTUnwrap(image.dataProvider?.data) as Data)
    let lines = try DocumentFigureTextBounds.detect(in: image)
    XCTAssertEqual(Array(try XCTUnwrap(image.dataProvider?.data) as Data), originalPixels)
    let captionLines = lines.filter { $0.minY > page.height * 0.35 && $0.maxY < page.height * 0.40 }
    XCTAssertFalse(captionLines.isEmpty)
    let refined = DocumentFigureTextBounds.refine(initial, textLines: lines, page: page)
    for line in captionLines { XCTAssertTrue(refined.contains(line)) }
    XCTAssertLessThan(refined.minX, initial.minX)
    if let output = ProcessInfo.processInfo.environment["KAIBA_TEST_FIGURE_OUTPUT"] {
      let extractor = CroppingDocumentPageFigureExtractor(locator: CaptionClippingFigureLocator())
      let figure = try XCTUnwrap(extractor.extractFigures(imageURL: url, pageNumber: 8).first)
      try figure.data.write(to: URL(fileURLWithPath: output))
    }
  }
}
private struct CaptionClippingFigureLocator: DocumentFigureLocating {
  func regions(imageURL: URL) throws -> [DocumentFigureRegion] {
    [.init(x: 0.255, y: 0.184, width: 0.6, height: 0.2075)]
  }
}
#endif
