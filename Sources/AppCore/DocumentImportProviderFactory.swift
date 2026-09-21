import Foundation

public extension KaibaImportConfiguration {
  func makePageRecognizer(environment: [String: String] = ProcessInfo.processInfo.environment, executionMode: AgentGatewayExecutionMode = .local) throws -> any DocumentPageRecognizing {
    switch resolvedOCREngine {
    case .vision: return VisionDocumentPageRecognizer()
    case .googleDocumentAI:
      guard let googleDocumentAI else { throw DocumentConversionError.failed("Google Document AI OCR requires import.googleDocumentAI configuration") }
      return GoogleDocumentAIPageRecognizer(configuration: googleDocumentAI, environment: environment)
    case .agentGateway:
      guard let ocr else { throw DocumentConversionError.failed("gateway OCR requires import.ocr configuration") }
      return ConverterPageRecognizer(converter: ocr.makeImageConverter(environment: environment, executionMode: documentExecutionMode(vendor: ocr.vendor, requested: executionMode)))
    }
  }

  var resolvedOCREngine: DocumentOCREngine {
    ocrEngine ?? (googleDocumentAI != nil ? .googleDocumentAI : (ocr == nil ? .vision : .agentGateway))
  }

  func makePageAnalyzer(environment: [String: String] = ProcessInfo.processInfo.environment, executionMode: AgentGatewayExecutionMode = .local) -> (any DocumentPageAnalyzing)? {
    analysis.map {
      StructuredDocumentPageAnalyzer(converter: $0.makeImageConverter(
        environment: environment, prompt: StructuredDocumentPageAnalyzer.prompt,
        executionMode: documentExecutionMode(vendor: $0.vendor, requested: executionMode)
      ))
    }
  }

  func makeFigureExtractor(environment: [String: String] = ProcessInfo.processInfo.environment, executionMode: AgentGatewayExecutionMode = .local) -> (any DocumentPageFigureExtracting)? {
    figures.map {
      CroppingDocumentPageFigureExtractor(locator: StructuredDocumentFigureLocator(
        converter: $0.makeImageConverter(environment: environment, prompt: StructuredDocumentFigureLocator.prompt, executionMode: documentExecutionMode(vendor: $0.vendor, requested: executionMode))
      ))
    }
  }

  private func documentExecutionMode(vendor: String, requested: AgentGatewayExecutionMode) -> AgentGatewayExecutionMode {
    guard requested != .local, vendor == "claude-code" else { return requested }
    return allowClaudeSubscription == true ? .subscription : .served
  }
}

public extension KaibaOCRConfiguration {
  func makeImageConverter(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    prompt: String = AgentGatewayImageOCRConverter.defaultPrompt,
    executionMode: AgentGatewayExecutionMode = .local
  ) -> AgentGatewayImageOCRConverter {
    AgentGatewayImageOCRConverter(
      commandPath: commandPath, vendor: vendor, model: model,
      apiKeyEnvironment: apiKeyEnvironmentVariable, environment: environment, prompt: prompt, executionMode: executionMode == .subscription && !["codex", "claude-code"].contains(vendor) ? .served : executionMode
    )
  }
}
