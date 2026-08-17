import Foundation

/// `AgentInvoking` adapter over the `agent-gateway` ACP CLI
/// (`impl-plans/active/agent-gateway-adapter.md`). Each invocation spawns
/// `agent-gateway client --vendor <v> --model <m> --system <s> --prompt -`,
/// writes the flattened prompt to stdin, and reads the ACP JSONL stream from
/// stdout; the `session/prompt` response's `_meta.agentGateway.resultText` is
/// the authoritative reply (streamed chunks are the fallback). Process spawn
/// only — kaiba keeps zero SwiftPM dependencies, mirroring the anydoc
/// converter pattern.
public struct AgentGatewayCLIInvoker: AgentInvoking {
  public static let defaultBinaryName = "agent-gateway"
  static let maximumOutputBytes = 64 * 1024 * 1024

  public var commandPath: String?
  /// agent-gateway vendor (claude-code, codex, cursor, openai, anthropic,
  /// gemini, openrouter). Mapped from kaiba's `ai.agent.provider`.
  public var vendor: String
  public var model: String
  /// Environment-variable NAME holding the provider credential; the gateway
  /// falls back to its per-vendor default name when absent.
  public var apiKeyEnvironment: String?
  public var environment: [String: String]

  public init(
    commandPath: String? = nil,
    vendor: String,
    model: String,
    apiKeyEnvironment: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.commandPath = commandPath
    self.vendor = vendor
    self.model = model
    self.apiKeyEnvironment = apiKeyEnvironment
    self.environment = environment
  }

