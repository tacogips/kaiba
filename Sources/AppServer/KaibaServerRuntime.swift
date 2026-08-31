import AppCore
import AppGraphQL
import Foundation

// The note server bootstrap, shared by `kaiba serve` (AppCLI) and the macOS
// menu-bar app (KaibaApp). It builds the driver, service, AI dispatcher,
// GraphQL executor, authenticator, and route handlers, then owns the running
// `KaibaLocalHTTPServer` and the periodic auto-action maintenance task. The CLI
// prints the returned start info and blocks; the app shows it in a menu and
// stops the runtime on quit (`design-docs/specs/macos-menu-bar-app.md`).

/// Everything the runtime needs to stand a server up. Parsed from CLI flags by
/// `ServeCommand`, or built directly by the app from its own defaults.
public struct KaibaServeConfiguration: Sendable {
  public var host: String
  public var port: Int
  public var noteRoot: String
  public var configuration: KaibaConfiguration
  public var webRoot: String?
  public var allowUnauthenticated: Bool
  public var unauthenticatedActsAsAdmin: Bool
  public var environment: [String: String]

  public init(
    host: String = "127.0.0.1",
    port: Int = 8787,
    noteRoot: String,
    configuration: KaibaConfiguration = KaibaConfiguration(),
    webRoot: String? = nil,
    allowUnauthenticated: Bool = false,
    unauthenticatedActsAsAdmin: Bool = false,
    environment: [String: String] = [:]
  ) {
    self.host = host
    self.port = port
    self.noteRoot = noteRoot
    self.configuration = configuration
    self.webRoot = webRoot
    self.allowUnauthenticated = allowUnauthenticated
    self.unauthenticatedActsAsAdmin = unauthenticatedActsAsAdmin
    self.environment = environment
  }
}

/// What a started server exposes, enough for a caller to print a ready banner
/// or render a status menu without reaching back into the runtime.
public struct KaibaServerStartInfo: Sendable, Equatable {
  public enum AuthMode: Sendable, Equatable {
    /// A bearer token is required; the operator provisions one through the
    /// registration URL / QR code carried here.
    case authenticated(registrationURL: String, qrText: String)
    /// `--allow-unauthenticated`: no credential, capped at the open libraries.
    case unauthenticated
    /// `--allow-unauthenticated --as-admin`: credential-less requests act as
    /// the seeded admin.
    case unauthenticatedAsAdmin
  }

  public var endpoint: String
  public var noteRoot: String
  public var webRoot: String?
  public var authMode: AuthMode
}

