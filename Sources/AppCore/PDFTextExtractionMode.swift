import Foundation

public enum PDFTextExtractionMode: String, Codable, Equatable, Sendable {
  case preferPDFText = "prefer-pdf-text"
  case ocrOnly = "ocr-only"

  public static func parse(_ value: String) throws -> Self {
    guard let mode = Self(rawValue: value) else {
      throw NoteServiceError.invalidInput("PDF text mode must be prefer-pdf-text or ocr-only")
    }
    return mode
  }
}

public extension NoteService {
  func resolvePDFTextMode(override: String? = nil, configuration: PDFTextExtractionMode? = nil) throws -> PDFTextExtractionMode {
    if let override { return try PDFTextExtractionMode.parse(override) }
    if let json = try appSetting(key: "web"),
       let stored = try JSONValue(parsing: json).asObject?["pdfTextMode"]?.asString,
       let mode = PDFTextExtractionMode(rawValue: stored) { return mode }
    return configuration ?? .preferPDFText
  }
}
