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
    /// Bind credential-less requests to the seeded admin account instead of
    /// capping them at the open libraries. Deliberately separate from
    /// `--allow-unauthenticated`: opening a port and handing that port every
    /// library are two decisions (`design-docs/specs/library.md`).
    var unauthenticatedActsAsAdmin = false
  }

  enum ServeError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case missingValue(String)
    case invalidConfiguration(String)

    var description: String {
      switch self {
      case .invalidArgument(let argument): return "unknown serve argument: \(argument)"
      case .missingValue(let option): return "missing value for \(option)"
      case .invalidConfiguration(let message): return message
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
      case "--as-admin":
        options.unauthenticatedActsAsAdmin = true
      default:
        throw ServeError.invalidArgument(argument)
      }
    }
    guard !options.unauthenticatedActsAsAdmin || options.allowUnauthenticated else {
      throw ServeError.invalidConfiguration(
        "--as-admin only applies with --allow-unauthenticated"
      )
    }
    // Serving the store with no authenticator on a routable address exposes
    // every library, the change feed, and `/files` to the network. The spec's
    // Safety rules (design-docs/specs/note-api-auth.md) make this a hard
    // failure, not a warning: the supported way to reach a LAN is an
    // authenticated mode.
    guard !options.allowUnauthenticated || isLoopbackBindHost(options.host) else {
      throw ServeError.invalidConfiguration(
        """
        --allow-unauthenticated requires a loopback --host (127.0.0.0/8, ::1, or \
        localhost); refusing to serve the note store unauthenticated on \(options.host)
        """
      )
    }
    return options
  }

  /// Whether a bind host keeps the server off routable networks. Accepts the
  /// loopback names and the whole IPv4 loopback block, matching what
  /// `--allow-unauthenticated` is allowed to bind.
  static func isLoopbackBindHost(_ host: String) -> Bool {
    let normalized = host.trimmingCharacters(in: .whitespaces).lowercased()
    if normalized == "localhost" || normalized == "::1" || normalized == "[::1]" {
      return true
    }
    let octets = normalized.split(separator: ".", omittingEmptySubsequences: false)
    guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else {
      return false
    }
    return octets[0] == "127"
  }

  static func run(_ options: Options) async throws {
    // AI reconciliation prints operator-facing lines and must run before the
    // port opens; the runtime performs the rest of the bootstrap
    // (design-docs/specs/ai-agent-integration.md,
    // design-docs/specs/macos-menu-bar-app.md).
    let driver = try KaibaConfigurationLoader.makeDriver(
      configuration: options.configuration.database,
      noteRoot: options.noteRoot,
      environment: ProcessInfo.processInfo.environment
    )
    let reconciliationService = try NoteService(driver: driver)
    for line in try AIAutoActionReconciliation.reconcile(
      service: reconciliationService,
      aiConfiguration: options.configuration.ai,
      invokerAvailable: AgentInvokerFactory.makeInvoker(
        configuration: options.configuration.ai,
        environment: ProcessInfo.processInfo.environment,
        executionMode: .served
      ) != nil,
      environment: ProcessInfo.processInfo.environment,
      executionMode: .served
    ) {
      print("ai: \(line)")
    }

    let runtime = KaibaServerRuntime(KaibaServeConfiguration(
      host: options.host,
      port: options.port,
      noteRoot: options.noteRoot,
      configuration: options.configuration,
      webRoot: options.webRoot,
      allowUnauthenticated: options.allowUnauthenticated,
      unauthenticatedActsAsAdmin: options.unauthenticatedActsAsAdmin,
      environment: ProcessInfo.processInfo.environment
    ))
    let info: KaibaServerStartInfo
    do {
      info = try await runtime.start()
    } catch let error as KaibaServerRuntime.RuntimeError {
      // Preserve the CLI's error surface for the one operator-facing case.
      throw ServeError.invalidConfiguration(error.description)
    }
    print("endpoint=\(info.endpoint)")
    print("noteRoot=\(info.noteRoot)")
    if let webRoot = info.webRoot {
      print("webRoot=\(webRoot)")
    }
    switch info.authMode {
    case let .authenticated(registrationURL, qrText):
      print("registrationURL=\(registrationURL)")
      print(qrText)
    case .unauthenticatedAsAdmin:
      print("auth=disabled (--allow-unauthenticated --as-admin)")
      print("actingUser=\(NoteStoreSchema.defaultUserId) (admin, every library)")
    case .unauthenticated:
      print("auth=disabled (--allow-unauthenticated)")
    }
    // The ready lines must reach pipes/log files before the long sleep.
    fflush(stdout)
    do {
      try await Task.sleep(nanoseconds: .max)
    } catch is CancellationError {
      // SIGINT/SIGTERM cancel the entry-point task.
    }
    await runtime.stop()
  }
}
