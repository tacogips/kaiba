import AppCore
import Foundation

/// `kaiba ai credential` — operator management of personal-agent credentials
/// (`design-docs/specs/user-agent-tools.md`, UA7). The key never travels as
/// an argument: it is read from an environment variable or stdin.
enum AICredentialCommand {
  enum Action: Equatable {
    case set(SetRequest)
    case show
    case clear
    case enable
    case disable
  }

  struct SetRequest: Equatable {
    var provider: UserAgentProvider
    var model: String
    var baseURL: String?
    var keySource: KeySource
  }

  enum KeySource: Equatable {
    case environmentVariable(String)
    case standardInput
  }

  struct Options: Equatable {
    var action: Action
    var userId: UserID?
    var output: AICommand.Output
  }

  static let usage = "ai credential (set --provider <anthropic|openai|openrouter|openai-compatible> "
    + "--model <model> (--api-key-env <NAME> | --api-key-stdin) [--base-url <url>] | show | clear | "
    + "enable | disable) --user <id> [--output text|json]"

  static func parse(_ iterator: inout IndexingIterator<[String]>) throws -> Options {
    guard let verb = iterator.next() else {
      throw AICommand.AICommandError.invalidUsage(usage)
    }
    var provider: UserAgentProvider?
    var model: String?
    var baseURL: String?
    var keySource: KeySource?
    var userId: UserID?
    var output = AICommand.Output.text
    while let argument = iterator.next() {
      switch argument {
      case "--provider":
        let value = try requiredValue(argument, &iterator)
        guard let parsed = UserAgentProvider(rawValue: value) else {
          throw AICommand.AICommandError.invalidUsage(
            "--provider expects one of \(UserAgentProvider.allCases.map(\.rawValue).joined(separator: ", ")); got: \(value)"
          )
        }
        provider = parsed
      case "--model":
        model = try requiredValue(argument, &iterator)
      case "--base-url":
        baseURL = try requiredValue(argument, &iterator)
      case "--api-key-env":
        keySource = .environmentVariable(try requiredValue(argument, &iterator))
      case "--api-key-stdin":
        keySource = .standardInput
      case "--user":
        userId = UserID(try requiredValue(argument, &iterator))
      case "--output":
        let value = try requiredValue(argument, &iterator)
        guard let parsed = AICommand.Output(rawValue: value) else {
          throw AICommand.AICommandError.invalidUsage("--output expects text or json, got: \(value)")
        }
        output = parsed
      default:
        throw AICommand.AICommandError.invalidArgument(argument)
      }
    }
    let action: Action
    switch verb {
    case "set":
      guard let provider, let model, let keySource else {
        throw AICommand.AICommandError.invalidUsage(
          "ai credential set requires --provider, --model, and one of --api-key-env <NAME> or --api-key-stdin"
        )
      }
      action = .set(SetRequest(provider: provider, model: model, baseURL: baseURL, keySource: keySource))
    case "show": action = .show
    case "clear": action = .clear
    case "enable": action = .enable
    case "disable": action = .disable
    default:
      throw AICommand.AICommandError.invalidUsage("unknown ai credential verb: \(verb); \(usage)")
    }
    if verb != "set", provider != nil || model != nil || baseURL != nil || keySource != nil {
      throw AICommand.AICommandError.invalidUsage("ai credential \(verb) takes only --user and --output")
    }
    return Options(action: action, userId: userId, output: output)
  }

  private static func requiredValue(
    _ argument: String,
    _ iterator: inout IndexingIterator<[String]>
  ) throws -> String {
    guard let value = iterator.next() else {
      throw AICommand.AICommandError.missingValue(argument)
    }
    return value
  }

