import Foundation

/// Builds the personal-agent runtime for one chat turn
/// (`design-docs/specs/user-agent-tools.md`, UA5). Held by the dispatcher;
/// nil there means the feature is off and every turn uses the gateway.
public struct UserAgentRuntimeFactory: Sendable {
  public var configuration: KaibaUserAgentConfiguration
  let streamer: any AgentHTTPStreaming

  public init(configuration: KaibaUserAgentConfiguration) {
    self.init(configuration: configuration, streamer: URLSessionAgentHTTPStreamer())
  }

  init(configuration: KaibaUserAgentConfiguration, streamer: any AgentHTTPStreaming) {
    self.configuration = configuration
    self.streamer = streamer
  }

  /// Whether `service`'s acting user would be answered by the personal
  /// runtime. Cheaper than `makeInvoker` and builds nothing that holds the
  /// key; the request path uses it to decide whether a turn is answerable.
  func isAvailable(for service: NoteService) -> Bool {
    ((try? enabledCredential(for: service)) ?? nil) != nil
  }

  /// The runtime for `service`'s acting user, or nil when that user has no
  /// enabled credential (or the principal is not an authenticated user).
  func makeInvoker(for service: NoteService) throws -> (any AgentStreamingInvoking)? {
    guard let credential = try enabledCredential(for: service) else {
      return nil
    }
    guard let baseURL = credential.resolvedBaseURL else {
      throw AgentInvocationError.unavailable(
        "personal agent credential for provider \(credential.provider.rawValue) has no endpoint"
      )
    }
    let client: any ToolLoopModelClient
    switch credential.provider.wireFormat {
    case .anthropicMessages:
      client = AnthropicMessagesToolLoopClient(baseURL: baseURL, apiKey: credential.apiKey, streamer: streamer)
    case .openAIChatCompletions:
      client = OpenAIChatCompletionsToolLoopClient(baseURL: baseURL, apiKey: credential.apiKey, streamer: streamer)
    }
    return UserAgentToolLoopRunner(
      client: client,
      tools: KaibaAgentToolbox(service: service),
      model: credential.defaultModel,
      maxToolRounds: configuration.resolvedMaxToolRounds
    )
  }

  private func enabledCredential(for service: NoteService) throws -> UserAgentCredential? {
    guard configuration.isEnabled,
      let userId = service.actingUserId,
      !service.isUnauthenticatedPrincipal,
      let credential = try service.storedUserAgentCredential(userId: userId),
      credential.enabled
    else {
      return nil
    }
    return credential
  }
}

/// Stands in when no runtime can answer a turn, so the chat path records a
/// failed turn with a clear message instead of a bare dispatch failure.
struct UnavailableAgentInvoker: AgentInvoking {
  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    throw AgentInvocationError.unavailable(
      "no agent runtime: configure ai.agent on the server or store a personal agent credential"
    )
  }
}
