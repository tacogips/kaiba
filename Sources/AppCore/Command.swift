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
    guard let command = cursor.next() else {
      return usage
    }

    let context = CommandContext(
      noteRoot: resolveNoteRoot(override: noteRootOverride),
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
    case "storage": return try runStorage(context)
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

  public var usage: String {
    """
    Usage: kaiba [--note-root <dir>] <command> ...

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

    Serve:
      serve      [--host <h>] [--port <p>] [--web-root <dir>]
                 [--allow-unauthenticated]
                 # HTTP note API (POST /graphql, /note/register QR auth,
                 # GET /note/events) + web viewer SPA from --web-root

    Storage:
      storage    migrate (<file-id>|--all) --profile <name> --endpoint <url>
                 --region <r> --bucket <b> --access-key-env <VAR>
                 --secret-key-env <VAR> [--key-prefix <prefix>]
      storage    gc [--grace-hours N]   # reclaim unreferenced file content

    Global:
      --note-root <dir>   Note store root (default ~/.kaiba, env KAIBA_NOTE_ROOT)
      --help, --version
    """
  }
}
