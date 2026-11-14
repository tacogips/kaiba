import Foundation
@testable import AppCore
import XCTest

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

  func testInvalidAnalysisFailsInsteadOfGuessing() {
    let analyzer = StructuredDocumentPageAnalyzer(converter: VisualResponse(markdown: "Some prose {\"isDocument\":true}"))
    XCTAssertThrowsError(try analyzer.analyze(imageURL: URL(fileURLWithPath: "/page.png")))
  }

  func testIndependentGatewayConfigurationsRoundTrip() throws {
    let settings = KaibaImportConfiguration(
      ocrEngine: .vision, maximumOCRPages: .first(2),
      analysis: KaibaOCRConfiguration(vendor: "codex", model: "analysis-model")
    )
    XCTAssertEqual(try JSONDecoder().decode(KaibaImportConfiguration.self, from: JSONEncoder().encode(settings)), settings)
    XCTAssertNotNil(settings.makePageAnalyzer(environment: [:]))
    XCTAssertNil(KaibaImportConfiguration().makePageAnalyzer())
    let legacy = Data(#"{"import":{"ocrEngine":"vision","maximumOCRPages":"all","figures":{"vendor":"anthropic","model":"ignored"}}}"#.utf8)
    let configuration = try JSONDecoder().decode(KaibaConfiguration.self, from: legacy)
    let decoded = try XCTUnwrap(configuration.importSettings)
    XCTAssertEqual(decoded.ocrEngine, .vision)
    XCTAssertEqual(decoded.maximumOCRPages, .all)
  }

}

private struct VisualResponse: DocumentConverting {
  var markdown: String
  func convert(inputPath: String) throws -> DocumentConversionResult { DocumentConversionResult(markdown: markdown, sourceFormat: "png") }
}
