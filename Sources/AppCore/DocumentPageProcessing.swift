import Foundation

public enum DocumentWritingMode: String, Codable, Sendable {
  case horizontal, vertical, unknown
}

public enum DocumentBinding: String, Codable, Sendable {
  case left, right, unknown
}

/// Unknown values remain explicit: an OCR engine need not pretend to understand layout.
public struct DocumentPageAnalysis: Codable, Equatable, Sendable {
  public var isDocument: Bool?
  public var language: String?
  public var writingMode: DocumentWritingMode
  public var binding: DocumentBinding
  public var title: String?

  public init(
    isDocument: Bool? = nil, language: String? = nil,
    writingMode: DocumentWritingMode = .unknown, binding: DocumentBinding = .unknown,
    title: String? = nil
  ) {
    self.isDocument = isDocument
    self.language = language
    self.writingMode = writingMode
    self.binding = binding
    self.title = title
  }
}

public protocol DocumentPageAnalyzing: Sendable {
  func analyze(imageURL: URL) throws -> DocumentPageAnalysis
}

public protocol DocumentPageRecognizing: Sendable {
  func recognize(imageURL: URL) throws -> String
}

/// Adapts existing gateway OCR without coupling the page pipeline to a vendor.
public struct ConverterPageRecognizer: DocumentPageRecognizing {
  public let converter: any DocumentConverting

  public init(converter: any DocumentConverting) {
    self.converter = converter
  }

  public func recognize(imageURL: URL) throws -> String {
    try converter.convert(inputPath: imageURL.path).markdown
  }
}

public struct PreparedDocumentPage: Equatable, Sendable {
  public var pageNumber: Int
  public var origin: DocumentExtractedImage
  public var figures: [DocumentExtractedImage]
  public var analysis: DocumentPageAnalysis
  /// nil means OCR is pending; an empty string means OCR ran and found no text.
  public var markdown: String?
}

public struct DocumentPageProcessor: Sendable {
  public let recognizer: any DocumentPageRecognizing
  public let analyzer: (any DocumentPageAnalyzing)?
  public let figureExtractor: (any DocumentPageFigureExtracting)?
  public let extractor: any DocumentImageExtracting

  public init(
    recognizer: any DocumentPageRecognizing,
    analyzer: (any DocumentPageAnalyzing)? = nil,
    extractor: any DocumentImageExtracting = DocumentImageExtractor(),
    figureExtractor: (any DocumentPageFigureExtracting)? = nil
  ) {
    self.recognizer = recognizer
    self.analyzer = analyzer
    self.extractor = extractor
    self.figureExtractor = figureExtractor
  }

  /// nil processes all pages; zero imports originals only. Pages beyond the
  /// limit invoke neither the analyzer nor OCR and retain their physical order.
  public func prepare(fileURL: URL, maximumOCRPages: Int? = 3) throws -> [PreparedDocumentPage] {
    guard maximumOCRPages.map({ $0 >= 0 }) ?? true else {
      throw NoteServiceError.invalidInput("maximum OCR pages must be nonnegative or all")
    }
    let format = fileURL.pathExtension.lowercased()
    let extraction: DocumentImageExtractionResult
    if ["png", "jpg", "jpeg", "gif", "webp"].contains(format) {
      extraction = DocumentImageExtractionResult(images: [DocumentExtractedImage(
        pageNumber: 1, kind: .pageCapture, data: try Data(contentsOf: fileURL),
        mediaType: NoteService.mediaType(forSourceFormat: format),
        suggestedFilename: fileURL.lastPathComponent
      )])
    } else if format == "pdf" {
      extraction = try extractor.extractImages(fileURL: fileURL, sourceFormat: format)
    } else {
      throw DocumentConversionError.unsupported(kind: format, message: "page import requires a PDF or image")
    }
    let origins = extraction.images.filter { $0.kind == .pageCapture }.sorted { $0.pageNumber < $1.pageNumber }
    guard !origins.isEmpty else {
      throw DocumentConversionError.failed("source produced no page images")
    }
    // Never silently shift later notes when a renderer skips a damaged page.
    guard origins.map(\.pageNumber) == Array(1...origins.count),
          extraction.pageTexts.isEmpty || extraction.pageTexts.count == origins.count else {
      throw DocumentConversionError.failed("source did not render every page in order")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try origins.enumerated().map { index, origin in
      var page = PreparedDocumentPage(
        pageNumber: origin.pageNumber, origin: origin,
        figures: figureExtractor == nil
          ? extraction.images.filter { $0.kind == .embedded && $0.pageNumber == origin.pageNumber } : [],
        analysis: DocumentPageAnalysis(), markdown: nil
      )
      if maximumOCRPages.map({ index < $0 }) ?? true {
        let imageURL = directory.appendingPathComponent("page-\(origin.pageNumber)")
          .appendingPathExtension(DocumentImageNaming.fileExtension(forMediaType: origin.mediaType))
        try origin.data.write(to: imageURL)
        page.analysis = try analyzer?.analyze(imageURL: imageURL) ?? DocumentPageAnalysis()
        page.markdown = try recognizer.recognize(imageURL: imageURL)
        if let figureExtractor {
          page.figures = try figureExtractor.extractFigures(imageURL: imageURL, pageNumber: origin.pageNumber)
        }
      }
      return page
    }
  }
}
