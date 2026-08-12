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
    let execution = try await Self.run(
      binary: binary,
      arguments: arguments,
      stdin: Data(promptText.utf8),
      environment: environment
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
      guard let object = (try? JSONSerialization.jsonObject(with: Data(lineData)))
        as? [String: Any]
      else {
        continue
      }
      if let error = object["error"] as? [String: Any] {
        let code = error["code"].map { "\($0)" } ?? "?"
        let message = error["message"] as? String ?? "unknown agent error"
        parsed.errorMessage = "agent error \(code): \(message)"
        continue
      }
      if let params = object["params"] as? [String: Any],
        object["method"] as? String == "session/update",
        let update = params["update"] as? [String: Any],
        update["sessionUpdate"] as? String == "agent_message_chunk",
        let content = update["content"] as? [String: Any],
        let text = content["text"] as? String {
        parsed.streamedText += text
        continue
      }
      if let result = object["result"] as? [String: Any],
        result["stopReason"] != nil,
        let meta = result["_meta"] as? [String: Any],
        let gateway = meta["agentGateway"] as? [String: Any],
        let text = gateway["resultText"] as? String {
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
    environment: [String: String]
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

    let stdoutCollector = PipeCollector(handle: output.fileHandleForReading)
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

/// Accumulates a pipe's bytes off the calling thread so large streams never
/// deadlock the spawned process against a full pipe buffer.
private final class PipeCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer = Data()
  private let handle: FileHandle

  init(handle: FileHandle) {
    self.handle = handle
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
      self.lock.unlock()
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
