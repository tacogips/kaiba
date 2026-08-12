import Foundation

/// How an extracted image relates to its source page: a raster capture of the
/// whole page, or an image that the document embeds inside the page.
public enum DocumentPageImageKind: String, Codable, Equatable, Sendable {
  case pageCapture = "page-capture"
  case embedded
}

/// One image pulled out of a source document during import.
public struct DocumentExtractedImage: Equatable, Sendable {
  /// 1-based page number for paginated formats (PDF), or the 1-based spine
  /// item index for reflowable formats (EPUB).
  public var pageNumber: Int
  public var kind: DocumentPageImageKind
  public var data: Data
  public var mediaType: String
  public var suggestedFilename: String

  public init(
    pageNumber: Int,
    kind: DocumentPageImageKind,
    data: Data,
    mediaType: String,
    suggestedFilename: String
  ) {
    self.pageNumber = pageNumber
    self.kind = kind
    self.data = data
    self.mediaType = mediaType
    self.suggestedFilename = suggestedFilename
  }
}

public struct DocumentImageExtractionResult: Equatable, Sendable {
  public var images: [DocumentExtractedImage]
  /// Per-page plain text, used to map pages onto the notes the markdown split
  /// produced. Empty when the format exposes no per-page text.
  public var pageTexts: [String]

  public static let empty = DocumentImageExtractionResult()

  public init(images: [DocumentExtractedImage] = [], pageTexts: [String] = []) {
    self.images = images
    self.pageTexts = pageTexts
  }
}

public protocol DocumentImageExtracting: Sendable {
  func extractImages(fileURL: URL, sourceFormat: String) throws -> DocumentImageExtractionResult
}

/// Routes an import source to the extractor that understands its container.
/// Formats without an extractor yield an empty result rather than an error, so
/// image extraction stays an additive step on top of markdown conversion.
public struct DocumentImageExtractor: DocumentImageExtracting {
  public var pdf: any DocumentImageExtracting
  public var epub: any DocumentImageExtracting

  public init(
    pdf: any DocumentImageExtracting = PDFDocumentImageExtractor(),
    epub: any DocumentImageExtracting = EPUBDocumentImageExtractor()
  ) {
    self.pdf = pdf
    self.epub = epub
  }

  public func extractImages(
    fileURL: URL,
    sourceFormat: String
  ) throws -> DocumentImageExtractionResult {
    switch Self.normalizedFormat(sourceFormat: sourceFormat, fileURL: fileURL) {
    case "pdf":
      return try pdf.extractImages(fileURL: fileURL, sourceFormat: "pdf")
    case "epub":
      return try epub.extractImages(fileURL: fileURL, sourceFormat: "epub")
    default:
      return .empty
    }
  }

  static func normalizedFormat(sourceFormat: String, fileURL: URL) -> String {
    let declared = sourceFormat.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if !declared.isEmpty {
      return declared
    }
    return fileURL.pathExtension.lowercased()
  }
}

/// Shared naming so page captures and embedded images sort predictably by
/// filename regardless of which extractor produced them.
enum DocumentImageNaming {
  static func pageCaptureFilename(pageNumber: Int, fileExtension: String) -> String {
    "page-\(paddedPage(pageNumber)).\(fileExtension)"
  }

  static func embeddedFilename(pageNumber: Int, index: Int, fileExtension: String) -> String {
    "page-\(paddedPage(pageNumber))-image-\(index).\(fileExtension)"
  }

  static func fileExtension(forMediaType mediaType: String) -> String {
    switch mediaType {
    case "image/jpeg": return "jpg"
    case "image/png": return "png"
    case "image/gif": return "gif"
    case "image/webp": return "webp"
    case "image/svg+xml": return "svg"
    case "image/jp2": return "jp2"
    default: return "bin"
    }
  }

  private static func paddedPage(_ pageNumber: Int) -> String {
    let digits = String(max(pageNumber, 0))
    return digits.count >= 4 ? digits : String(repeating: "0", count: 4 - digits.count) + digits
  }
}
