import Foundation

/// Why the agent is being invoked; lets an adapter pick per-purpose settings
/// (e.g. a cheaper model for tag extraction).
public enum AgentInvocationPurpose: String, Codable, Equatable, Sendable {
  case chat
  case tagExtraction = "tag-extraction"
  case translation
  case search
}

public struct AgentInvocationTurn: Codable, Equatable, Sendable {
  public enum Role: String, Codable, Equatable, Sendable {
    case user
    case assistant
  }

  public var role: Role
  public var markdown: String

  public init(role: Role, markdown: String) {
    self.role = role
    self.markdown = markdown
  }
}

public struct AgentInvocationRequest: Equatable, Sendable {
  public var purpose: AgentInvocationPurpose
  public var systemPrompt: String
  public var turns: [AgentInvocationTurn]
  /// Subject note/notebook markdown supplied as context.
  public var contextMarkdown: String?
  public var provider: String?
  public var model: String?
  /// Whether a runtime that can execute tools may offer them for this
  /// request. Off for note-edit turns, whose reply is a replacement body the
  /// server applies itself (`design-docs/specs/user-agent-tools.md`, UA3).
  /// Runtimes without tools ignore it.
  public var allowsTools: Bool

  public init(
    purpose: AgentInvocationPurpose,
    systemPrompt: String,
    turns: [AgentInvocationTurn],
    contextMarkdown: String? = nil,
    provider: String? = nil,
    model: String? = nil,
    allowsTools: Bool = true
  ) {
    self.purpose = purpose
    self.systemPrompt = systemPrompt
    self.turns = turns
    self.contextMarkdown = contextMarkdown
    self.provider = provider
    self.model = model
    self.allowsTools = allowsTools
  }
}

public struct AgentInvocationResult: Equatable, Sendable {
  public var markdown: String

  public init(markdown: String) {
    self.markdown = markdown
  }
}

public enum AgentInvocationError: Error, Equatable, Sendable {
  /// No agent backend is configured (`ai.agent` absent) or no adapter for the
  /// configured backend is available yet.
  case notConfigured
  /// A backend is configured but cannot run right now (binary missing, ...).
  case unavailable(String)
  case failed(String)
}

/// The agent runtime seam (`design-docs/specs/ai-agent-integration.md`, AI1).
/// No streaming: the HTTP server writes single responses, so results land via
/// persistence plus the change feed. The concrete implementation arrives with
/// the agent-gateway adapter (`impl-plans/active/agent-gateway-adapter.md`).
public protocol AgentInvoking: Sendable {
  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult
}

/// Builds the invoker for the configured backend. Returns nil when no backend
/// is configured, the backend is unknown, required settings are missing, or
/// the gateway binary cannot be found — callers treat nil as "agent
/// unavailable" and `describeAvailability` explains why.
public enum AgentInvokerFactory {
  public static func makeInvoker(
    configuration: KaibaAIConfiguration?,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    executionMode: AgentGatewayExecutionMode = .local
  ) -> (any AgentInvoking)? {
    guard let agent = configuration?.agent,
      agent.backend == KaibaAgentBackendConfiguration.agentGatewayCLIBackend,
      let vendor = agent.provider, !vendor.isEmpty,
      let model = agent.model, !model.isEmpty
    else {
      return nil
    }
    let invoker = AgentGatewayCLIInvoker(
      commandPath: agent.commandPath,
      vendor: vendor,
      model: model,
      apiKeyEnvironment: agent.apiKeyEnvironmentVariable,
      environment: environment,
      executionMode: executionMode
    )
    do {
      try invoker.validateAvailability()
      if let translationVendor = configuration?.translate?.provider,
        !translationVendor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        try invoker.validateAvailability(vendor: translationVendor)
      }
      return invoker
    } catch {
      return nil
    }
  }

  public static func describeAvailability(
    configuration: KaibaAIConfiguration?,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    executionMode: AgentGatewayExecutionMode = .local
  ) -> String {
    guard let agent = configuration?.agent else {
      return "no agent backend configured (ai.agent is absent in config.json)"
    }
    guard agent.backend == KaibaAgentBackendConfiguration.agentGatewayCLIBackend else {
      return "unknown agent backend \"\(agent.backend)\"; the supported backend is "
        + "\"\(KaibaAgentBackendConfiguration.agentGatewayCLIBackend)\""
    }
    guard let vendor = agent.provider, !vendor.isEmpty else {
      return "ai.agent.provider is not set; choose an agent-gateway vendor "
        + "(claude-code, codex, cursor, openai, anthropic, gemini, openrouter)"
    }
    guard let model = agent.model, !model.isEmpty else {
      return "ai.agent.model is not set; agent-gateway requires an explicit model"
    }
    let invoker = AgentGatewayCLIInvoker(
      commandPath: agent.commandPath,
      vendor: vendor,
      model: model,
      apiKeyEnvironment: agent.apiKeyEnvironmentVariable,
      environment: environment,
      executionMode: executionMode
    )
    do {
      let binary = try invoker.resolveBinary()
      try invoker.validateAvailability()
      if let translationVendor = configuration?.translate?.provider,
        !translationVendor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        try invoker.validateAvailability(vendor: translationVendor)
      }
      return "agent-gateway ready at \(binary) (vendor \(vendor), model \(model))"
    } catch AgentInvocationError.unavailable(let message) {
      return message
    } catch {
      return "agent-gateway is unavailable: \(error)"
    }
  }
}
