import Foundation

#if canImport(PDFKit)
import CoreGraphics
import ImageIO
import PDFKit
#endif

/// Extracts per-page rasters and embedded raster images from a PDF.
///
/// Page captures give every note a visual of the source page it came from;
/// embedded images recover the illustrations that markdown conversion drops.
/// The reconstruction of embedded images is deliberately conservative: only the
/// encodings that survive a straight copy (JPEG) or a trivial rebuild
/// (8-bit DeviceRGB/DeviceGray, directly named or behind an ICCBased profile)
/// are emitted, since a wrong guess about a color space produces a
/// plausible-looking but corrupted image.
///
/// PDFKit is Apple-only. On other platforms this extractor yields no images so
/// document import still succeeds.
public struct PDFDocumentImageExtractor: DocumentImageExtracting {
  /// Longest side of a page capture, in pixels.
  public static let maximumCaptureSide = 1600
  /// Upper bound on the render scale, so small pages stay legible without
  /// growing past what a reader pane can use.
  public static let maximumCaptureScale = 2.0
  public static let captureQuality = 0.8
  /// Embedded images below this size are icons, rules, and spacers.
  public static let minimumEmbeddedSide = 32
  public static let minimumEmbeddedBytes = 1024
  /// Runaway guard for documents with unusually many illustrations.
  public static let maximumEmbeddedImages = 200

  public init() {}

  public func extractImages(
    fileURL: URL,
    sourceFormat: String
  ) throws -> DocumentImageExtractionResult {
    #if canImport(PDFKit)
    guard let document = PDFDocument(url: fileURL) else {
      throw DocumentConversionError.failed(
        "PDF is not readable for image extraction: \(fileURL.lastPathComponent)"
      )
    }
    var images: [DocumentExtractedImage] = []
    var pageTexts: [String] = []
    // Repeated bytes are page furniture (logos, rules) rather than content, so
    // only the first page carrying them keeps a copy.
    var seenDigests: Set<String> = []
    var embeddedCount = 0
    for pageIndex in 0..<document.pageCount {
      guard let page = document.page(at: pageIndex) else {
        pageTexts.append("")
        continue
      }
      let pageNumber = pageIndex + 1
      pageTexts.append(page.string ?? "")
      if let capture = Self.pageCapture(page: page, pageNumber: pageNumber) {
        images.append(capture)
      }
      var emittedOnPage = 0
      for candidate in Self.embeddedImages(page: page) {
        guard embeddedCount < Self.maximumEmbeddedImages else {
          break
        }
        guard seenDigests.insert(sha256Hex(candidate.data)).inserted else {
          continue
        }
        emittedOnPage += 1
        embeddedCount += 1
        images.append(DocumentExtractedImage(
          pageNumber: pageNumber,
          kind: .embedded,
          data: candidate.data,
          mediaType: candidate.mediaType,
          suggestedFilename: DocumentImageNaming.embeddedFilename(
            pageNumber: pageNumber,
            index: emittedOnPage,
            fileExtension: DocumentImageNaming.fileExtension(forMediaType: candidate.mediaType)
          )
        ))
      }
    }
    return DocumentImageExtractionResult(images: images, pageTexts: pageTexts)
    #else
    return .empty
    #endif
  }
}

#if canImport(PDFKit)

private struct EmbeddedImageCandidate {
  var data: Data
  var mediaType: String
}

private extension PDFDocumentImageExtractor {
  // MARK: - Page capture

