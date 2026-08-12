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
    case status
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
        "ai requires a subcommand: tag (--note <id> | --notebook <id>) [--dry-run] | status"
      )
    }
    switch subcommand {
    case "status":
      if let stray = iterator.next() {
        throw AICommandError.invalidArgument(stray)
      }
      return Options(noteRoot: noteRoot, configuration: configuration, subcommand: .status)
    case "tag":
      var noteId: String?
      var notebookId: String?
      var dryRun = false
      while let argument = iterator.next() {
        switch argument {
        case "--note":
          guard let value = iterator.next() else {
            throw AICommandError.missingValue(argument)
          }
          noteId = value
        case "--notebook":
          guard let value = iterator.next() else {
            throw AICommandError.missingValue(argument)
          }
          notebookId = value
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
}