  /// Opens the store for the operator and runs the action, mapping service
  /// errors to the CLI's `Error:` convention. Returns (output, exitCode).
  static func runFromCLI(
    _ options: Options,
    noteRoot: String,
    configuration: KaibaConfiguration
  ) throws -> (String, Int32) {
    try FileManager.default.createDirectory(atPath: noteRoot, withIntermediateDirectories: true)
    let service = try NoteService(driver: KaibaConfigurationLoader.makeDriver(
      configuration: configuration.database,
      noteRoot: noteRoot,
      environment: ProcessInfo.processInfo.environment
    ))
    do {
      return try run(options, service: service, configuration: configuration.ai.resolvedUserAgent)
    } catch let error as NoteServiceError {
      switch error {
      case .invalidInput(let message), .notFound(let message), .conflict(let message),
        .accountUnavailable(let message), .invalidRow(let message), .readOnly(let message),
        .protectedTag(let message):
        return ("Error: \(message)", 1)
      }
    }
  }

  /// Returns (output, exitCode).
  static func run(
    _ options: Options,
    service: NoteService,
    configuration: KaibaUserAgentConfiguration,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    readStandardInput: () -> String = { readAllStandardInput() }
  ) throws -> (String, Int32) {
    guard configuration.isEnabled else {
      return ("Error: personal agents are disabled (ai.userAgent.enabled is false)", 1)
    }
    switch options.action {
    case .set(let request):
      let apiKey: String
      switch request.keySource {
      case .environmentVariable(let name):
        guard let value = environment[name], !value.isEmpty else {
          return ("Error: environment variable \(name) is unset or empty", 1)
        }
        apiKey = value
      case .standardInput:
        apiKey = readStandardInput().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
          return ("Error: no API key was read from stdin", 1)
        }
      }
      let summary = try service.setUserAgentCredential(
        UserAgentCredentialInput(
          provider: request.provider,
          apiKey: apiKey,
          defaultModel: request.model,
          baseURL: request.baseURL,
          enabled: true
        ),
        targetUserId: options.userId,
        customBaseURLAllowed: configuration.customBaseURLAllowed
      )
      return (render(summary, output: options.output), 0)
    case .show:
      guard let summary = try service.userAgentCredentialSummary(targetUserId: options.userId) else {
        return (options.output == .json ? "null" : "no personal agent credential", 0)
      }
      return (render(summary, output: options.output), 0)
    case .clear:
      let removed = try service.clearUserAgentCredential(targetUserId: options.userId)
      switch options.output {
      case .json: return (try JSONValue.object(["removed": .bool(removed)]).encodedString(prettyPrinted: true), 0)
      case .text: return (removed ? "personal agent credential cleared" : "no personal agent credential", 0)
      }
    case .enable, .disable:
      let enabled = options.action == .enable
      guard let summary = try service.setUserAgentCredentialEnabled(enabled, targetUserId: options.userId) else {
        return ("Error: no personal agent credential to \(enabled ? "enable" : "disable")", 1)
      }
      return (render(summary, output: options.output), 0)
    }
  }

  private static func render(_ summary: UserAgentCredentialSummary, output: AICommand.Output) -> String {
    switch output {
    case .json:
      return (try? JSONValue.object(summaryJSON(summary)).encodedString(prettyPrinted: true)) ?? "{}"
    case .text:
      var lines = [
        "provider=\(summary.provider.rawValue)",
        "model=\(summary.defaultModel)",
        "key=****\(summary.keyHint)",
        "enabled=\(summary.enabled ? "yes" : "no")",
        "updatedAt=\(summary.updatedAt)"
      ]
      if let baseURL = summary.baseURL {
        lines.insert("baseURL=\(baseURL)", at: 2)
      }
      return lines.joined(separator: "\n")
    }
  }

  static func summaryJSON(_ summary: UserAgentCredentialSummary) -> JSONObject {
    [
      "provider": .string(summary.provider.rawValue),
      "keyHint": .string(summary.keyHint),
      "baseURL": summary.baseURL.map(JSONValue.string) ?? .null,
      "defaultModel": .string(summary.defaultModel),
      "enabled": .bool(summary.enabled),
      "updatedAt": .string(summary.updatedAt)
    ]
  }

  private static func readAllStandardInput() -> String {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    return String(bytes: data, encoding: .utf8) ?? ""
  }
}
