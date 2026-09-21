import Foundation
#if os(macOS)
import Darwin
#endif

extension AgentGatewayCLIInvoker {
  static func claudeSubscriptionExecutable(environment: [String: String]) throws -> String {
    for directory in (environment["PATH"] ?? "").split(separator: ":") {
      let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("claude").resolvingSymlinksInPath()
      if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.path }
    }
    throw AgentInvocationError.unavailable("Install Claude Code on the server PATH")
  }

  static func validateClaudeSubscription(environment: [String: String]) throws {
    _ = try claudeSubscriptionExecutable(environment: environment)
    guard let token = environment["CLAUDE_CODE_OAUTH_TOKEN"], !token.isEmpty else {
      throw AgentInvocationError.unavailable("Claude server subscription requires CLAUDE_CODE_OAUTH_TOKEN")
    }
    #if os(macOS)
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
      throw AgentInvocationError.unavailable("Claude subscription sandbox is unavailable")
    }
    #else
    throw AgentInvocationError.unavailable("Claude server subscription requires macOS")
    #endif
  }

  static func claudeSubscriptionContext(
    binary: String, arguments: [String], environment: [String: String]
  ) throws -> AgentGatewayExecutionContext {
    try validateClaudeSubscription(environment: environment)
    #if os(macOS)
    let executable = try claudeSubscriptionExecutable(environment: environment)
    let gateway = URL(fileURLWithPath: binary).resolvingSymlinksInPath().path
    guard let physicalPath = realpath(FileManager.default.temporaryDirectory.path, nil) else {
      throw AgentInvocationError.unavailable("Claude subscription temporary directory unavailable")
    }
    defer { free(physicalPath) }
    let workspace = URL(fileURLWithPath: String(cString: physicalPath), isDirectory: true)
      .appendingPathComponent("kaiba-claude-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let isolated: [String: String] = [
      "HOME": workspace.path, "CLAUDE_CONFIG_DIR": workspace.appendingPathComponent(".claude").path,
      "CLAUDE_CODE_TMPDIR": workspace.path, "XDG_RUNTIME_DIR": workspace.path,
      "TMPDIR": workspace.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
      "CLAUDE_CODE_OAUTH_TOKEN": environment["CLAUDE_CODE_OAUTH_TOKEN"] ?? ""
    ]
    let profile = servedSandboxProfile(binary: gateway, workspace: workspace)
      + "\n(allow file-read-metadata)\n(allow file-lock (subpath \(sandboxLiteral(workspace.path))))"
      + "\n(allow file-read* (subpath \"/private/etc\") (literal \"/private/var/run/resolv.conf\"))"
      + "\n(allow mach-lookup (global-name \"com.apple.trustd\") (global-name \"com.apple.SecurityServer\")"
      + " (global-name \"com.apple.SystemConfiguration.configd\") (global-name \"com.apple.networkd\")"
      + " (global-name \"com.apple.dnssd.service\"))"
      + "\n(allow file-read* (literal \(sandboxLiteral(executable))))"
    return AgentGatewayExecutionContext(
      binary: "/usr/bin/sandbox-exec",
      arguments: ["-p", profile, gateway] + arguments
        + ["--working-directory", workspace.path, "--executable", executable, "--"] + ClaudeImageInput.restrictedArguments,
      environment: isolated, workingDirectory: workspace, workspace: workspace
    )
    #else
    throw AgentInvocationError.unavailable("Claude server subscription requires macOS")
    #endif
  }
}