  public func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    try await invokeGateway(request, onChunk: nil)
  }

  /// Deliberately not named `invoke`: an overload would make the streaming
  /// conformance below resolve to itself and recurse.
  private func invokeGateway(
    _ request: AgentInvocationRequest,
    onChunk: (@Sendable (String) -> Void)?
  ) async throws -> AgentInvocationResult {
    let binary = try resolveBinary()
    var arguments = [
      "client",
      "--vendor", request.provider ?? vendor,
      "--model", request.model ?? model,
      "--prompt", "-"
    ]
    if !request.systemPrompt.isEmpty {
      arguments += ["--system", request.systemPrompt]
    }
    if let apiKeyEnvironment {
      arguments += ["--api-key-environment", apiKeyEnvironment]
    }
    let promptText = Self.flattenedPrompt(request)
    var lineHandler: (@Sendable (Data) -> Void)?
    if let onChunk {
      lineHandler = { line in
        if let text = Self.agentMessageChunkText(fromACPLine: line) {
          onChunk(text)
        }
      }
    }
    let execution = try await Self.run(
      binary: binary,
      arguments: arguments,
      stdin: Data(promptText.utf8),
      environment: environment,
      onStdoutLine: lineHandler
    )
    let parsed = Self.parseACPOutput(execution.stdout)
    if let errorMessage = parsed.errorMessage {
      throw AgentInvocationError.failed(errorMessage)
    }
    guard let reply = parsed.resultText ?? (parsed.streamedText.isEmpty ? nil : parsed.streamedText)
    else {
      let stderrTail = String(data: execution.stderr.suffix(500), encoding: .utf8) ?? ""
      throw AgentInvocationError.failed(
        "agent-gateway produced no reply (exit \(execution.exitCode))"
          + (stderrTail.isEmpty ? "" : ": \(stderrTail.trimmingCharacters(in: .whitespacesAndNewlines))")
      )
    }
    guard execution.exitCode == 0 else {
      throw AgentInvocationError.failed(
        "agent-gateway exited with status \(execution.exitCode)"
      )
    }
    return AgentInvocationResult(markdown: reply)
  }

  // MARK: - Availability

  func resolveBinary() throws -> String {
    try Self.resolveBinary(commandPath: commandPath, environment: environment)
  }

  static func resolveBinary(
    commandPath: String?,
    environment: [String: String]
  ) throws -> String {
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
        .appendingPathComponent(Self.defaultBinaryName)
      if FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }
    throw AgentInvocationError.unavailable(
      "agent-gateway binary not found on PATH; install it or set ai.agent.commandPath"
    )
  }

  public var isAvailable: Bool {
    (try? resolveBinary()) != nil
  }

  // MARK: - Prompt flattening

  /// The gateway client runs one prompt turn, so history and subject context
  /// flatten into a single prompt text.
  static func flattenedPrompt(_ request: AgentInvocationRequest) -> String {
    var sections: [String] = []
    if let context = request.contextMarkdown, !context.isEmpty {
      sections.append("<document>\n\(context)\n</document>")
    }
    let history = request.turns.dropLast()
    if !history.isEmpty {
      let transcript = history.map { turn in
        "\(turn.role == .user ? "User" : "Assistant"):\n\(turn.markdown)"
      }.joined(separator: "\n\n")
      sections.append("Conversation so far:\n\n\(transcript)")
    }
    if let last = request.turns.last {
      sections.append(history.isEmpty ? last.markdown : "User:\n\(last.markdown)")
    }
    return sections.joined(separator: "\n\n")
  }

  // MARK: - ACP output parsing

  /// Extracts the text of a single ACP `agent_message_chunk` update line;
  /// nil for every other line kind.
  static func agentMessageChunkText(fromACPLine lineData: Data) -> String? {
    guard let object = try? JSONValue(parsing: lineData),
      object["method"]?.asString == "session/update",
      let update = object["params"]?["update"],
      update["sessionUpdate"]?.asString == "agent_message_chunk",
      let text = update["content"]?["text"]?.asString
    else {
      return nil
    }
    return text
  }

  struct ParsedACPOutput: Equatable {
    var resultText: String?
    var streamedText: String = ""
    var errorMessage: String?
  }

  /// Scans the ACP JSONL stream for the prompt response's
  /// `_meta.agentGateway.resultText`, accumulating `agent_message_chunk`
  /// text as a fallback and surfacing JSON-RPC error responses.
  static func parseACPOutput(_ data: Data) -> ParsedACPOutput {
    var parsed = ParsedACPOutput()
    for lineData in data.split(separator: UInt8(ascii: "\n")) {
      guard let object = try? JSONValue(parsing: Data(lineData)) else {
        continue
      }
      if let error = object["error"] {
        let code = error["code"]?.asInt64.map(String.init) ?? error["code"]?.asString ?? "?"
        let message = error["message"]?.asString ?? "unknown agent error"
        parsed.errorMessage = "agent error \(code): \(message)"
        continue
      }
      if object["method"]?.asString == "session/update",
        let update = object["params"]?["update"],
        update["sessionUpdate"]?.asString == "agent_message_chunk",
        let text = update["content"]?["text"]?.asString {
        parsed.streamedText += text
        continue
      }
      if let result = object["result"],
        result["stopReason"] != nil,
        let text = result["_meta"]?["agentGateway"]?["resultText"]?.asString {
        parsed.resultText = text
      }
    }
    return parsed
  }

  // MARK: - Process execution

  struct Execution {
    var exitCode: Int32
    var stdout: Data
    var stderr: Data
  }

  static func run(
    binary: String,
    arguments: [String],
    stdin: Data,
    environment: [String: String],
    onStdoutLine: (@Sendable (Data) -> Void)? = nil
  ) async throws -> Execution {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    process.environment = environment
    let input = Pipe()
    let output = Pipe()
    let errorPipe = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errorPipe

    let stdoutCollector = PipeCollector(handle: output.fileHandleForReading, onLine: onStdoutLine)
    let stderrCollector = PipeCollector(handle: errorPipe.fileHandleForReading)
    do {
      try process.run()
    } catch {
      throw AgentInvocationError.unavailable("agent-gateway could not start: \(binary)")
    }
    input.fileHandleForWriting.write(stdin)
    try? input.fileHandleForWriting.close()

    let exitCode: Int32 = await withCheckedContinuation { continuation in
      process.terminationHandler = { finished in
        continuation.resume(returning: finished.terminationStatus)
      }
    }
    let stdout = stdoutCollector.finish(limit: maximumOutputBytes)
    let stderr = stderrCollector.finish(limit: maximumOutputBytes)
    return Execution(exitCode: exitCode, stdout: stdout, stderr: stderr)
  }
}

/// A model advertised by agent-gateway's vendor model catalog.
public struct AgentGatewayModelInfo: Codable, Equatable, Sendable {
  public var modelId: String
  public var name: String?
  public var description: String?

  public init(modelId: String, name: String? = nil, description: String? = nil) {
    self.modelId = modelId
    self.name = name
    self.description = description
  }
}

