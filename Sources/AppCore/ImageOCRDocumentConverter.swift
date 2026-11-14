import Foundation

/// Selects OCR for standalone images and anydoc-swift for document formats.
public struct ImportDocumentConverter: DocumentConverting {
  public var anydoc: AnydocKitDocumentConverter
  public var ocr: AgentGatewayImageOCRConverter?

  public init(
    anydoc: AnydocKitDocumentConverter = AnydocKitDocumentConverter(),
    ocr: AgentGatewayImageOCRConverter? = nil
  ) {
    self.anydoc = anydoc
    self.ocr = ocr
  }

  public func convert(inputPath: String) throws -> DocumentConversionResult {
    guard Self.isImagePath(inputPath) else {
      return try anydoc.convert(inputPath: inputPath)
    }
    guard let ocr else {
      throw DocumentConversionError.failed(
        "image OCR is not configured; set import.ocr.vendor and import.ocr.model"
      )
    }
    return try ocr.convert(inputPath: inputPath)
  }

  static func isImagePath(_ path: String) -> Bool {
    supportedImageExtensions.contains(
      URL(fileURLWithPath: path).pathExtension.lowercased()
    )
  }

  private static let supportedImageExtensions: Set<String> = [
    "gif", "jpeg", "jpg", "png", "webp"
  ]
}

/// OCR adapter over `agent-gateway client --image`. It deliberately shares
/// the gateway's ACP reply parser with the normal AI invoker.
public struct AgentGatewayImageOCRConverter: DocumentConverting {
  public static let defaultPrompt = """
  Transcribe all visible text in this image into GitHub-Flavored Markdown.
  Preserve headings, paragraphs, lists, tables, and reading order. Return only Markdown.
  """

  public var commandPath: String?
  public var vendor: String
  public var model: String
  public var apiKeyEnvironment: String?
  public var environment: [String: String]
  public var prompt: String
  public var executionMode: AgentGatewayExecutionMode
  public var timeoutNanoseconds: UInt64

  public init(
    commandPath: String? = nil,
    vendor: String,
    model: String,
    apiKeyEnvironment: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    prompt: String = Self.defaultPrompt,
    executionMode: AgentGatewayExecutionMode = .local,
    timeoutNanoseconds: UInt64 = 120_000_000_000
  ) {
    self.commandPath = commandPath
    self.vendor = vendor
    self.model = model
    self.apiKeyEnvironment = apiKeyEnvironment
    self.environment = environment
    self.prompt = prompt
    self.executionMode = executionMode
    self.timeoutNanoseconds = timeoutNanoseconds
  }

  public func convert(inputPath: String) throws -> DocumentConversionResult {
    do { return try performConversion(inputPath: inputPath) } catch {
      if executionMode != .local { throw DocumentConversionError.failed("agent-gateway image processing failed") }
      throw error
    }
  }

