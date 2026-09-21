import Foundation
#if canImport(Vision)
import Vision
#endif

/// Local OCR option for imports that should not invoke an LLM or a network service.
public struct VisionDocumentPageRecognizer: DocumentPageRecognizing {
  public var recognitionLanguages: [String]

  public init(recognitionLanguages: [String] = []) {
    self.recognitionLanguages = recognitionLanguages
  }

  public func recognize(imageURL: URL) throws -> String {
    #if canImport(Vision)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.automaticallyDetectsLanguage = recognitionLanguages.isEmpty
    if !recognitionLanguages.isEmpty {
      request.recognitionLanguages = recognitionLanguages
    }
    try VNImageRequestHandler(url: imageURL).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    #else
    throw DocumentConversionError.failed("Apple Vision OCR is unavailable on this platform")
    #endif
  }
}
