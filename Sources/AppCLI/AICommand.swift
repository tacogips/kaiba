import AppCore
import Foundation

/// `kaiba ai` — manual AI operations (`design-docs/specs/ai-agent-integration.md`,
/// AI5). `tag` runs ontology tag extraction synchronously for a note or
/// notebook; `status` reports configuration and runtime availability. Until
/// the agent-gateway adapter lands, `tag` exits with a clear
/// "not configured" error while `status` explains why.
enum AICommand {
  struct Options {
    var noteRoot: String
    var configuration: KaibaConfiguration
    var subcommand: Subcommand
  }

  enum Subcommand {
    case tag(subject: AITagExtractionSubject, dryRun: Bool)
    case translate(TranslateRequest)
    case models(output: Output)
    case search(query: String, notebookId: NotebookID?, limit: Int)
    case status
  }

  enum TranslateRequest {
    case start(
      notebookId: NotebookID,
      targetLanguage: String?,
      provider: String?,
      model: String?,
      title: String?
    )
    /// Resumes a pending/failed translation notebook where it stopped.
    case resume(translationNotebookId: NotebookID, provider: String?, model: String?)
  }

  enum Output: String {
    case text
    case json
  }

  enum AICommandError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case missingValue(String)
    case invalidUsage(String)

    var description: String {
      switch self {
      case .invalidArgument(let argument): return "unknown ai argument: \(argument)"
      case .missingValue(let option): return "missing value for \(option)"
      case .invalidUsage(let message): return message
      }
    }
  }

  static func parse(
    arguments: [String],
    noteRoot: String,
    configuration: KaibaConfiguration
  ) throws -> Options {
    var iterator = arguments.makeIterator()
    guard let subcommand = iterator.next() else {
      throw AICommandError.invalidUsage(
        "ai requires a subcommand: tag (--note <id> | --notebook <id>) [--dry-run] | "
          + "translate (--notebook <id> [--to <language>] | --resume <id>) "
          + "[--provider <vendor>] [--model <model>] [--title <title>] | "
          + "search <query> [--notebook <id>] [--limit N] | "
          + "models [--output text|json] | status"
      )
    }
    switch subcommand {
    case "status":
      if let stray = iterator.next() {
        throw AICommandError.invalidArgument(stray)
      }
      return Options(noteRoot: noteRoot, configuration: configuration, subcommand: .status)
    case "models":
      var output = Output.text
      while let argument = iterator.next() {
        guard argument == "--output" else {
          throw AICommandError.invalidArgument(argument)
        }
        guard let value = iterator.next() else {
          throw AICommandError.missingValue(argument)
        }
        guard let parsed = Output(rawValue: value) else {
          throw AICommandError.invalidUsage("--output expects text or json, got: \(value)")
        }
        output = parsed
      }
      return Options(
        noteRoot: noteRoot,
        configuration: configuration,
        subcommand: .models(output: output)
      )
    case "translate":
      return Options(
        noteRoot: noteRoot,
        configuration: configuration,
        subcommand: .translate(try parseTranslate(&iterator))
      )
    case "search":
      var query: String?
      var notebookId: NotebookID?
      var limit = 20
      while let argument = iterator.next() {
        switch argument {
        case "--notebook":
          guard let value = iterator.next() else {
            throw AICommandError.missingValue(argument)
          }
          notebookId = NotebookID(value)
        case "--limit":
          guard let value = iterator.next(), let parsed = Int(value) else {
            throw AICommandError.missingValue(argument)
          }
          limit = parsed
        default:
          guard !argument.hasPrefix("-"), query == nil else {
            throw AICommandError.invalidArgument(argument)
          }
          query = argument
        }
      }
      guard let query else {
        throw AICommandError.invalidUsage("ai search requires <query>")
      }
      return Options(
        noteRoot: noteRoot,
        configuration: configuration,
        subcommand: .search(query: query, notebookId: notebookId, limit: limit)
      )
    case "tag":
      var noteId: NoteID?
      var notebookId: NotebookID?
      var dryRun = false
      while let argument = iterator.next() {
        switch argument {
        case "--note":
          guard let value = iterator.next() else {
            throw AICommandError.missingValue(argument)
          }
          noteId = NoteID(value)
        case "--notebook":
          guard let value = iterator.next() else {
            throw AICommandError.missingValue(argument)
          }
          notebookId = NotebookID(value)
        case "--dry-run":
          dryRun = true
        default:
          throw AICommandError.invalidArgument(argument)
        }
      }
      let subject: AITagExtractionSubject
      switch (noteId, notebookId) {
      case (let noteId?, nil): subject = .note(noteId)
      case (nil, let notebookId?): subject = .notebook(notebookId)
      default:
        throw AICommandError.invalidUsage(
          "ai tag requires exactly one of --note <id> or --notebook <id>"
        )
      }
      return Options(
        noteRoot: noteRoot,
        configuration: configuration,
        subcommand: .tag(subject: subject, dryRun: dryRun)
      )
    default:
      throw AICommandError.invalidUsage("unknown ai subcommand: \(subcommand)")
    }
  }

  private static func parseTranslate(
    _ iterator: inout IndexingIterator<[String]>
  ) throws -> TranslateRequest {
    var values: [String: String] = [:]
    while let argument = iterator.next() {
      guard ["--notebook", "--resume", "--to", "--provider", "--model", "--title"]
        .contains(argument)
      else {
        throw AICommandError.invalidArgument(argument)
      }
      guard let value = iterator.next() else {
        throw AICommandError.missingValue(argument)
      }
      values[argument] = value
    }
    switch (values["--notebook"], values["--resume"]) {
    case (let notebookId?, nil):
      return .start(
        notebookId: NotebookID(notebookId),
        targetLanguage: values["--to"],
        provider: values["--provider"],
        model: values["--model"],
        title: values["--title"]
      )
    case (nil, let resumeNotebookId?):
      guard values["--to"] == nil, values["--title"] == nil else {
        throw AICommandError.invalidUsage(
          "ai translate --resume does not take --to or --title; the pending "
            + "notebook already records them"
        )
      }
      return .resume(
        translationNotebookId: NotebookID(resumeNotebookId),
        provider: values["--provider"],
        model: values["--model"]
      )
    default:
      throw AICommandError.invalidUsage(
        "ai translate requires exactly one of --notebook <id> or --resume <id>"
      )
    }
  }

  /// Returns (output, exitCode).
  static func run(_ options: Options) async throws -> (String, Int32) {
    let aiConfiguration = options.configuration.ai
    let invoker = AgentInvokerFactory.makeInvoker(configuration: aiConfiguration)
    switch options.subcommand {
    case .status:
      var lines = [
        "backend=\(aiConfiguration?.agent?.backend ?? "(none)")",
        "provider=\(aiConfiguration?.agent?.provider ?? "(default)")",
        "model=\(aiConfiguration?.agent?.model ?? "(default)")",
        "autoTag=\(aiConfiguration?.autoTagEnabled == true ? "on" : "off")",
        "runtime=\(invoker == nil ? "unavailable" : "available")"
      ]
      if invoker == nil {
        lines.append(AgentInvokerFactory.describeAvailability(configuration: aiConfiguration))
      }
      return (lines.joined(separator: "\n"), 0)
    case .models(let output):
      guard let agent = aiConfiguration?.agent else {
        return ("Error: no agent backend configured (ai.agent is absent in config.json)", 1)
      }
      guard agent.backend == KaibaAgentBackendConfiguration.agentGatewayCLIBackend else {
        return ("Error: unknown agent backend \"\(agent.backend)\"", 1)
      }
      guard let vendor = agent.provider, !vendor.isEmpty else {
        return ("Error: ai.agent.provider is not set", 1)
      }
      let catalog = AgentGatewayCLIModelCatalog(
        commandPath: agent.commandPath,
        vendor: vendor,
        apiKeyEnvironment: agent.apiKeyEnvironmentVariable
      )
      do {
        let result = try await catalog.models()
        switch output {
        case .json:
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
          let data = try encoder.encode(result)
          guard let json = String(data: data, encoding: .utf8) else {
            return ("Error: could not encode the agent-gateway model catalog", 1)
          }
          return (json, 0)
        case .text:
          if result.models.isEmpty {
            return ("no models available for \(result.vendor)", 0)
          }
          return (result.models.map(Self.describeModel).joined(separator: "\n"), 0)
        }
      } catch AgentInvocationError.unavailable(let message) {
        return ("Error: \(message)", 1)
      } catch AgentInvocationError.failed(let message) {
        return ("Error: \(message)", 1)
      } catch {
        return ("Error: agent-gateway model listing failed: \(error)", 1)
      }
    case .translate(let request):
      guard let invoker else {
        return (
          "Error: "
            + AgentInvokerFactory.describeAvailability(configuration: aiConfiguration),
          1
        )
      }
      try FileManager.default.createDirectory(
        atPath: options.noteRoot,
        withIntermediateDirectories: true
      )
      let service = try NoteService(driver: KaibaConfigurationLoader.makeDriver(
        configuration: options.configuration.database,
        noteRoot: options.noteRoot,
        environment: ProcessInfo.processInfo.environment
      ))
      let translateConfiguration = aiConfiguration?.translate
      func translationService(provider: String?, model: String?) -> AITranslationService {
        AITranslationService(
          service: service,
          invoker: invoker,
          provider: provider ?? translateConfiguration?.provider
            ?? aiConfiguration?.agent?.provider,
          model: model ?? translateConfiguration?.model ?? aiConfiguration?.agent?.model
        )
      }
      switch request {
      case .start(let notebookId, let targetLanguage, let provider, let model, let title):
        guard let language = targetLanguage ?? translateConfiguration?.defaultTargetLanguage,
          !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          return (
            "Error: ai translate requires --to <language> "
              + "(or ai.translate.defaultTargetLanguage in config.json)",
            1
          )
        }
        let translation = translationService(provider: provider, model: model)
        let pending = try service.startNotebookTranslation(
          sourceNotebookId: notebookId,
          targetLanguage: language,
          title: title
        )
        do {
          let notebook = try await translation.run(
            translationNotebookId: pending.notebookId
          )
          return (Self.describeTranslation(notebook, service: service), 0)
        } catch {
          return (
            "Error: notebook translation failed: \(error)\n"
              + "resume with: kaiba ai translate --resume \(pending.notebookId)",
            1
          )
        }
      case .resume(let translationNotebookId, let provider, let model):
        let translation = translationService(provider: provider, model: model)
        do {
          let notebook = try await translation.run(
            translationNotebookId: translationNotebookId
          )
          return (Self.describeTranslation(notebook, service: service), 0)
        } catch {
          return (
            "Error: notebook translation failed: \(error)\n"
              + "resume with: kaiba ai translate --resume \(translationNotebookId)",
            1
          )
        }
      }
    case .search(let query, let notebookId, let limit):
      guard let invoker else {
        return (
          "Error: "
            + AgentInvokerFactory.describeAvailability(configuration: aiConfiguration),
          1
        )
      }
      try FileManager.default.createDirectory(
        atPath: options.noteRoot,
        withIntermediateDirectories: true
      )
      let service = try NoteService(driver: KaibaConfigurationLoader.makeDriver(
        configuration: options.configuration.database,
        noteRoot: options.noteRoot,
        environment: ProcessInfo.processInfo.environment
      ))
      let search = AIAgenticSearchService(
        service: service,
        invoker: invoker,
        provider: aiConfiguration?.agent?.provider,
        model: aiConfiguration?.agent?.model
      )
      do {
        let result = try await search.search(query: query, notebookId: notebookId, limit: limit)
        return (result.answerMarkdown, 0)
      } catch {
        return ("Error: agentic search failed: \(error)", 1)
      }
    case .tag(let subject, let dryRun):
      guard let invoker else {
        return (
          "Error: "
            + AgentInvokerFactory.describeAvailability(configuration: aiConfiguration),
          1
        )
      }
      try FileManager.default.createDirectory(
        atPath: options.noteRoot,
        withIntermediateDirectories: true
      )
      let service = try NoteService(driver: KaibaConfigurationLoader.makeDriver(
        configuration: options.configuration.database,
        noteRoot: options.noteRoot,
        environment: ProcessInfo.processInfo.environment
      ))
      let extraction = AITagExtractionService(
        service: service,
        invoker: invoker,
        provider: aiConfiguration?.agent?.provider,
        model: aiConfiguration?.agent?.model
      )
      let result = try await extraction.extractTags(subject: subject, dryRun: dryRun)
      if result.proposals.isEmpty {
        return ("no tags proposed", 0)
      }
      let verb = result.applied ? "applied" : "proposed (dry run)"
      let lines = [verb] + result.proposals.map { proposal in
        var line = "  #\(proposal.name)"
        if let classId = proposal.class {
          line += " [\(classId)]"
        }
        if let parent = proposal.parent {
          line += " parent=\(parent)"
        }
        return line
      }
      return (lines.joined(separator: "\n"), 0)
    }
  }

  private static func describeTranslation(_ notebook: Notebook, service: NoteService) -> String {
    let noteCount = (try? service.listNotes(notebookId: notebook.notebookId, limit: 200, offset: 0))?
      .count
    var lines = [
      "translated notebook: \(notebook.notebookId)",
      "  title: \(notebook.title)"
    ]
    if let noteCount {
      lines.append("  notes: \(noteCount)\(noteCount == 200 ? "+" : "")")
    }
    return lines.joined(separator: "\n")
  }

  private static func describeModel(_ model: AgentGatewayModelInfo) -> String {
    var line = model.modelId
    if let name = model.name, !name.isEmpty, name != model.modelId {
      line += "\t\(name)"
    }
    if let description = model.description, !description.isEmpty {
      line += "\t\(description)"
    }
    return line
  }
}
