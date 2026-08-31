import Foundation

#if os(Linux)
import Glibc
#else
import Darwin
#endif

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
  /// Apply the same hard response limit while collecting ACP stdout as the
  /// chat relay and serving hub. Truncating only after process exit would let
  /// a malicious or hung gateway allocate without bound first.
  static let maximumOutputBytes = AgentReplyOutputLimits.maximumBytes
  /// A gateway is an external process and must never indefinitely hold an
  /// outbox lease or block server startup. Callers may tighten this in tests
  /// or deployment-specific construction.
  public static let defaultInvocationTimeoutNanoseconds: UInt64 = 300_000_000_000
  /// Give well-behaved gateways a short chance to flush and exit after
  /// SIGTERM, then force termination so ignored signals cannot strand work.
  public static let defaultTerminationGraceNanoseconds: UInt64 = 2_000_000_000

  public var commandPath: String?
  /// agent-gateway vendor (claude-code, codex, cursor, openai, anthropic,
  /// gemini, openrouter). Mapped from kaiba's `ai.agent.provider`.
  public var vendor: String
  public var model: String
  /// Environment-variable NAME holding the provider credential; the gateway
  /// falls back to its per-vendor default name when absent.
  public var apiKeyEnvironment: String?
  public var environment: [String: String]
  public var executionMode: AgentGatewayExecutionMode
  public var invocationTimeoutNanoseconds: UInt64
  public var terminationGraceNanoseconds: UInt64

  public init(
    commandPath: String? = nil,
    vendor: String,
    model: String,
    apiKeyEnvironment: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    executionMode: AgentGatewayExecutionMode = .local,
    invocationTimeoutNanoseconds: UInt64 = Self.defaultInvocationTimeoutNanoseconds,
    terminationGraceNanoseconds: UInt64 = Self.defaultTerminationGraceNanoseconds
  ) {
    self.commandPath = commandPath
    self.vendor = vendor
    self.model = model
    self.apiKeyEnvironment = apiKeyEnvironment
    self.environment = environment
    self.executionMode = executionMode
    self.invocationTimeoutNanoseconds = invocationTimeoutNanoseconds
    self.terminationGraceNanoseconds = terminationGraceNanoseconds
  }

  public func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    try await invokeGateway(request, onChunk: nil)
  }

  /// Deliberately not named `invoke`: an overload would make the streaming
  /// conformance below resolve to itself and recurse.
  private func invokeGateway(
    _ request: AgentInvocationRequest,
    onChunk: (@Sendable (String) -> Bool)?
  ) async throws -> AgentInvocationResult {
    do {
      return try await invokeGatewayUnsanitized(request, onChunk: onChunk)
    } catch {
      throw Self.sanitizedInvocationError(error, executionMode: executionMode)
    }
  }

  private func invokeGatewayUnsanitized(
    _ request: AgentInvocationRequest,
    onChunk: (@Sendable (String) -> Bool)?
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
    var lineHandler: (@Sendable (Data) -> Bool)?
    if let onChunk {
      lineHandler = { line in
        if let text = Self.agentMessageChunkText(fromACPLine: line) {
          return onChunk(text)
        }
        return true
      }
    }
    let selectedVendor = request.provider ?? vendor
    let executionContext = try Self.executionContext(
      mode: executionMode,
      vendor: selectedVendor,
      binary: binary,
      arguments: arguments,
      environment: environment,
      apiKeyEnvironment: apiKeyEnvironment
    )
    defer { executionContext.cleanUp() }
    let execution = try await Self.run(
      binary: executionContext.binary,
      arguments: executionContext.arguments,
      stdin: Data(promptText.utf8),
      environment: executionContext.environment,
      onStdoutLine: lineHandler,
      timeoutNanoseconds: invocationTimeoutNanoseconds,
      terminationGraceNanoseconds: terminationGraceNanoseconds,
      workingDirectory: executionContext.workingDirectory
    )
    let parsed = Self.parseACPOutput(execution.stdout)
    if let errorMessage = parsed.errorMessage {
      throw AgentInvocationError.failed(
        Self.sanitizedDiagnostic(errorMessage, executionMode: executionMode)
      )
    }
    guard let reply = parsed.resultText ?? (parsed.streamedText.isEmpty ? nil : parsed.streamedText)
    else {
      let diagnostic: String
      if case .served = executionMode {
        diagnostic = "agent-gateway produced no reply (exit \(execution.exitCode))"
      } else {
        let stderrTail = String(data: execution.stderr.suffix(500), encoding: .utf8) ?? ""
        diagnostic = "agent-gateway produced no reply (exit \(execution.exitCode))"
          + (stderrTail.isEmpty ? "" : ": \(stderrTail.trimmingCharacters(in: .whitespacesAndNewlines))")
      }
      throw AgentInvocationError.failed(diagnostic)
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
    (try? validateAvailability()) != nil
  }

  func validateAvailability(vendor: String? = nil) throws {
    _ = try resolveBinary()
    try Self.validateExecutionRequirements(
      mode: executionMode,
      vendor: vendor ?? self.vendor,
      environment: environment,
      apiKeyEnvironment: apiKeyEnvironment
    )
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
    onStdoutLine: (@Sendable (Data) -> Bool)? = nil,
    timeoutNanoseconds: UInt64 = defaultInvocationTimeoutNanoseconds,
    terminationGraceNanoseconds: UInt64 = defaultTerminationGraceNanoseconds,
    workingDirectory: URL? = nil,
    processGroupPollIntervalWaiter: (@Sendable () async -> Void)? = nil,
    processGroupDescendantStatusInspector: (@Sendable (pid_t) -> ProcessGroupDescendantStatus)? = nil,
    signalObserver: (@Sendable (pid_t, Int32) -> Void)? = nil,
    leaderWaitpidReturnedObserver: (@Sendable () -> Void)? = nil,
    leaderReapedObserver: (@Sendable () -> Void)? = nil
  ) async throws -> Execution {
    let input = Pipe()
    let output = Pipe()
    let errorPipe = Pipe()

    // A deadline closes stdin while the detached writer may still be blocked.
    // macOS pipes otherwise deliver SIGPIPE to the whole server process rather
    // than reporting the closed descriptor to write(2). Linux blocks and
    // consumes SIGPIPE on the detached writer thread below.
    #if os(macOS)
    _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    #endif

    let spawned = try spawnGatewayProcess(
      binary: binary,
      arguments: arguments,
      environment: environment,
      workingDirectory: workingDirectory,
      input: input,
      output: output,
      error: errorPipe,
      processGroupDescendantStatusInspector: processGroupDescendantStatusInspector,
      leaderWaitpidReturnedObserver: leaderWaitpidReturnedObserver,
      leaderReapedObserver: leaderReapedObserver
    )
    let terminator = ProcessTerminator(
      input: input.fileHandleForWriting,
      output: output.fileHandleForReading,
      error: errorPipe.fileHandleForReading,
      processGroupWitness: spawned.processGroupWitness,
      terminationGraceNanoseconds: terminationGraceNanoseconds,
      processGroupPollIntervalWaiter: processGroupPollIntervalWaiter,
      signalObserver: signalObserver
    )
    let stopProcess: @Sendable () -> Void = { terminator.terminateForOutputLimit() }
    let stdoutCollector = PipeCollector(
      handle: output.fileHandleForReading,
      maximumBytes: maximumOutputBytes,
      onLine: onStdoutLine,
      onLimitExceeded: stopProcess
    )
    let stderrCollector = PipeCollector(
      handle: errorPipe.fileHandleForReading,
      maximumBytes: maximumOutputBytes,
      onLimitExceeded: stopProcess
    )
    // FileHandle.write can block when a compromised child stops draining its
    // prompt. Keep that blocking operation off the async caller and make the
    // timeout/cancellation path close the pipe and terminate the child.
    let inputWriter = Task.detached(priority: .utility) {
      defer { try? input.fileHandleForWriting.close() }
      writeGatewayStdin(stdin, to: input.fileHandleForWriting)
    }
    let timeout = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    timeout.schedule(deadline: .now() + .nanoseconds(Int(clamping: timeoutNanoseconds)))
    timeout.setEventHandler {
      terminator.terminateForDeadline()
    }
    timeout.resume()
    let exitCode = await withTaskCancellationHandler(operation: {
      await spawned.completion.wait()
    }, onCancel: {
      terminator.cancel()
    })
    // ProcessCompletion resumes only after waitpid has marked the direct
    // child reaped. All subsequent cleanup must address the process group only.
    inputWriter.cancel()
    if terminator.didExceedDeadline {
      await terminator.terminateRemainingProcessGroup()
      timeout.cancel()
      throw AgentInvocationError.failed("agent-gateway invocation timed out")
    }
    if Task.isCancelled {
      terminator.cancel()
      await terminator.terminateRemainingProcessGroup()
      timeout.cancel()
      throw CancellationError()
    }
    // A helper can close stdout and stderr before the direct gateway exits.
    // Always await witness-backed post-reap cleanup. It never addresses the
    // reaped gateway PID and retains a non-reusable group identity through
    // grace-period escalation.
    await withTaskCancellationHandler(operation: {
      await terminator.terminateRemainingProcessGroup()
    }, onCancel: {
      terminator.cancel()
    })
    if terminator.didExceedDeadline {
      timeout.cancel()
      throw AgentInvocationError.failed("agent-gateway invocation timed out")
    }
    if Task.isCancelled {
      terminator.cancel()
      timeout.cancel()
      throw CancellationError()
    }
    let stdout = stdoutCollector.finish()
    let stderr = stderrCollector.finish()
    timeout.cancel()
    if terminator.didExceedDeadline {
      throw AgentInvocationError.failed("agent-gateway invocation timed out")
    }
    if Task.isCancelled {
      terminator.cancel()
      throw CancellationError()
    }
    guard !stdoutCollector.exceededLimit, !stderrCollector.exceededLimit else {
      throw AgentInvocationError.failed("agent-gateway output exceeds the 256 KiB process limit")
    }
    guard !stdoutCollector.chunkRejected else {
      throw AgentInvocationError.failed("agent reply exceeds the 256 KiB or 256-chunk output limit")
    }
    return Execution(exitCode: exitCode, stdout: stdout, stderr: stderr)
  }

  private struct SpawnedGatewayProcess: Sendable {
    var processIdentifier: pid_t
    var completion: ProcessCompletion
    var reapState: ProcessReapState
    var processGroupWitness: ProcessGroupWitness
  }

  /// Spawn the gateway in its own process group. Provider adapters frequently
  /// spawn helpers; every timeout and cancellation signal must reach that
  /// entire execution tree rather than only the gateway's direct PID.
  private static func spawnGatewayProcess(
    binary: String,
    arguments: [String],
    environment: [String: String],
    workingDirectory: URL?,
    input: Pipe,
    output: Pipe,
    error: Pipe,
    processGroupDescendantStatusInspector: (@Sendable (pid_t) -> ProcessGroupDescendantStatus)?,
    leaderWaitpidReturnedObserver: (@Sendable () -> Void)?,
    leaderReapedObserver: (@Sendable () -> Void)?
  ) throws -> SpawnedGatewayProcess {
    let processGroupWitness = try spawnProcessGroupWitness(
      input: input,
      output: output,
      error: error,
      processGroupDescendantStatusInspector: processGroupDescendantStatusInspector
    )
    do {
      return try spawnGatewayProcessInWitnessedGroup(
        binary: binary,
        arguments: arguments,
        environment: environment,
        workingDirectory: workingDirectory,
        input: input,
        output: output,
        error: error,
        processGroupWitness: processGroupWitness,
        leaderWaitpidReturnedObserver: leaderWaitpidReturnedObserver,
        leaderReapedObserver: leaderReapedObserver
      )
    } catch {
      _ = processGroupWitness.signalOwnedProcessGroup(SIGKILL, signalObserver: nil)
      Task.detached { await processGroupWitness.reapAfterTermination() }
      throw error
    }
  }

  /// The witness deliberately outlives the gateway leader. Holding this direct
  /// child unreaped until cleanup is complete makes its PID a non-reusable
  /// process-group ownership token, including after gateway `waitpid`.
  private static func spawnProcessGroupWitness(
    input: Pipe,
    output: Pipe,
    error: Pipe,
    processGroupDescendantStatusInspector: (@Sendable (pid_t) -> ProcessGroupDescendantStatus)?
  ) throws -> ProcessGroupWitness {
    #if os(macOS)
    var fileActions: posix_spawn_file_actions_t?
    #else
    var fileActions = posix_spawn_file_actions_t()
    #endif
    guard posix_spawn_file_actions_init(&fileActions) == 0 else {
      throw AgentInvocationError.unavailable("agent-gateway could not prepare process-group witness I/O")
    }
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    let descriptors = [
      input.fileHandleForReading.fileDescriptor,
      input.fileHandleForWriting.fileDescriptor,
      output.fileHandleForReading.fileDescriptor,
      output.fileHandleForWriting.fileDescriptor,
      error.fileHandleForReading.fileDescriptor,
      error.fileHandleForWriting.fileDescriptor
    ]
    guard descriptors.allSatisfy({ posix_spawn_file_actions_addclose(&fileActions, $0) == 0 }) else {
      throw AgentInvocationError.unavailable("agent-gateway could not prepare process-group witness I/O")
    }
    #if os(macOS)
    var attributes: posix_spawnattr_t?
    #else
    var attributes = posix_spawnattr_t()
    #endif
    guard posix_spawnattr_init(&attributes) == 0 else {
      throw AgentInvocationError.unavailable("agent-gateway could not prepare process-group witness")
    }
    defer { posix_spawnattr_destroy(&attributes) }
    var defaultSignals = sigset_t()
    sigemptyset(&defaultSignals)
    sigaddset(&defaultSignals, SIGTERM)
    var unblockedSignals = sigset_t()
    sigemptyset(&unblockedSignals)
    let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
    guard posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0,
      posix_spawnattr_setsigmask(&attributes, &unblockedSignals) == 0,
      posix_spawnattr_setflags(&attributes, flags) == 0,
      posix_spawnattr_setpgroup(&attributes, 0) == 0
    else {
      throw AgentInvocationError.unavailable("agent-gateway could not isolate its process group")
    }
    let command = "/bin/sleep"
    let argumentPointers = [strdup("sleep"), strdup("86400")]
    guard argumentPointers.allSatisfy({ $0 != nil }) else {
      argumentPointers.forEach { free($0) }
      throw AgentInvocationError.unavailable("agent-gateway could not prepare process-group witness")
    }
    defer { argumentPointers.forEach { free($0) } }
    var argumentVector: [UnsafeMutablePointer<CChar>?] = argumentPointers + [nil]
    var processIdentifier: pid_t = 0
    let spawnResult = argumentVector.withUnsafeMutableBufferPointer { argumentBuffer in
      posix_spawn(
        &processIdentifier,
        command,
        &fileActions,
        &attributes,
        argumentBuffer.baseAddress,
        environ
      )
    }
    guard spawnResult == 0 else {
      throw AgentInvocationError.unavailable("agent-gateway could not start process-group witness")
    }
    return ProcessGroupWitness(
      processIdentifier: processIdentifier,
      descendantStatusInspector: processGroupDescendantStatusInspector
    )
  }

  private static func spawnGatewayProcessInWitnessedGroup(
    binary: String,
    arguments: [String],
    environment: [String: String],
    workingDirectory: URL?,
    input: Pipe,
    output: Pipe,
    error: Pipe,
    processGroupWitness: ProcessGroupWitness,
    leaderWaitpidReturnedObserver: (@Sendable () -> Void)?,
    leaderReapedObserver: (@Sendable () -> Void)?
  ) throws -> SpawnedGatewayProcess {
    #if os(macOS)
    var fileActions: posix_spawn_file_actions_t?
    #else
    var fileActions = posix_spawn_file_actions_t()
    #endif
    guard posix_spawn_file_actions_init(&fileActions) == 0 else {
      throw AgentInvocationError.unavailable("agent-gateway could not prepare process I/O")
    }
    defer { posix_spawn_file_actions_destroy(&fileActions) }

    let inputRead = input.fileHandleForReading.fileDescriptor
    let inputWrite = input.fileHandleForWriting.fileDescriptor
    let outputRead = output.fileHandleForReading.fileDescriptor
    let outputWrite = output.fileHandleForWriting.fileDescriptor
    let errorRead = error.fileHandleForReading.fileDescriptor
    let errorWrite = error.fileHandleForWriting.fileDescriptor
    let fileActionResults = [
      posix_spawn_file_actions_adddup2(&fileActions, inputRead, STDIN_FILENO),
      posix_spawn_file_actions_adddup2(&fileActions, outputWrite, STDOUT_FILENO),
      posix_spawn_file_actions_adddup2(&fileActions, errorWrite, STDERR_FILENO),
      posix_spawn_file_actions_addclose(&fileActions, inputRead),
      posix_spawn_file_actions_addclose(&fileActions, inputWrite),
      posix_spawn_file_actions_addclose(&fileActions, outputRead),
      posix_spawn_file_actions_addclose(&fileActions, outputWrite),
      posix_spawn_file_actions_addclose(&fileActions, errorRead),
      posix_spawn_file_actions_addclose(&fileActions, errorWrite)
    ]
    guard fileActionResults.allSatisfy({ $0 == 0 }) else {
      throw AgentInvocationError.unavailable("agent-gateway could not prepare process I/O")
    }
    if let workingDirectory {
      let changeDirectoryResult = workingDirectory.path.withCString {
        posix_spawn_file_actions_addchdir_np(&fileActions, $0)
      }
      guard changeDirectoryResult == 0 else {
        throw AgentInvocationError.unavailable("agent-gateway could not isolate its working directory")
      }
    }

    #if os(macOS)
    var attributes: posix_spawnattr_t?
    #else
    var attributes = posix_spawnattr_t()
    #endif
    guard posix_spawnattr_init(&attributes) == 0 else {
      throw AgentInvocationError.unavailable("agent-gateway could not prepare process attributes")
    }
    defer { posix_spawnattr_destroy(&attributes) }
    var defaultSignals = sigset_t()
    sigemptyset(&defaultSignals)
    sigaddset(&defaultSignals, SIGTERM)
    var unblockedSignals = sigset_t()
    sigemptyset(&unblockedSignals)
    let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
    guard posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0,
      posix_spawnattr_setsigmask(&attributes, &unblockedSignals) == 0,
      posix_spawnattr_setflags(&attributes, flags) == 0,
      posix_spawnattr_setpgroup(&attributes, processGroupWitness.processIdentifier) == 0
    else {
      throw AgentInvocationError.unavailable("agent-gateway could not isolate its process group")
    }

    let command = [binary] + arguments
    let commandPointers = command.compactMap { strdup($0) }
    guard commandPointers.count == command.count else {
      throw AgentInvocationError.unavailable("agent-gateway could not prepare command arguments")
    }
    defer { commandPointers.forEach { free($0) } }
    let environmentPointers = environment.compactMap { key, value in strdup("\(key)=\(value)") }
    guard environmentPointers.count == environment.count else {
      throw AgentInvocationError.unavailable("agent-gateway could not prepare environment")
    }
    defer { environmentPointers.forEach { free($0) } }
    var commandVector: [UnsafeMutablePointer<CChar>?] = commandPointers + [nil]
    var environmentVector: [UnsafeMutablePointer<CChar>?] = environmentPointers + [nil]
    var processIdentifier: pid_t = 0
    let spawnResult = commandVector.withUnsafeMutableBufferPointer { commandBuffer in
      environmentVector.withUnsafeMutableBufferPointer { environmentBuffer in
        posix_spawn(
          &processIdentifier,
          binary,
          &fileActions,
          &attributes,
          commandBuffer.baseAddress,
          environmentBuffer.baseAddress
        )
      }
    }
    guard spawnResult == 0 else {
      throw AgentInvocationError.unavailable("agent-gateway could not start: \(binary)")
    }

    // The parent must release the child-only pipe ends; otherwise a descendant
    // that inherits them can prevent EOF and delay the bounded completion path.
    try? input.fileHandleForReading.close()
    try? output.fileHandleForWriting.close()
    try? error.fileHandleForWriting.close()

    let completion = ProcessCompletion()
    let reapState = ProcessReapState(
      completion: completion,
      leaderWaitpidReturnedObserver: leaderWaitpidReturnedObserver,
      leaderReapedObserver: leaderReapedObserver
    )
    let spawnedProcessIdentifier = processIdentifier
    DispatchQueue.global(qos: .utility).async {
      while !reapState.pollForLeaderExit(processIdentifier: spawnedProcessIdentifier) {
        usleep(10_000)
      }
    }
    return SpawnedGatewayProcess(
      processIdentifier: processIdentifier,
      completion: completion,
      reapState: reapState,
      processGroupWitness: processGroupWitness
    )
  }

  private static func writeGatewayStdin(_ data: Data, to handle: FileHandle) {
    #if os(Linux)
    var blockedSignals = sigset_t()
    sigemptyset(&blockedSignals)
    sigaddset(&blockedSignals, SIGPIPE)
    var previousSignals = sigset_t()
    _ = pthread_sigmask(SIG_BLOCK, &blockedSignals, &previousSignals)
    defer {
      var pendingSignals = sigset_t()
      if sigpending(&pendingSignals) == 0, sigismember(&pendingSignals, SIGPIPE) == 1 {
        var receivedSignal: Int32 = 0
        _ = sigwait(&blockedSignals, &receivedSignal)
      }
      _ = pthread_sigmask(SIG_SETMASK, &previousSignals, nil)
    }
    #endif

    data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
      var offset = 0
      while offset < data.count {
        let written = write(handle.fileDescriptor, baseAddress.advanced(by: offset), data.count - offset)
        if written > 0 {
          offset += Int(written)
        } else if written == -1 && errno == EINTR {
          continue
        } else {
          return
        }
      }
    }
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
  public var executionMode: AgentGatewayExecutionMode

  public init(
    commandPath: String? = nil,
    vendor: String,
    apiKeyEnvironment: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    executionMode: AgentGatewayExecutionMode = .local
  ) {
    self.commandPath = commandPath
    self.vendor = vendor
    self.apiKeyEnvironment = apiKeyEnvironment
    self.environment = environment
    self.executionMode = executionMode
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
    let executionContext = try AgentGatewayCLIInvoker.executionContext(
      mode: executionMode,
      vendor: vendor,
      binary: binary,
      arguments: arguments,
      environment: environment,
      apiKeyEnvironment: apiKeyEnvironment
    )
    defer { executionContext.cleanUp() }
    let execution = try await AgentGatewayCLIInvoker.run(
      binary: executionContext.binary,
      arguments: executionContext.arguments,
      stdin: Data(),
      environment: executionContext.environment,
      workingDirectory: executionContext.workingDirectory
    )
    guard execution.exitCode == 0 else {
      if case .served = executionMode {
        throw AgentInvocationError.failed(
          "agent-gateway model listing exited with status \(execution.exitCode)"
        )
      }
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
    onChunk: @escaping @Sendable (String) -> Bool
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
  private let readLock = NSLock()
  private var buffer = Data()
  private var lineBuffer = Data()
  private let handle: FileHandle
  private let descriptor: Int32
  private let maximumBytes: Int
  private let onLine: (@Sendable (Data) -> Bool)?
  private let onLimitExceeded: @Sendable () -> Void
  private var didExceedLimit = false
  private var didRejectChunk = false

  init(
    handle: FileHandle,
    maximumBytes: Int,
    onLine: (@Sendable (Data) -> Bool)? = nil,
    onLimitExceeded: @escaping @Sendable () -> Void = {}
  ) {
    self.handle = handle
    self.descriptor = handle.fileDescriptor
    self.maximumBytes = maximumBytes
    self.onLine = onLine
    self.onLimitExceeded = onLimitExceeded
    handle.readabilityHandler = { [weak self] readable in
      guard let self else {
        return
      }
      self.readLock.lock()
      let data = readable.availableData
      self.readLock.unlock()
      if data.isEmpty {
        readable.readabilityHandler = nil
        return
      }
      self.lock.lock()
      let remainingBytes = max(0, self.maximumBytes - self.buffer.count)
      let accepted = data.prefix(remainingBytes)
      self.buffer.append(accepted)
      let limitExceeded = accepted.count < data.count
      if limitExceeded {
        self.didExceedLimit = true
      }
      let lines = self.consumeCompleteLinesLocked(appending: accepted)
      self.lock.unlock()
      if limitExceeded {
        self.onLimitExceeded()
        return
      }
      for line in lines {
        guard self.onLine?(line) != false else {
          self.lock.lock()
          self.didRejectChunk = true
          self.lock.unlock()
          self.onLimitExceeded()
          return
        }
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

  func finish() -> Data {
    handle.readabilityHandler = nil
    let remaining = drainAvailableBytes()
    if !remaining.isEmpty {
      lock.lock()
      let remainingBytes = max(0, maximumBytes - buffer.count)
      let accepted = remaining.prefix(remainingBytes)
      buffer.append(accepted)
      if accepted.count < remaining.count {
        didExceedLimit = true
      }
      lock.unlock()
    }
    lock.lock()
    defer { lock.unlock() }
    return buffer
  }

  /// Drain only bytes already available from the descriptor. `readToEnd()`
  /// waits for EOF, which a detached gateway descendant can postpone forever
  /// by retaining stdout or stderr after the direct gateway has exited.
  private func drainAvailableBytes() -> Data {
    readLock.lock()
    defer { readLock.unlock() }

    let originalFlags = fcntl(descriptor, F_GETFL)
    guard originalFlags >= 0 else { return Data() }
    guard fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
      return Data()
    }
    defer { _ = fcntl(descriptor, F_SETFL, originalFlags) }

    var result = Data()
    var chunk = [UInt8](repeating: 0, count: 8_192)
    while true {
      let byteCount = chunk.withUnsafeMutableBytes { buffer in
        read(descriptor, buffer.baseAddress, buffer.count)
      }
      if byteCount > 0 {
        result.append(contentsOf: chunk.prefix(Int(byteCount)))
      } else if byteCount == -1, errno == EINTR {
        continue
      } else {
        return result
      }
    }
  }

  var exceededLimit: Bool {
    lock.lock()
    defer { lock.unlock() }
    return didExceedLimit
  }

  var chunkRejected: Bool {
    lock.lock()
    defer { lock.unlock() }
    return didRejectChunk
  }

  /// A post-reap group signal is needed only when a descendant still owns an
  /// output descriptor. `POLLHUP` is a non-consuming EOF check, so it cannot
  /// lose gateway bytes while distinguishing a normal exit from a live helper.
  var hasReachedEOF: Bool {
    var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    guard poll(&descriptorState, 1, 0) > 0 else { return false }
    return (descriptorState.revents & Int16(POLLHUP)) != 0
  }
}