  static func pageCapture(page: PDFPage, pageNumber: Int) -> DocumentExtractedImage? {
    let bounds = page.bounds(for: .mediaBox)
    // `rotation` is a multiple of 90; a quarter turn swaps the visible extent.
    let quarterTurns = (((page.rotation % 360) + 360) % 360) / 90
    let isSideways = quarterTurns % 2 == 1
    let width = isSideways ? bounds.height : bounds.width
    let height = isSideways ? bounds.width : bounds.height
    guard width > 0, height > 0 else {
      return nil
    }
    let scale = min(
      CGFloat(maximumCaptureScale),
      CGFloat(maximumCaptureSide) / max(width, height)
    )
    let pixelWidth = max(1, Int((width * scale).rounded()))
    let pixelHeight = max(1, Int((height * scale).rounded()))
    guard let context = CGContext(
      data: nil,
      width: pixelWidth,
      height: pixelHeight,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
      return nil
    }
    // PDF pages assume paper: without this the unpainted area renders black.
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
    context.saveGState()
    context.scaleBy(x: scale, y: scale)
    // `draw(with:to:)` applies the box origin and page rotation itself.
    page.draw(with: .mediaBox, to: context)
    context.restoreGState()
    guard let image = context.makeImage(), let data = encodeJPEG(image) else {
      return nil
    }
    return DocumentExtractedImage(
      pageNumber: pageNumber,
      kind: .pageCapture,
      data: data,
      mediaType: "image/jpeg",
      suggestedFilename: DocumentImageNaming.pageCaptureFilename(
        pageNumber: pageNumber,
        fileExtension: "jpg"
      )
    )
  }

  // MARK: - Embedded images