/// The typed JSON result returned by `agent-gateway models`.
public struct AgentGatewayModelCatalogResult: Codable, Equatable, Sendable {
  public var protocolVersion: String
  public var vendor: String
  public var models: [AgentGatewayModelInfo]

  public init(
    protocolVersion: String,
    vendor: String,
    models: [AgentGatewayModelInfo]
  ) {
    self.protocolVersion = protocolVersion
    self.vendor = vendor
    self.models = models
  }
}

/// Process adapter for agent-gateway's model-listing command. Listing needs a
/// configured vendor and credential route, but deliberately does not require a
/// selected model so callers can use the catalog to choose one.
public struct AgentGatewayCLIModelCatalog: Sendable {
  public var commandPath: String?
  public var vendor: String
  public var apiKeyEnvironment: String?
  public var environment: [String: String]

  public init(
    commandPath: String? = nil,
    vendor: String,
    apiKeyEnvironment: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.commandPath = commandPath
    self.vendor = vendor
    self.apiKeyEnvironment = apiKeyEnvironment
    self.environment = environment
  }

  public func models() async throws -> AgentGatewayModelCatalogResult {
    let binary = try AgentGatewayCLIInvoker.resolveBinary(
      commandPath: commandPath,
      environment: environment
    )
    var arguments = ["models", "--vendor", vendor]
    if let apiKeyEnvironment, !apiKeyEnvironment.isEmpty {
      arguments += ["--api-key-environment", apiKeyEnvironment]
    }
    let execution = try await AgentGatewayCLIInvoker.run(
      binary: binary,
      arguments: arguments,
      stdin: Data(),
      environment: environment
    )
    guard execution.exitCode == 0 else {
      let detail = String(data: execution.stderr.suffix(1_000), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if let detail, !detail.isEmpty {
        throw AgentInvocationError.failed(detail)
      }
      throw AgentInvocationError.failed(
        "agent-gateway model listing exited with status \(execution.exitCode)"
      )
    }
    do {
      return try JSONDecoder().decode(AgentGatewayModelCatalogResult.self, from: execution.stdout)
    } catch {
      throw AgentInvocationError.failed(
        "agent-gateway returned an invalid model catalog; version 0.1.2 or newer is required"
      )
    }
  }
}

extension AgentGatewayCLIInvoker: AgentStreamingInvoking {
  /// Streaming invocation: `onChunk` fires for every ACP `agent_message_chunk`
  /// as the gateway emits it, while the final result stays authoritative.
  public func invoke(
    _ request: AgentInvocationRequest,
    onChunk: @escaping @Sendable (String) -> Void
  ) async throws -> AgentInvocationResult {
    try await invokeGateway(request, onChunk: onChunk)
  }
}

/// Accumulates a pipe's bytes off the calling thread so large streams never
/// deadlock the spawned process against a full pipe buffer. When `onLine` is
/// set, complete newline-terminated lines are also surfaced as they arrive
/// (the streaming path's incremental ACP parse).
private final class PipeCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer = Data()
  private var lineBuffer = Data()
  private let handle: FileHandle
  private let onLine: (@Sendable (Data) -> Void)?

  init(handle: FileHandle, onLine: (@Sendable (Data) -> Void)? = nil) {
    self.handle = handle
    self.onLine = onLine
    handle.readabilityHandler = { [weak self] readable in
      let data = readable.availableData
      guard let self else {
        return
      }
      if data.isEmpty {
        readable.readabilityHandler = nil
        return
      }
      self.lock.lock()
      self.buffer.append(data)
      let lines = self.consumeCompleteLinesLocked(appending: data)
      self.lock.unlock()
      for line in lines {
        self.onLine?(line)
      }
    }
  }

  /// Must be called with `lock` held; returns the complete lines the new data
  /// finished, keeping any trailing partial line buffered.
  private func consumeCompleteLinesLocked(appending data: Data) -> [Data] {
    guard onLine != nil else {
      return []
    }
    lineBuffer.append(data)
    var lines: [Data] = []
    while let newlineIndex = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
      let line = lineBuffer.subdata(in: lineBuffer.startIndex..<newlineIndex)
      lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)
      if !line.isEmpty {
        lines.append(line)
      }
    }
    return lines
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