  private func performConversion(inputPath: String) throws -> DocumentConversionResult {
    guard Self.supportedVendors.contains(vendor) else {
      throw DocumentConversionError.failed(
        "OCR vendor \(vendor) is not image-capable through agent-gateway; "
          + "use claude-code, codex, openai, anthropic, gemini, or openrouter"
      )
    }
    let binary: String
    do {
      binary = try resolveBinary()
    } catch AgentInvocationError.unavailable(let message) {
      throw DocumentConversionError.failed(message)
    } catch {
      throw DocumentConversionError.failed("agent-gateway is unavailable: \(error)")
    }

    var arguments = [
      "client", "--vendor", vendor, "--model", model,
      "--prompt", "-"
    ]
    if vendor != "codex", vendor != "claude-code", executionMode == .local {
      arguments += ["--image", inputPath]
    }
    if let apiKeyEnvironment, !apiKeyEnvironment.isEmpty {
      arguments += ["--api-key-environment", apiKeyEnvironment]
    }
    if vendor == "codex", executionMode == .local {
      // agent-gateway 0.1.2 accepts ACP image blocks but does not yet forward
      // them to CLI vendors. Vendor arguments after `--` reach `codex exec`,
      // whose native --image option supplies the same file without bypassing
      // gateway-owned model/provider routing.
      arguments += ["--", "--image", inputPath]
    }
    if vendor == "claude-code", executionMode == .local {
      arguments += ["--"] + ClaudeImageInput.arguments
    }
    var context = try AgentGatewayCLIInvoker.executionContext(
      mode: executionMode, vendor: vendor, binary: binary, arguments: arguments,
      environment: environment, apiKeyEnvironment: apiKeyEnvironment
    )
    defer { context.cleanUp() }
    if executionMode != .local, vendor != "claude-code" {
      guard let workspace = context.workspace else { throw DocumentConversionError.failed("image workspace unavailable") }
      let image = workspace.appendingPathComponent("page").appendingPathExtension(URL(fileURLWithPath: inputPath).pathExtension)
      try FileManager.default.copyItem(at: URL(fileURLWithPath: inputPath), to: image)
      context.arguments += ["--image", image.path]
    }
    if executionMode != .local, vendor == "claude-code" {
      context.arguments += ["--input-format", "stream-json"]
    }
    let input = try vendor == "claude-code"
      ? ClaudeImageInput.encode(prompt: prompt, imageURL: URL(fileURLWithPath: inputPath))
      : Data(prompt.utf8)
    let execution = try run(context: context, stdin: input)
    let parsed = AgentGatewayCLIInvoker.parseACPOutput(execution.stdout)
    if let message = parsed.errorMessage {
      throw DocumentConversionError.failed(message)
    }
    guard execution.exitCode == 0 else {
      let detail = String(data: execution.stderr.suffix(1_000), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw DocumentConversionError.failed(
        detail?.isEmpty == false
          ? detail ?? "image OCR failed"
          : "agent-gateway OCR exited with status \(execution.exitCode)"
      )
    }
    guard let markdown = parsed.resultText
      ?? (parsed.streamedText.isEmpty ? nil : parsed.streamedText),
      !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw DocumentConversionError.failed("agent-gateway OCR produced no Markdown")
    }
    return DocumentConversionResult(
      markdown: markdown,
      sourceFormat: URL(fileURLWithPath: inputPath).pathExtension.lowercased(),
      toolName: AgentGatewayCLIInvoker.defaultBinaryName
    )
  }

  private func run(context: AgentGatewayExecutionContext, stdin: Data) throws -> AgentGatewayCLIInvoker.Execution {
    let completion = SynchronousGatewayResult()
    Task.detached {
      do {
        completion.finish(.success(try await AgentGatewayCLIInvoker.run(
          binary: context.binary, arguments: context.arguments, stdin: stdin,
          environment: context.environment, timeoutNanoseconds: timeoutNanoseconds,
          workingDirectory: context.workingDirectory
        )))
      } catch { completion.finish(.failure(error)) }
    }
    return try completion.wait()
  }

  private func resolveBinary() throws -> String {
    if let commandPath, !commandPath.isEmpty {
      let expanded = (commandPath as NSString).expandingTildeInPath
      guard FileManager.default.isExecutableFile(atPath: expanded) else {
        throw AgentInvocationError.unavailable("agent-gateway binary not found: \(expanded)")
      }
      return expanded
    }
    let searchPath = environment["PATH"] ?? ""
    for directory in searchPath.split(separator: ":") {
      let candidate = (String(directory) as NSString)
        .appendingPathComponent(AgentGatewayCLIInvoker.defaultBinaryName)
      if FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }
    throw AgentInvocationError.unavailable(
      "agent-gateway binary not found on PATH; install it or set import.ocr.commandPath"
    )
  }

  static let supportedVendors: Set<String> = [
    "anthropic", "claude-code", "codex", "gemini", "openai", "openrouter"
  ]
}
