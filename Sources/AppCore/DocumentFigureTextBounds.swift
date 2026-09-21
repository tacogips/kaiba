import Foundation
#if canImport(Vision)
import Vision
import CoreGraphics

/// Refines model geometry using local text-line bounds. Recognized strings are
/// discarded; no remote provider is invoked. Coordinates use upright pixels.
enum DocumentFigureTextBounds {
  static func detect(in image: CGImage) throws -> [CGRect] {
    // Vision's fast recognizer may reuse image-provider storage for its
    // segmentation work. Give it independent pixels so crops remain original.
    guard let buffer = CGContext(
      data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
      bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw DocumentConversionError.failed("could not allocate text-bound detection image") }
    buffer.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let detectionImage = buffer.makeImage() else {
      throw DocumentConversionError.failed("could not prepare text-bound detection image")
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .fast
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: detectionImage).perform([request])
    return (request.results ?? []).map { observation in
      let bounds = observation.boundingBox
      return CGRect(
        x: bounds.minX * CGFloat(image.width), y: (1 - bounds.maxY) * CGFloat(image.height),
        width: bounds.width * CGFloat(image.width), height: bounds.height * CGFloat(image.height)
      )
    }
  }

  static func refine(_ rectangle: CGRect, textLines: [CGRect], page: CGRect) -> CGRect {
    var result = rectangle
    // Use the original box for every intersection. Expansion must not cascade
    // through adjacent paragraphs or swallow an entire column of body text.
    for line in textLines where !line.isEmpty && line.height <= page.height * 0.1 {
      let overlap = rectangle.intersection(line)
      guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
      if !rectangle.contains(line.insetBy(dx: -2, dy: -2)) {
        result = result.union(line.insetBy(dx: -2, dy: -2))
      }
    }
    return result.integral.intersection(page)
  }
}
#endif
