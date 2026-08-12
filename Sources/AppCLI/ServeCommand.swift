import AppCore
import AppGraphQL
import AppServer
import Foundation

/// `kaiba serve` — long-running local HTTP server exposing the note GraphQL
/// API (`POST /graphql`), QR client registration (`/note/register`), the
/// long-poll change feed (`GET /note/events`), and, when `--web-root` points
/// at the built viewer, the static SPA.
struct ServeCommand {
  struct Options {
    var host = "127.0.0.1"
    var port = 8787
    var noteRoot: String
    var configuration: KaibaConfiguration
    var webRoot: String?
    var allowUnauthenticated = false
  }

  enum ServeError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case missingValue(String)

    var description: String {
      switch self {
      case .invalidArgument(let argument): return "unknown serve argument: \(argument)"
      case .missingValue(let option): return "missing value for \(option)"
      }
    }
  }

  static func parse(
    arguments: [String],
    noteRoot: String,
    configuration: KaibaConfiguration = KaibaConfiguration()
  ) throws -> Options {
    var options = Options(noteRoot: noteRoot, configuration: configuration)
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--host":
        guard let value = iterator.next() else { throw ServeError.missingValue(argument) }
        options.host = value
      case "--port":
        guard let value = iterator.next(), let port = Int(value) else {
          throw ServeError.missingValue(argument)
        }
        options.port = port
      case "--web-root":
        guard let value = iterator.next() else { throw ServeError.missingValue(argument) }
        options.webRoot = (value as NSString).expandingTildeInPath
      case "--allow-unauthenticated":
        options.allowUnauthenticated = true
      default:
        throw ServeError.invalidArgument(argument)
      }
    }
    return options
  }

  static func run(_ options: Options) async throws {
    try FileManager.default.createDirectory(
      atPath: options.noteRoot,
      withIntermediateDirectories: true
    )
    let changeFeed = NoteChangeFeed()
    let driver = try KaibaConfigurationLoader.makeDriver(
      configuration: options.configuration.database,
      noteRoot: options.noteRoot,
      environment: ProcessInfo.processInfo.environment
    )
    // AI wiring (design-docs/specs/ai-agent-integration.md): the invoker is
    // nil until the agent-gateway adapter lands, so no dispatcher installs and
    // the AI auto-actions stay force-disabled (no outbox buildup). The
    // dispatcher gets its own service value over the same driver; its
    // completion writes carry originatingActionId, so loops are impossible.
    let aiConfiguration = options.configuration.ai
    let invoker = AgentInvokerFactory.makeInvoker(configuration: aiConfiguration)
    var dispatcher: KaibaAutoActionDispatcher?
    if let invoker {
      dispatcher = KaibaAutoActionDispatcher(
        service: try NoteService(driver: driver),
        invoker: invoker,
        provider: aiConfiguration?.agent?.provider,
        model: aiConfiguration?.agent?.model
      )
    }
    let service = try NoteService(
      driver: driver,
      autoActionDispatcher: dispatcher,
      changeObserver: NoteChangeFeedObserver(feed: changeFeed)
    )
    for line in try AIAutoActionReconciliation.reconcile(
      service: service,
      aiConfiguration: aiConfiguration,
      invokerAvailable: invoker != nil
    ) {
      print("ai: \(line)")
    }
    // Startup recovery plus a periodic tick: rows enqueued by other processes
    // (e.g. `kaiba import` while serve is running) stay pending until a
    // retry entry point runs, so the serving process drains them regularly.
    var maintenance: Task<Void, Never>?
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
    defer { maintenance?.cancel() }
    let executor = NoteGraphQLDocumentExecutor(
      service: GraphQLNoteGraphQLService(service: service),
      s3Profiles: try KaibaConfigurationLoader.makeS3Profiles(
        configuration: options.configuration,
        environment: ProcessInfo.processInfo.environment
      )
    )
    let authenticator: QRClientRegistrationAuthenticator? = options.allowUnauthenticated
      ? nil
      : QRClientRegistrationAuthenticator(service: service, registrationScope: "kaiba-serve")
    let routeHandler = DeterministicServerRouteHandler(
      graphQLExecutor: executor,
      noteAPIAuthenticator: authenticator,
      allowUnauthenticatedNoteAPI: options.allowUnauthenticated,
      noteChangeFeed: changeFeed
    )
    let adapter = DeterministicServerHTTPAdapter(
      routeHandler: routeHandler,
      context: ServerRequestContext(serviceName: "kaiba")
    )
    let httpHandler: any KaibaHTTPRouteHandling
    if let webRoot = options.webRoot {
      httpHandler = KaibaStaticSPAHTTPRouter(
        service: adapter,
        webRoot: URL(fileURLWithPath: webRoot, isDirectory: true)
      )
    } else {
      httpHandler = adapter
    }
    let server = KaibaLocalHTTPServer(routeHandler: httpHandler)
    let boundPort = try await server.start(host: options.host, port: options.port)
    let endpoint = "http://\(options.host):\(boundPort)"
    print("endpoint=\(endpoint)")
    print("noteRoot=\(options.noteRoot)")
    if let webRoot = options.webRoot {
      print("webRoot=\(webRoot)")
    }
    if let authenticator {
      let challenge = try await authenticator.createRegistrationChallenge(publicBaseURL: endpoint)
      print("registrationURL=\(challenge.registrationURL)")
      print(challenge.qrText)
    } else {
      print("auth=disabled (--allow-unauthenticated)")
    }
    // The ready lines must reach pipes/log files before the long sleep.
    fflush(stdout)
    do {
      try await Task.sleep(nanoseconds: .max)
    } catch is CancellationError {
      // SIGINT/SIGTERM cancel the entry-point task.
    }
    await server.stop()
  }
}
