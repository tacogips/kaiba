import Foundation

/// Delivers mail by spawning `resend-gateway-writer emails send`, mirroring the
/// `agent-gateway` and AnydocKit adapters: kaiba keeps zero SwiftPM
/// dependencies, and the API key stays in the gateway's own resolution chain
/// (explicit key, `RESEND_API_KEY`, then kinko) so it never passes through
/// kaiba's configuration or its logs.
public struct ResendGatewayCLIMailSender: KaibaMailSending {
  public static let defaultBinaryName = "resend-gateway-writer"
  static let maximumOutputBytes = 4 * 1024 * 1024

  public var commandPath: String?
  public var environment: [String: String]

  public init(
    commandPath: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.commandPath = commandPath
    self.environment = environment
  }

  public var isAvailable: Bool {
    (try? resolveBinary()) != nil
  }

  public func send(_ message: KaibaMailMessage) async throws {
    let binary = try resolveBinary()
    var arguments = [
      "emails", "send",
      "--from", message.from,
      "--to", message.to,
      "--subject", message.subject,
      "--text", message.text
    ]
    if let idempotencyKey = message.idempotencyKey {
      arguments += ["--idempotency-key", idempotencyKey]
    }
    let execution = try await run(binary: binary, arguments: arguments)
    guard execution.exitCode == 0 else {
      // The gateway scrubs anything shaped like an API key on its way into an
      // error, so its stderr is safe to surface. Trimmed anyway: a wall of
      // JSON in a CLI error helps nobody.
      let detail = String(data: execution.stderr.suffix(600), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        ?? ""
      throw KaibaMailError.failed(
        "resend-gateway-writer exited with status \(execution.exitCode)"
          + (detail.isEmpty ? "" : ": \(detail)")
      )
    }
  }

  func resolveBinary() throws -> String {
    if let commandPath, !commandPath.isEmpty {
      let expanded = (commandPath as NSString).expandingTildeInPath
      guard FileManager.default.isExecutableFile(atPath: expanded) else {
        throw KaibaMailError.unavailable("resend-gateway-writer not found: \(expanded)")
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
    throw KaibaMailError.unavailable(
      "resend-gateway-writer not found on PATH; install it with `brew install resend-gateway`"
    )
  }

  private func run(binary: String, arguments: [String]) async throws -> (
    exitCode: Int32, stdout: Data, stderr: Data
  ) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    process.environment = environment
    let output = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = output
    process.standardError = errorPipe
    do {
      try process.run()
    } catch {
      throw KaibaMailError.unavailable("resend-gateway-writer could not start: \(binary)")
    }
    // Both pipes are drained concurrently: reading one to EOF while the other
    // fills its buffer would deadlock the child.
    let collected = PipeOutputBox()
    await withTaskGroup(of: Void.self) { group in
      for (handle, isStdout) in [
        (output.fileHandleForReading, true),
        (errorPipe.fileHandleForReading, false)
      ] {
        group.addTask {
          let data = handle.readDataToEndOfFile().prefix(Self.maximumOutputBytes)
          collected.store(Data(data), isStdout: isStdout)
        }
      }
    }
    process.waitUntilExit()
    return (process.terminationStatus, collected.stdout, collected.stderr)
  }
}

private final class PipeOutputBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stdoutData = Data()
  private var stderrData = Data()

  func store(_ data: Data, isStdout: Bool) {
    lock.lock()
    defer { lock.unlock() }
    if isStdout {
      stdoutData = data
    } else {
      stderrData = data
    }
  }

  var stdout: Data {
    lock.lock()
    defer { lock.unlock() }
    return stdoutData
  }

  var stderr: Data {
    lock.lock()
    defer { lock.unlock() }
    return stderrData
  }
}
