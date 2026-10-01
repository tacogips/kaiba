import Foundation
import XCTest
@testable import AppCore
#if canImport(PDFKit)
import CoreGraphics
import ImageIO
import PDFKit
#endif

final class PDFPageRasterDeterminismTests: XCTestCase {
  func testPageCaptureBytesAreDeterministicAt1600Pixels() throws {
    #if canImport(PDFKit)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let pdf = root.appendingPathComponent("synthetic.pdf")
    var mediaBox = CGRect(x: 0, y: 0, width: 800, height: 1_000)
    let data = NSMutableData()
    let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
    let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
    for page in 0..<2 {
      context.beginPage(mediaBox: &mediaBox)
      context.setFillColor(CGColor(gray: CGFloat(page) * 0.4, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 800, height: 1_000))
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(CGRect(x: 80, y: 100, width: 300, height: 120))
      context.endPage()
    }
    context.closePDF()
    try (data as Data).write(to: pdf)

    let extractor = DocumentImageExtractor()
    let first = try extractor.extractImages(fileURL: pdf, sourceFormat: "pdf")
      .images.filter { $0.kind == .pageCapture }
    let second = try extractor.extractImages(fileURL: pdf, sourceFormat: "pdf")
      .images.filter { $0.kind == .pageCapture }
    XCTAssertEqual(first.map(\.pageNumber), [1, 2])
    XCTAssertEqual(second.map(\.pageNumber), [1, 2])
    XCTAssertEqual(first.map(\.data), second.map(\.data))
    for capture in first {
      let source = try XCTUnwrap(CGImageSourceCreateWithData(capture.data as CFData, nil))
      let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
      XCTAssertEqual(max(image.width, image.height), 1_600)
    }
    #else
    throw XCTSkip("PDFKit is unavailable")
    #endif
  }
}
