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
    // `--jwt` names the account the command acts as. `--jwt-env` keeps the
    // token out of the process table and the shell history, which is how an
    // agent should receive one.
    let authToken = try resolveAuthToken(
      token: try cursor.extractOption("--jwt"),
      environmentVariable: try cursor.extractOption("--jwt-env")
    )
    // `--library` names the set of notebooks the command reads and writes.
    let librarySelection = resolveLibrarySelection(
      override: try cursor.extractOption("--library")
    )
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
      cursor: cursor,
      authToken: authToken,
      librarySelection: librarySelection
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
    case "user": return try runUser(context)
    case "auth": return try runAuth(context)
    case "library": return try runLibrary(context)
    default:
      if command.hasPrefix("-") {
        throw Error.unknownArgument(command)
      }
      throw Error.unknownCommand(command)
    }
  }

  /// Resolves the command's credential from `--jwt` or `--jwt-env`. Passing
  /// both is refused rather than silently preferring one, because two options
  /// naming different accounts is a mistake worth surfacing.
  func resolveAuthToken(token: String?, environmentVariable: String?) throws -> String? {
    if token != nil, environmentVariable != nil {
      throw Error.invalidUsage("--jwt and --jwt-env cannot be combined")
    }
    if let token {
      let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        throw Error.invalidUsage("--jwt requires a token")
      }
      return trimmed
    }
    guard let environmentVariable else {
      return nil
    }
    guard let value = environment[environmentVariable]?
      .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      throw Error.invalidUsage("\(environmentVariable) is empty or unset")
    }
    return value
  }

  /// The library the command acts in: the explicit flag, then
  /// `KAIBA_LIBRARY`, then nil for the default library
  /// (`design-docs/specs/library.md`).
  public func resolveLibrarySelection(override: String?) -> String? {
    if let override, !override.isEmpty {
      return override
    }
    if let env = environment["KAIBA_LIBRARY"], !env.isEmpty {
      return env
    }
    return nil
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
      search     <query> [--notebook <id>] [--tag <name>]... [--class <id>]
                 [--include-linked] [--memos]
                 [--sort created-desc|created-asc|updated-desc|title]
                 [--created-after <iso8601>] [--created-before <iso8601>]
                 [--limit N] [--offset N]
                 # full-text (grep) search over notes; --notebook scopes to one
                 # notebook, --memos also greps memo text
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
      ai search  <query> [--notebook <id>] [--limit N]
                 # agentic search: the configured agent answers the question,
                 # searching notes and memos with the kaiba CLI (when its
                 # runtime can run commands) plus a built-in grep pass
      ai status  # AI configuration and runtime availability

    Serve and API access:
      serve      [--host <h>] [--port <p>] [--web-root <dir>]
                 [--allow-unauthenticated]
                 # HTTP note API (POST /graphql, /note/register QR auth,
                 # GET /note/events) + web viewer SPA from --web-root
      graphql    (<document>|--file <path>|-) [--variables <json>]
                 [--operation <name>]   # execute GraphQL against the local store
                 [--endpoint <url> [--api-key-env <VAR>]]
                 # send the document to a running kaiba server's POST /graphql
                 # instead; the API key is read from the named env variable
      client     issue --name <n> [--user <user-id>] | list [--all]
                 | revoke <client-id>
                 # API keys accepted as bearer tokens by kaiba serve;
                 # without --user the key acts as the default user

    Users:
      user       add --email <address> [--name <n>] [--output json|text]
      user       list [--all] [--output json|text]
      user       disable <user-id> | enable <user-id>
                 # each user owns their own notebooks; a store is created with
                 # a default user, which unauthenticated requests act as
      auth       token issue --user <user-id> [--ttl-minutes N]
                 [--output json|text]
      auth       whoami [--output json|text]
      auth       login request --email <address>
                 [--mail-sender log|resend] [--from <address>]
                 [--mail-command <path>] [--output json|text]
      auth       login verify --email <address> --code <code>
                 [--output json|text]
                 # passwordless sign-in: a one-time code is mailed to an
                 # address that already has an account, and verifying it
                 # returns a token for --jwt. `resend` delivers through
                 # resend-gateway-writer, which holds the API key.

    Libraries:
      library    list [--output json|text]
      library    show <name> [--output json|text]
      library    create <name> [--title <t>] [--auth required|none]
      library    update <name> [--title <t>] [--auth required|none]
      library    delete <name>          # refuses a non-empty or default library
      library    move <notebook-id> --to <name>
      library    env <name> [--output json|text]
      library    grant <name> --user <user-id> [--role owner|member]
      library    revoke <name> --user <user-id>
      library    members <name> [--output json|text]
                 # a library groups notebooks. --auth decides whether a caller
                 # with no credential may see it at all; grant/revoke decide
                 # which accounts may. An open library needs no grants.
                 # `env` reports the kinko scope and variable names, never a
                 # secret value.

    Storage:
      storage    migrate (<file-id>|--all) --profile <name> --endpoint <url>
                 --region <r> --bucket <b> --access-key-env <VAR>
                 --secret-key-env <VAR> [--key-prefix <prefix>]
                 # endpoint/credential options may come from a named config profile
      storage    gc [--grace-hours N]   # reclaim unreferenced file content

    Global:
      --jwt <token>       Act as the token's user; writes are attributed to it
                          and reads are scoped to it. Without it the command
                          runs unscoped over the whole store.
      --jwt-env <VAR>     Read the token from an environment variable instead,
                          keeping it out of the process table
      --library <name>    Act in one library: writes land in it and reads are
                          filtered to it (env KAIBA_LIBRARY). Without it writes
                          go to the default library.
      --note-root <dir>   Note store root (default ~/.kaiba, env KAIBA_NOTE_ROOT)
      --config <path>     Config file (default ~/.config/kaiba/config.json,
                          env KAIBA_CONFIG_PATH)
      sqlite file         env KAIBA_SQLITE_PATH, else config database.path,
                          else <note-root>/note-store.sqlite
      --help, --version
    """
  }
}
