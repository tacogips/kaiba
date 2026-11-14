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

  public init(
    commandPath: String? = nil,
    vendor: String,
    model: String,
    apiKeyEnvironment: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    prompt: String = Self.defaultPrompt
  ) {
    self.commandPath = commandPath
    self.vendor = vendor
    self.model = model
    self.apiKeyEnvironment = apiKeyEnvironment
    self.environment = environment
    self.prompt = prompt
  }

  public func convert(inputPath: String) throws -> DocumentConversionResult {
    guard Self.supportedVendors.contains(vendor) else {
      throw DocumentConversionError.failed(
        "OCR vendor \(vendor) is not image-capable through agent-gateway; "
          + "use codex, openai, anthropic, gemini, or openrouter"
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
    if vendor != "codex" {
      arguments += ["--image", inputPath]
    }
    if let apiKeyEnvironment, !apiKeyEnvironment.isEmpty {
      arguments += ["--api-key-environment", apiKeyEnvironment]
    }
    if vendor == "codex" {
      // agent-gateway 0.1.2 accepts ACP image blocks but does not yet forward
      // them to CLI vendors. Vendor arguments after `--` reach `codex exec`,
      // whose native --image option supplies the same file without bypassing
      // gateway-owned model/provider routing.
      arguments += ["--", "--image", inputPath]
    }
    let execution = try run(binary: binary, arguments: arguments, stdin: Data(prompt.utf8))
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

  private func run(
    binary: String,
    arguments: [String],
    stdin: Data
  ) throws -> ImageOCRProcessExecution {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    process.environment = environment
    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = error
    let stdoutCollector = ImageOCRPipeCollector(handle: output.fileHandleForReading)
    let stderrCollector = ImageOCRPipeCollector(handle: error.fileHandleForReading)
    do {
      try process.run()
    } catch {
      throw DocumentConversionError.failed("could not launch agent-gateway: \(error)")
    }
    input.fileHandleForWriting.write(stdin)
    try? input.fileHandleForWriting.close()
    process.waitUntilExit()
    let maximumBytes = AgentGatewayCLIInvoker.maximumOutputBytes
    let stdout = stdoutCollector.finish(limit: maximumBytes + 1)
    let stderr = stderrCollector.finish(limit: 64 * 1_024)
    guard stdout.count <= maximumBytes else {
      throw DocumentConversionError.failed("agent-gateway OCR output exceeded the size limit")
    }
    return ImageOCRProcessExecution(
      exitCode: process.terminationStatus,
      stdout: stdout,
      stderr: stderr
    )
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

  private static let supportedVendors: Set<String> = [
    "anthropic", "codex", "gemini", "openai", "openrouter"
  ]
}

private struct ImageOCRProcessExecution {
  var exitCode: Int32
  var stdout: Data
  var stderr: Data
}

/// Drains a process pipe while it runs so a verbose child cannot deadlock on
/// a full stdout or stderr buffer.
private final class ImageOCRPipeCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer = Data()
  private let handle: FileHandle

  init(handle: FileHandle) {
    self.handle = handle
    handle.readabilityHandler = { [weak self] readable in
      let data = readable.availableData
      guard let self else { return }
      if data.isEmpty {
        readable.readabilityHandler = nil
        return
      }
      lock.lock()
      buffer.append(data)
      lock.unlock()
    }
  }

  func finish(limit: Int) -> Data {
    handle.readabilityHandler = nil
    if let remaining = try? handle.readToEnd(), !remaining.isEmpty {
      lock.lock()
      buffer.append(remaining)
      lock.unlock()
    }
    lock.lock()
    defer { lock.unlock() }
    return buffer.prefix(limit)
  }
}