  static func embeddedImages(page: PDFPage) -> [EmbeddedImageCandidate] {
    guard let pageDictionary = page.pageRef?.dictionary else {
      return []
    }
    var resources: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources),
          let resources else {
      return []
    }
    var xobjects: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects),
          let xobjects else {
      return []
    }
    // XObject keys are unordered; sorting keeps a repeated import stable.
    return dictionaryKeys(in: xobjects).sorted().compactMap { key in
      var stream: CGPDFStreamRef?
      guard CGPDFDictionaryGetStream(xobjects, key, &stream), let stream else {
        return nil
      }
      return candidate(from: stream)
    }
  }

  static func candidate(from stream: CGPDFStreamRef) -> EmbeddedImageCandidate? {
    guard let dictionary = CGPDFStreamGetDictionary(stream),
          name(in: dictionary, key: "Subtype") == "Image" else {
      return nil
    }
    var isImageMask: CGPDFBoolean = 0
    if CGPDFDictionaryGetBoolean(dictionary, "ImageMask", &isImageMask), isImageMask != 0 {
      return nil
    }
    guard let width = integer(in: dictionary, key: "Width"),
          let height = integer(in: dictionary, key: "Height"),
          width >= minimumEmbeddedSide, height >= minimumEmbeddedSide else {
      return nil
    }
    var format: CGPDFDataFormat = .raw
    guard let copied = CGPDFStreamCopyData(stream, &format) else {
      return nil
    }
    let data = copied as Data
    guard data.count >= minimumEmbeddedBytes else {
      return nil
    }
    switch format {
    case .jpegEncoded:
      return EmbeddedImageCandidate(data: data, mediaType: "image/jpeg")
    case .JPEG2000:
      // JPEG 2000 is unusable in a browser, so it is re-encoded rather than
      // passed through.
      guard let transcoded = transcodeToJPEG(data) else {
        return nil
      }
      return EmbeddedImageCandidate(data: transcoded, mediaType: "image/jpeg")
    case .raw:
      guard let png = encodePNG(
        rawData: data,
        dictionary: dictionary,
        width: width,
        height: height
      ) else {
        return nil
      }
      return EmbeddedImageCandidate(data: png, mediaType: "image/png")
    @unknown default:
      return nil
    }
  }

  /// Rebuilds a CGImage from decoded sample data for the two color spaces whose
  /// layout is unambiguous, and encodes it as PNG.
  static func encodePNG(
    rawData: Data,
    dictionary: CGPDFDictionaryRef,
    width: Int,
    height: Int
  ) -> Data? {
    guard integer(in: dictionary, key: "BitsPerComponent") == 8,
          let (colorSpace, componentCount) = resolvedColorSpace(in: dictionary) else {
      return nil
    }
    let bytesPerRow = width * componentCount
    let expectedBytes = bytesPerRow * height
    guard expectedBytes > 0, rawData.count >= expectedBytes,
          let provider = CGDataProvider(data: Data(rawData.prefix(expectedBytes)) as CFData),
          let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8 * componentCount,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
          ) else {
      return nil
    }
    return encode(image, as: "public.png", options: nil)
  }

  /// Resolves the sample layout of an image's color space. Direct
  /// `/DeviceRGB` and `/DeviceGray` names are accepted, and so are `ICCBased`
  /// profiles whose declared component count (`/N`) is 3 or 1 — Quartz-written
  /// PDFs (macOS print-to-PDF among them) store even plain RGB images behind
  /// an ICC profile, which the device color space renders acceptably. CMYK and
  /// exotic spaces stay rejected: a wrong guess corrupts the image.
  static func resolvedColorSpace(in dictionary: CGPDFDictionaryRef) -> (CGColorSpace, Int)? {
    if let colorSpaceName = name(in: dictionary, key: "ColorSpace") {
      switch colorSpaceName {
      case "DeviceRGB": return (CGColorSpaceCreateDeviceRGB(), 3)
      case "DeviceGray": return (CGColorSpaceCreateDeviceGray(), 1)
      default: return nil
      }
    }
    var array: CGPDFArrayRef?
    guard CGPDFDictionaryGetArray(dictionary, "ColorSpace", &array), let array,
          CGPDFArrayGetCount(array) >= 2 else {
      return nil
    }
    var familyPointer: UnsafePointer<Int8>?
    guard CGPDFArrayGetName(array, 0, &familyPointer), let familyPointer,
          String(cString: familyPointer) == "ICCBased" else {
      return nil
    }
    var profileStream: CGPDFStreamRef?
    guard CGPDFArrayGetStream(array, 1, &profileStream), let profileStream,
          let profileDictionary = CGPDFStreamGetDictionary(profileStream),
          let componentCount = integer(in: profileDictionary, key: "N") else {
      return nil
    }
    switch componentCount {
    case 3: return (CGColorSpaceCreateDeviceRGB(), 3)
    case 1: return (CGColorSpaceCreateDeviceGray(), 1)
    default: return nil
    }
  }

  static func transcodeToJPEG(_ data: Data) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      return nil
    }
    return encodeJPEG(image)
  }

  static func encodeJPEG(_ image: CGImage) -> Data? {
    encode(
      image,
      as: "public.jpeg",
      options: [kCGImageDestinationLossyCompressionQuality: captureQuality] as CFDictionary
    )
  }

  static func encode(_ image: CGImage, as identifier: String, options: CFDictionary?) -> Data? {
    let buffer = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      buffer as CFMutableData,
      identifier as CFString,
      1,
      nil
    ) else {
      return nil
    }
    CGImageDestinationAddImage(destination, image, options)
    guard CGImageDestinationFinalize(destination) else {
      return nil
    }
    return buffer as Data
  }

  // MARK: - CGPDF dictionary reads

  static func dictionaryKeys(in dictionary: CGPDFDictionaryRef) -> [String] {
    let collector = PDFDictionaryKeyCollector()
    CGPDFDictionaryApplyFunction(
      dictionary,
      { key, _, info in
        guard let info else {
          return
        }
        Unmanaged<PDFDictionaryKeyCollector>.fromOpaque(info)
          .takeUnretainedValue()
          .keys
          .append(String(cString: key))
      },
      Unmanaged.passUnretained(collector).toOpaque()
    )
    return collector.keys
  }

  static func name(in dictionary: CGPDFDictionaryRef, key: String) -> String? {
    var value: UnsafePointer<Int8>?
    guard CGPDFDictionaryGetName(dictionary, key, &value), let value else {
      return nil
    }
    return String(cString: value)
  }

  static func integer(in dictionary: CGPDFDictionaryRef, key: String) -> Int? {
    var value: CGPDFInteger = 0
    guard CGPDFDictionaryGetInteger(dictionary, key, &value) else {
      return nil
    }
    return Int(value)
  }
}

/// Reference box for `CGPDFDictionaryApplyFunction`, whose callback is a C
/// function pointer and so cannot capture context.
private final class PDFDictionaryKeyCollector {
  var keys: [String] = []
}

#endif
