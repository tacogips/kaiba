import Foundation
#if os(macOS)
import Darwin
#endif

extension AgentGatewayCLIInvoker {
  static func subscriptionHome(environment: [String: String]) -> URL {
    if let home = environment["CODEX_HOME"], !home.isEmpty { return URL(fileURLWithPath: home) }
    return URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory()).appendingPathComponent(".codex")
  }

  static func subscriptionExecutable(environment: [String: String]) throws -> String {
    for directory in (environment["PATH"] ?? "").split(separator: ":") {
      let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("codex").resolvingSymlinksInPath()
      if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.path }
    }
    throw AgentInvocationError.unavailable("Install Codex CLI on the server PATH")
  }

  static func validateSubscriptionRequirements(vendor: String, environment: [String: String]) throws {
    if vendor == "claude-code" {
      try validateClaudeSubscription(environment: environment)
      return
    }
    guard vendor == "codex" else {
      throw AgentInvocationError.unavailable("subscription execution only supports codex")
    }
    _ = try subscriptionExecutable(environment: environment)
    let auth = subscriptionHome(environment: environment).appendingPathComponent("auth.json")
    guard let data = try? Data(contentsOf: auth),
      let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      value["auth_mode"] as? String == "chatgpt", value["tokens"] is [String: Any] else {
      throw AgentInvocationError.unavailable("Run codex login on the server with file-based ChatGPT authentication")
    }
    #if os(macOS)
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
      throw AgentInvocationError.unavailable("server subscription filesystem sandbox is unavailable")
    }
    #else
    throw AgentInvocationError.unavailable("server subscription execution requires the macOS filesystem sandbox")
    #endif
  }

  static func subscriptionExecutionContext(
    vendor: String, binary: String, arguments: [String], environment: [String: String]
  ) throws -> AgentGatewayExecutionContext {
    if vendor == "claude-code" {
      return try claudeSubscriptionContext(binary: binary, arguments: arguments, environment: environment)
    }
    try validateSubscriptionRequirements(vendor: vendor, environment: environment)
    let executable = try subscriptionExecutable(environment: environment)
    let temporaryPath = FileManager.default.temporaryDirectory.path
    // URL.resolvingSymlinksInPath can shorten /private/var back to /var on
    // macOS. Seatbelt needs the physical path, including for custom TMPDIRs.
    #if os(macOS)
    guard let resolved = realpath(temporaryPath, nil) else {
      throw AgentInvocationError.unavailable("server subscription temporary directory is unavailable")
    }
    defer { free(resolved) }
    let canonicalTemporaryPath = String(cString: resolved)
    #else
    let canonicalTemporaryPath = temporaryPath
    #endif
    let workspace = URL(fileURLWithPath: canonicalTemporaryPath, isDirectory: true)
      .appendingPathComponent("kaiba-codex-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    do {
      let home = workspace.appendingPathComponent(".codex", isDirectory: true)
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let auth = try Data(contentsOf: subscriptionHome(environment: environment).appendingPathComponent("auth.json"))
      let authURL = home.appendingPathComponent("auth.json")
      try auth.write(to: authURL, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
      let isolatedEnvironment = [
        "HOME": workspace.path, "CODEX_HOME": home.path, "TMPDIR": workspace.path,
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"
      ]
      var invocationArguments = arguments + ["--working-directory", workspace.path, "--executable", executable, "--",
        "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules",
        "--sandbox", "read-only", "-c", "approval_policy=\"never\"", "-c", "web_search=\"disabled\"",
        "-c", "cli_auth_credentials_store=\"file\""
      ]
      for feature in ["shell_tool", "unified_exec", "apps", "hooks", "multi_agent", "skills",
                      "browser_use", "computer_use", "in_app_browser", "code_mode", "code_mode_host"] {
        invocationArguments += ["-c", "features.\(feature)=false"]
      }
      #if os(macOS)
      let profile = servedSandboxProfile(binary: binary, workspace: workspace)
        + "\n(allow file-read-metadata)\n(allow file-lock (subpath \(sandboxLiteral(workspace.path))))"
        + "\n(allow file-read* (subpath \"/private/etc\") (literal \"/private/var/run/resolv.conf\"))"
        + "\n(allow mach-lookup (global-name \"com.apple.trustd\") (global-name \"com.apple.SecurityServer\")"
        + " (global-name \"com.apple.SystemConfiguration.configd\") (global-name \"com.apple.networkd\")"
        + " (global-name \"com.apple.dnssd.service\"))"
        + "\n(allow file-read* (literal \(sandboxLiteral(executable))))"
      return AgentGatewayExecutionContext(
        binary: "/usr/bin/sandbox-exec", arguments: ["-p", profile, binary] + invocationArguments,
        environment: isolatedEnvironment, workingDirectory: workspace, workspace: workspace
      )
      #else
      throw AgentInvocationError.unavailable("server subscription execution requires macOS")
      #endif
    } catch {
      try? FileManager.default.removeItem(at: workspace)
      throw error
    }
  }

  /// Codex CLI does not enumerate models through agent-gateway. Use its local
  /// catalog, never tokens/configuration, and retain the user's explicit default.
  public static func subscriptionModels(defaultModel: String) -> [String] {
    let url = subscriptionHome(environment: ProcessInfo.processInfo.environment).appendingPathComponent("models_cache.json")
    guard let data = try? Data(contentsOf: url), data.count <= 5_000_000,
      let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let models = document["models"] as? [[String: Any]] else { return [defaultModel] }
    let slugs = models.compactMap { $0["slug"] as? String }.filter { !$0.isEmpty && $0.count <= 200 }
    return [defaultModel] + Array(Set(slugs).subtracting([defaultModel])).sorted()
  }
}