/// Owns a running note server. Start once, stop once; `start()` is idempotent
/// in the sense that a second call while running returns the existing info.
public actor KaibaServerRuntime {
  public enum RuntimeError: Error, CustomStringConvertible, Equatable {
    case invalidConfiguration(String)

    public var description: String {
      switch self {
      case let .invalidConfiguration(message): message
      }
    }
  }

  private let config: KaibaServeConfiguration
  private var server: KaibaLocalHTTPServer?
  private var maintenance: Task<Void, Never>?
  private var startInfo: KaibaServerStartInfo?

  public init(_ configuration: KaibaServeConfiguration) {
    self.config = configuration
  }

  public var isRunning: Bool { server != nil }

  public var currentStartInfo: KaibaServerStartInfo? { startInfo }

  /// Builds and starts the server, returning what it exposes. A no-op that
  /// returns the existing info if already running.
  @discardableResult
  public func start() async throws -> KaibaServerStartInfo {
    if let startInfo {
      return startInfo
    }

    try FileManager.default.createDirectory(
      atPath: config.noteRoot,
      withIntermediateDirectories: true
    )
    let changeFeed = NoteChangeFeed()
    let driver = try KaibaConfigurationLoader.makeDriver(
      configuration: config.configuration.database,
      noteRoot: config.noteRoot,
      environment: config.environment
    )
    let aiConfiguration = config.configuration.ai
    let invoker = AgentInvokerFactory.makeInvoker(
      configuration: aiConfiguration,
      environment: config.environment,
      executionMode: .served
    )
    let agentReplyStreamHub = AgentReplyStreamHub()
    var dispatcher: KaibaAutoActionDispatcher?
    if let invoker {
      dispatcher = KaibaAutoActionDispatcher(
        service: try NoteService(driver: driver),
        invoker: invoker,
        provider: aiConfiguration?.agent?.provider,
        model: aiConfiguration?.agent?.model,
        translateProvider: aiConfiguration?.translate?.provider,
        translateModel: aiConfiguration?.translate?.model,
        streamPublisher: AgentReplyStreamHubPublisher(hub: agentReplyStreamHub)
      )
    }
    let service = try NoteService(
      driver: driver,
      autoActionDispatcher: dispatcher,
      changeObserver: NoteChangeFeedObserver(feed: changeFeed)
    )
    // Fail before the port opens: `--as-admin` is only meaningful while the
    // account it binds to is still an enabled admin.
    if config.unauthenticatedActsAsAdmin {
      let account = try service.defaultUser()
      guard account.isAdmin, account.isEnabled else {
        throw RuntimeError.invalidConfiguration(
          """
          --as-admin requires \(NoteStoreSchema.defaultUserId) to be an enabled admin; \
          run `kaiba user grant-admin \(NoteStoreSchema.defaultUserId)` first
          """
        )
      }
    }
    if dispatcher != nil {
      _ = try await service.recoverAndRetryAutoActionDispatches()
      let maintenanceService = service
      maintenance = Task {
        while !Task.isCancelled {
          try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
          if Task.isCancelled {
            return
          }
          _ = try? await maintenanceService.recoverAndRetryAutoActionDispatches()
        }
      }
    }
    let s3Profiles = try KaibaConfigurationLoader.makeS3Profiles(
      configuration: config.configuration,
      environment: config.environment
    )
    let executor = NoteGraphQLDocumentExecutor(
      service: GraphQLNoteGraphQLService(
        service: service,
        agentInvoker: invoker,
        agentProvider: aiConfiguration?.agent?.provider,
        agentModel: aiConfiguration?.agent?.model,
        agentModelCatalog: agentModelCatalog(
          configuration: aiConfiguration,
          environment: config.environment
        )
      ),
      s3Profiles: s3Profiles
    )
    let authenticator: QRClientRegistrationAuthenticator? = config.allowUnauthenticated
      ? nil
      : QRClientRegistrationAuthenticator(service: service, registrationScope: "kaiba-serve")
    let routeHandler = DeterministicServerRouteHandler(
      graphQLExecutor: executor,
      noteAPIAuthenticator: authenticator,
      allowUnauthenticatedNoteAPI: config.allowUnauthenticated,
      unauthenticatedActsAsAdmin: config.unauthenticatedActsAsAdmin,
      noteService: service,
      noteChangeFeed: changeFeed,
      agentReplyStreamHub: agentReplyStreamHub,
      agentTokenIssuer: service
    )
    let adapter = DeterministicServerHTTPAdapter(
      routeHandler: routeHandler,
      context: ServerRequestContext(serviceName: "kaiba")
    )
    let downstream: any KaibaHTTPRouteHandling
    if let webRoot = config.webRoot {
      downstream = KaibaStaticSPAHTTPRouter(
        service: adapter,
        webRoot: URL(fileURLWithPath: webRoot, isDirectory: true)
      )
    } else {
      downstream = adapter
    }
    let httpHandler = KaibaNoteFileHTTPRouter(
      service: downstream,
      noteService: service,
      s3Profiles: s3Profiles,
      authenticator: authenticator,
      allowUnauthenticated: config.allowUnauthenticated,
      unauthenticatedActsAsAdmin: config.unauthenticatedActsAsAdmin
    )
    let server = KaibaLocalHTTPServer(routeHandler: httpHandler)
    let boundPort = try await server.start(host: config.host, port: config.port)
    let endpoint = "http://\(config.host):\(boundPort)"

    let authMode: KaibaServerStartInfo.AuthMode
    if let authenticator {
      let challenge = try await authenticator.createRegistrationChallenge(publicBaseURL: endpoint)
      authMode = .authenticated(
        registrationURL: challenge.registrationURL,
        qrText: challenge.qrText
      )
    } else if config.unauthenticatedActsAsAdmin {
      authMode = .unauthenticatedAsAdmin
    } else {
      authMode = .unauthenticated
    }

    self.server = server
    let info = KaibaServerStartInfo(
      endpoint: endpoint,
      noteRoot: config.noteRoot,
      webRoot: config.webRoot,
      authMode: authMode
    )
    self.startInfo = info
    return info
  }

  /// Stops the server and cancels maintenance. Safe to call when not running.
  public func stop() async {
    maintenance?.cancel()
    maintenance = nil
    await server?.stop()
    server = nil
    startInfo = nil
  }
}

/// The live model catalog closure for the GraphQL service, or nil when no agent
/// provider is configured. Ported from `ServeCommand` so both entry points wire
/// the catalog identically.
private func agentModelCatalog(
  configuration: KaibaAIConfiguration?,
  environment: [String: String]
) -> (@Sendable () async throws -> AgentGatewayModelCatalogResult)? {
  guard let agent = configuration?.agent, let provider = agent.provider, !provider.isEmpty else {
    return nil
  }
  return {
    try await AgentGatewayCLIModelCatalog(
      commandPath: agent.commandPath,
      vendor: provider,
      apiKeyEnvironment: agent.apiKeyEnvironmentVariable,
      environment: environment,
      executionMode: .served
    ).models()
  }
}
