import Foundation

public struct AppCommand: Sendable {
  public enum Error: Swift.Error, Equatable, Sendable {
    case unknownArgument(String)
    case unknownCommand(String)
    case missingValue(String)
    case invalidUsage(String)
  }

  public let arguments: [String]
  public let environment: [String: String]

  public init(
    arguments: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.arguments = arguments
    self.environment = environment
  }

  public func run() throws -> String {
    if arguments.contains("--version") {
      return Version.current
    }

    if arguments.isEmpty || arguments.contains("--help") || arguments.contains("-h") {
      return usage
    }

    var cursor = CommandCursor(arguments: arguments)
    let noteRootOverride = try cursor.extractOption("--note-root")
    let configPathOverride = try cursor.extractOption("--config")
    let configPath = resolveConfigPath(override: configPathOverride)
    guard let command = cursor.next() else {
      return usage
    }

    let context = CommandContext(
      noteRoot: resolveNoteRoot(override: noteRootOverride),
      configuration: try KaibaConfigurationLoader.load(
        at: configPath,
        required: configPathOverride != nil || !(environment["KAIBA_CONFIG_PATH"] ?? "").isEmpty
      ),
      cursor: cursor
    )

    switch command {
    case "add": return try runAdd(context)
    case "edit": return try runEdit(context)
    case "show": return try runShow(context)
    case "list": return try runList(context)
    case "search": return try runSearch(context)
    case "tag": return try runTag(context)
    case "tags": return try runTags(context)
    case "classes": return try runClasses(context)
    case "tag-define": return try runTagDefine(context)
    case "class-define": return try runClassDefine(context)
    case "comment": return try runComment(context)
    case "attach": return try runAttach(context)
    case "file": return try runFile(context)
    case "link": return try runLink(context)
    case "readonly": return try runReadOnly(context)
    case "delete": return try runDelete(context)
    case "notebook": return try runNotebook(context)
    case "import": return try runImport(context)
    case "storage": return try runStorage(context)
    case "client": return try runClient(context)
    default:
      if command.hasPrefix("-") {
        throw Error.unknownArgument(command)
      }
      throw Error.unknownCommand(command)
    }
  }

  public func resolveNoteRoot(override: String?) -> String {
    if let override, !override.isEmpty {
      return (override as NSString).expandingTildeInPath
    }
    if let env = environment["KAIBA_NOTE_ROOT"], !env.isEmpty {
      return (env as NSString).expandingTildeInPath
    }
    return (NSHomeDirectory() as NSString).appendingPathComponent(".kaiba")
  }

  public func resolveConfigPath(override: String?) -> String {
    if let override, !override.isEmpty {
      return (override as NSString).expandingTildeInPath
    }
    if let configured = environment["KAIBA_CONFIG_PATH"], !configured.isEmpty {
      return (configured as NSString).expandingTildeInPath
    }
    return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .appendingPathComponent(".config/kaiba/config.json")
      .path
  }

  public var usage: String {
    """
    Usage: kaiba [--note-root <dir>] [--config <path>] <command> ...

    Notes:
      add        [--notebook <id>] [--title <t>] (--body <md>|--body-file <path>|-)
                 [--tag <name>]... [--read-only] [--output json|text]
      edit       <note-id> (--body <md>|--body-file <path>) [--append]
      show       <note-id> [--output json|text]
      list       [--notebook <id>] [--tag <name>]... [--limit N] [--offset N]
      search     <query> [--tag <name>]... [--class <id>] [--include-linked]
                 [--sort created-desc|created-asc|updated-desc|title]
                 [--created-after <iso8601>] [--created-before <iso8601>]
                 [--limit N] [--offset N]
      readonly   <note-id> (--on|--off)
      delete     <note-id>

    Tags and ontology:
      tag        <note-id> (--add <name>... | --remove <name>...)
      tags       [--output json|text]
      classes    [--output json|text]
      tag-define <name> [--class <id>] [--parent <tag-name>]
      class-define <class-id> --label <label> [--description <text>]

    Relations and files:
      comment    <note-id> --body <text>
      link       <from-note-id> <to-note-id> [--kind <kind>]
      attach     <note-id> <file-path> [--role related|embedded|source-page-image]
      file       <file-id> [--out <path>]

    Notebooks:
      notebook   list [--tag <name>]... [--sort <order>] [--created-after <t>]
                 [--created-before <t>] [--limit N] [--offset N]
      notebook   show <notebook-id>
      notebook   create --title <t> [--kind <kind-tag>]
      notebook   delete <notebook-id>
      notebook   progress <notebook-id> <none|progress|done|pending>
      notebook   readonly <notebook-id> (--on|--off)

    Import:
      import     <file-path> [--title <t>] [--kind-tag <tag>]
                 [--output json|text]
                 # convert a document (pdf, docx, pptx, epub, ...) with
                 # AnydocKit, or OCR an image (png, jpeg, gif, webp) with
                 # configured import.ocr agent settings; store one note per
                 # top-level Markdown section with the original attached

    AI (agent runtime arrives with agent-gateway; see kaiba ai status):
      ai tag     (--note <id> | --notebook <id>) [--dry-run]
                 # extract ontology tags with the configured agent
      ai translate (--notebook <id> [--to <language>] | --resume <id>)
                 [--provider <vendor>] [--model <model>] [--title <title>]
                 # translate a notebook into a new notebook; --provider/--model
                 # (or ai.translate in config.json) pick the AI vendor
      ai models  [--output text|json]
                 # list models available from the configured agent-gateway vendor
      ai status  # AI configuration and runtime availability

    Serve and API access:
      serve      [--host <h>] [--port <p>] [--web-root <dir>]
                 [--allow-unauthenticated]
                 # HTTP note API (POST /graphql, /note/register QR auth,
                 # GET /note/events) + web viewer SPA from --web-root
      graphql    (<document>|--file <path>|-) [--variables <json>]
                 [--operation <name>]   # execute GraphQL against the local store
      client     issue --name <n> | list [--all] | revoke <client-id>
                 # API keys accepted as bearer tokens by kaiba serve

    Storage:
      storage    migrate (<file-id>|--all) --profile <name> --endpoint <url>
                 --region <r> --bucket <b> --access-key-env <VAR>
                 --secret-key-env <VAR> [--key-prefix <prefix>]
                 # endpoint/credential options may come from a named config profile
      storage    gc [--grace-hours N]   # reclaim unreferenced file content

    Global:
      --note-root <dir>   Note store root (default ~/.kaiba, env KAIBA_NOTE_ROOT)
      --config <path>     Config file (default ~/.config/kaiba/config.json,
                          env KAIBA_CONFIG_PATH)
      --help, --version
    """
  }
}
