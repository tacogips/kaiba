import Foundation

/// `kaiba search-engine` provides foreground status and synchronization for
/// the configured search engine.
public enum SearchEngineCommand {
  public struct Options: Sendable {
    public let noteRoot: String
    public let configuration: KaibaConfiguration
    public let subcommand: Subcommand
    public let json: Bool

    public init(
      noteRoot: String,
      configuration: KaibaConfiguration,
      subcommand: Subcommand,
      json: Bool
    ) {
      self.noteRoot = noteRoot
      self.configuration = configuration
      self.subcommand = subcommand
      self.json = json
    }
  }

  public enum Subcommand: String, Sendable {
    case status
    case sync
    case reindex
  }

  private enum CommandError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case missingValue(String)
    case invalidOutput(String)
    case missingSubcommand

    var description: String {
      switch self {
      case .invalidArgument(let argument):
        "unknown search-engine argument: \(argument)"
      case .missingValue(let option):
        "missing value for \(option)"
      case .invalidOutput(let value):
        "--output expects json or text, got: \(value)"
      case .missingSubcommand:
        "search-engine requires a subcommand: status|sync|reindex"
      }
    }
  }

  public static func parse(
    arguments: [String],
    noteRoot: String,
    configuration: KaibaConfiguration
  ) throws -> Options {
    guard let first = arguments.first, let subcommand = Subcommand(rawValue: first) else {
      if arguments.isEmpty {
        throw CommandError.missingSubcommand
      }
      throw CommandError.invalidArgument(arguments[0])
    }

    var json = false
    var index = 1
    while index < arguments.count {
      let argument = arguments[index]
      guard argument == "--output" else {
        throw CommandError.invalidArgument(argument)
      }
      guard index + 1 < arguments.count else {
        throw CommandError.missingValue(argument)
      }
      let value = arguments[index + 1]
      guard value == "json" || value == "text" else {
        throw CommandError.invalidOutput(value)
      }
      json = value == "json"
      index += 2
    }

    return Options(
      noteRoot: noteRoot,
      configuration: configuration,
      subcommand: subcommand,
      json: json
    )
  }

  /// Opens and authorizes the store before resolving the effective adapter.
  public static func run(
    _ options: Options,
    environment: [String: String]
  ) async -> (String, Int32) {
    do {
      try FileManager.default.createDirectory(
        atPath: options.noteRoot,
        withIntermediateDirectories: true
      )
      let service = try NoteService(driver: KaibaConfigurationLoader.makeDriver(
        configuration: options.configuration.database,
        noteRoot: options.noteRoot,
        environment: environment
      ))
      try service.requireStoreAdministrator()
      let resolution = try service.resolveSearchEngineSettings(
        configuration: options.configuration.searchEngine,
        environment: environment
      )
      let engine = try service.makeResolvedSearchEngine(
        configuration: options.configuration.searchEngine,
        environment: environment
      )
      guard let engine else { return ("Error: search engine is not configured", 2) }
      let kind: String
      switch resolution {
      case .managedByConfig(let config): kind = config.isEnabled ? config.kind : "none"
      case .store(let settings, _): kind = settings.kind
      case .none: kind = "none"
      }
      return await run(options, environment: environment, engine: engine, kind: kind)
    } catch SearchEngineSettingsError.invalid(let field) {
      return ("Error: invalid search engine settings: \(field)", 2)
    } catch let error as KaibaConfigurationError {
      return ("Error: invalid search engine configuration: \(configurationErrorField(error))", 2)
    } catch {
      return ("Error: invalid search engine configuration", 2)
    }
  }

  /// Test seam that runs the command without constructing a concrete adapter.
  static func run(
    _ options: Options,
    environment: [String: String],
    engine: (any SearchEngine)?
  ) async -> (String, Int32) {
    await run(
      options,
      environment: environment,
      engine: engine,
      kind: options.configuration.searchEngine?.kind ?? SearchEngineFactory.defaultKind
    )
  }

  private static func run(
    _ options: Options,
    environment: [String: String],
    engine: (any SearchEngine)?,
    kind: String
  ) async -> (String, Int32) {
    guard let engine else {
      return ("Error: search engine is not configured", 2)
    }

    do {
      try FileManager.default.createDirectory(
        atPath: options.noteRoot,
        withIntermediateDirectories: true
      )
      let service = try NoteService(driver: KaibaConfigurationLoader.makeDriver(
        configuration: options.configuration.database,
        noteRoot: options.noteRoot,
        environment: environment
      ))
      try service.requireStoreAdministrator()

      switch options.subcommand {
      case .status:
        return await status(options, service: service, engine: engine, kind: kind, environment: environment)
      case .sync, .reindex:
        return await synchronize(options, service: service, engine: engine, environment: environment)
      }
    } catch {
      return ("Error: \(sanitize(String(describing: error), options: options, environment: environment))", 1)
    }
  }

  private static func status(
    _ options: Options,
    service: NoteService,
    engine: any SearchEngine,
    kind: String,
    environment: [String: String]
  ) async -> (String, Int32) {
    var available = false
    var detail = "unavailable"
    do {
      let health = try await engine.health()
      available = health.isAvailable
      detail = health.detail
    } catch {
      detail = String(describing: error)
    }

    do {
      let outbox = try service.searchIndexOutboxStatus()
      let fields: JSONObject = [
        "kind": .string(kind),
        "indexIdentity": .string(engine.indexIdentity),
        "available": .bool(available),
        "healthDetail": .string(detail),
        "activated": .bool(outbox.isActivated),
        "pending": .integer(Int64(outbox.pending)),
        "failing": .integer(Int64(outbox.failing)),
        "due": .integer(Int64(outbox.due)),
        "nextDueAt": outbox.nextDueAt.map(JSONValue.string) ?? .string("-")
      ]
      if options.json {
        guard let output = try? renderJSON(fields) else {
          return ("Error: could not encode search-engine status", 1)
        }
        return (sanitize(output, options: options, environment: environment), 0)
      }
      let text = [
        "kind \(kind)",
        "index-identity \(engine.indexIdentity)",
        "available \(available)",
        "health-detail \(detail)",
        "activated \(outbox.isActivated)",
        "pending \(outbox.pending)",
        "failing \(outbox.failing)",
        "due \(outbox.due)",
        "next-due-at \(outbox.nextDueAt ?? "-")"
      ].joined(separator: "\n")
      return (sanitize(text, options: options, environment: environment), 0)
    } catch {
      return ("Error: \(sanitize(String(describing: error), options: options, environment: environment))", 1)
    }
  }

  private static func synchronize(
    _ options: Options,
    service: NoteService,
    engine: any SearchEngine,
    environment: [String: String]
  ) async -> (String, Int32) {
    do {
      try await engine.ensureIndex()
      let activated = try service.activateSearchEngineSync(indexIdentity: engine.indexIdentity)
      let enqueued: Int?
      if options.subcommand == .reindex {
        enqueued = try service.enqueueAllNotesForSearchEngineSync()
      } else {
        enqueued = nil
      }
      let report = try await SearchIndexSynchronizer(service: service).drainUntilIdle(engine: engine)
      let exitCode: Int32 = report.failed > 0 ? 1 : 0
      if options.json {
        var fields: JSONObject = [
          "activated": .bool(activated),
          "pushed": .integer(Int64(report.pushed)),
          "failed": .integer(Int64(report.failed)),
          "remaining": .integer(Int64(report.remaining))
        ]
        if let enqueued {
          fields["enqueued"] = .integer(Int64(enqueued))
        }
        guard let output = try? renderJSON(fields) else {
          return ("Error: could not encode search-engine sync report", 1)
        }
        return (sanitize(output, options: options, environment: environment), exitCode)
      }
      var values = [
        "activated \(activated)",
        "pushed \(report.pushed)",
        "failed \(report.failed)",
        "remaining \(report.remaining)"
      ]
      if let enqueued {
        values.insert("enqueued \(enqueued)", at: 1)
      }
      return (sanitize(values.joined(separator: " "), options: options, environment: environment), exitCode)
    } catch {
      return ("Error: \(sanitize(String(describing: error), options: options, environment: environment))", 1)
    }
  }

  private static func configurationErrorField(_ error: KaibaConfigurationError) -> String {
    switch error {
    case .invalid(let field):
      field
    case .missingEnvironmentVariable(let name):
      name
    case .unreadable:
      "searchEngine"
    }
  }

  private static func sanitize(
    _ value: String,
    options: Options,
    environment: [String: String]
  ) -> String {
    var result = value
    if let configuration = options.configuration.searchEngine {
      for sensitiveValue in [
        configuration.url,
        configuration.apiKeyEnvironmentVariable.flatMap { environment[$0] },
        configuration.usernameEnvironmentVariable.flatMap { environment[$0] },
        configuration.passwordEnvironmentVariable.flatMap { environment[$0] }
      ].compactMap({ $0 }) where !sensitiveValue.isEmpty {
        result = result.replacingOccurrences(of: sensitiveValue, with: "[redacted]")
      }
    }
    return result
  }
}
