import Foundation

/// Selects whether a gateway invocation is a local operator command or work
/// initiated by an HTTP server. Served work receives a deliberately narrow
/// process environment and never permits coding-agent CLI vendors.
public enum AgentGatewayExecutionMode: Sendable {
  case local
  case served
}

struct AgentGatewayExecutionContext {
  var binary: String
  var arguments: [String]
  var environment: [String: String]
  var workingDirectory: URL?
  var workspace: URL?

  func cleanUp() {
    guard let workspace else { return }
    try? FileManager.default.removeItem(at: workspace)
  }
}

extension AgentGatewayCLIInvoker {
  /// These vendor adapters delegate to coding CLIs that can execute tools.
  /// They are safe for an operator's explicit local command, but not for a
  /// server request whose prompt includes user-controlled notes or chat.
  static let servedToolCapableVendors: Set<String> = ["claude-code", "codex", "cursor"]
  /// Values controlled by the served sandbox itself. A credential must not
  /// replace one of these because it would either defeat the sandbox's runtime
  /// configuration or create a duplicate-key trap during environment setup.
  static let servedReservedEnvironmentKeys: Set<String> = [
    "HOME", "TMPDIR", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "PATH", "LANG", "LC_ALL"
  ]

  static func executionContext(
    mode: AgentGatewayExecutionMode,
    vendor: String,
    binary: String,
    arguments: [String],
    environment: [String: String],
    apiKeyEnvironment: String?
  ) throws -> AgentGatewayExecutionContext {
    try validateExecutionRequirements(
      mode: mode,
      vendor: vendor,
      environment: environment,
      apiKeyEnvironment: apiKeyEnvironment
    )
    guard mode == .served else {
      return AgentGatewayExecutionContext(
        binary: binary,
        arguments: arguments,
        environment: environment,
        workingDirectory: nil,
        workspace: nil
      )
    }

    guard let apiKeyEnvironment, let credential = environment[apiKeyEnvironment] else {
      throw AgentInvocationError.unavailable("server agent-gateway credential preflight changed unexpectedly")
    }

    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("kaiba-agent-gateway-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: workspace.appendingPathComponent(".config", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: workspace.appendingPathComponent(".cache", isDirectory: true),
      withIntermediateDirectories: true
    )

    var isolatedEnvironment: [String: String] = [
      "HOME": workspace.path,
      "TMPDIR": workspace.path,
      "XDG_CONFIG_HOME": workspace.appendingPathComponent(".config").path,
      "XDG_CACHE_HOME": workspace.appendingPathComponent(".cache").path
    ]
    // `validateExecutionRequirements` rejects every sandbox-reserved name.
    // Assigning after construction preserves that invariant without relying on
    // a dictionary literal's duplicate-key runtime trap.
    isolatedEnvironment[apiKeyEnvironment] = credential
    if let path = environment["PATH"], !path.isEmpty {
      isolatedEnvironment["PATH"] = path
    }
    if let language = environment["LANG"], !language.isEmpty {
      isolatedEnvironment["LANG"] = language
    }
    if let locale = environment["LC_ALL"], !locale.isEmpty {
      isolatedEnvironment["LC_ALL"] = locale
    }

    #if os(macOS)
    let profile = servedSandboxProfile(binary: binary, workspace: workspace)
    return AgentGatewayExecutionContext(
      binary: "/usr/bin/sandbox-exec",
      arguments: ["-p", profile, binary] + arguments,
      environment: isolatedEnvironment,
      workingDirectory: workspace,
      workspace: workspace
    )
    #else
    try? FileManager.default.removeItem(at: workspace)
    throw AgentInvocationError.unavailable(
      "server agent-gateway execution requires the macOS filesystem sandbox"
    )
    #endif
  }

  /// Checks served-runtime constraints without creating a workspace or launching
  /// a process. Factory availability and startup reconciliation use this so
  /// unavailable served configurations never enable retrying auto-actions.
  static func validateExecutionRequirements(
    mode: AgentGatewayExecutionMode,
    vendor: String,
    environment: [String: String],
    apiKeyEnvironment: String?
  ) throws {
    guard mode == .served else { return }
    let normalizedVendor = vendor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !servedToolCapableVendors.contains(normalizedVendor) else {
      throw AgentInvocationError.unavailable(
        "server agent-gateway execution rejects tool-capable vendor \(normalizedVendor); use a tool-free API vendor"
      )
    }
    guard let apiKeyEnvironment, isValidEnvironmentVariableName(apiKeyEnvironment),
      !servedReservedEnvironmentKeys.contains(apiKeyEnvironment),
      let credential = environment[apiKeyEnvironment], !credential.isEmpty
    else {
      throw AgentInvocationError.unavailable(
        "server agent-gateway execution requires a non-reserved, valid ai.agent.apiKeyEnvironmentVariable"
      )
    }
    #if os(macOS)
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
      throw AgentInvocationError.unavailable("server agent-gateway filesystem sandbox is unavailable")
    }
    #else
    throw AgentInvocationError.unavailable(
      "server agent-gateway execution requires the macOS filesystem sandbox"
    )
    #endif
  }

  static func sanitizedDiagnostic(
    _ diagnostic: String,
    executionMode: AgentGatewayExecutionMode
  ) -> String {
    guard executionMode == .served else { return diagnostic }
    return "agent-gateway request failed"
  }

  private static func isValidEnvironmentVariableName(_ value: String) -> Bool {
    guard let first = value.utf8.first, isEnvironmentNameStart(first) else {
      return false
    }
    return value.utf8.dropFirst().allSatisfy(isEnvironmentNameContinuation)
  }

  private static func isEnvironmentNameStart(_ byte: UInt8) -> Bool {
    byte == 95 || (65...90).contains(byte) || (97...122).contains(byte)
  }

  private static func isEnvironmentNameContinuation(_ byte: UInt8) -> Bool {
    isEnvironmentNameStart(byte) || (48...57).contains(byte)
  }

  #if os(macOS)
  private static func servedSandboxProfile(binary: String, workspace: URL) -> String {
    let binaryPath = URL(fileURLWithPath: binary).standardizedFileURL.path
    let readableDirectories = [
      "/System", "/bin", "/sbin", "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/share",
      "/etc", "/dev", "/private/var/db", workspace.path
    ]
    let readRules = readableDirectories.map { "(allow file-read* (subpath \(sandboxLiteral($0))))" }
      .joined(separator: "\n")
    return """
    (version 1)
    (deny default)
    (import "system.sb")
    (allow process*)
    (allow file-read* (literal \(sandboxLiteral(binaryPath))))
    \(readRules)
    (allow file-write* (subpath \(sandboxLiteral(workspace.path))) (literal \"/dev/null\"))
    (allow network-outbound)
    """
  }

  private static func sandboxLiteral(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
  }
  #endif
}
