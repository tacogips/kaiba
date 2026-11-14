import Foundation

// `kaiba library` — notebooks grouped into named sets, each deciding whether an
// unauthenticated caller may see it. The store seeds a default library on
// creation and every notebook lands there unless one is selected
// (`design-docs/specs/library.md`).

extension AppCommand {
  func runLibrary(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    guard let subcommand = cursor.next() else {
      throw Error.invalidUsage(
        "library requires a subcommand: list|show|create|update|delete|move|env|grant|revoke|members"
      )
    }
    var subContext = context
    subContext.cursor = cursor
    switch subcommand {
    case "list": return try runLibraryList(subContext)
    case "show": return try runLibraryShow(subContext)
    case "create": return try runLibraryCreate(subContext)
    case "update": return try runLibraryUpdate(subContext)
    case "delete": return try runLibraryDelete(subContext)
    case "move": return try runLibraryMove(subContext)
    case "env": return try runLibraryEnv(subContext)
    case "grant": return try runLibraryGrant(subContext)
    case "revoke": return try runLibraryRevoke(subContext)
    case "members": return try runLibraryMembers(subContext)
    default:
      throw Error.invalidUsage("unknown library subcommand: \(subcommand)")
    }
  }

  private func runLibraryList(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let output = try cursor.extractOutputMode()
    try cursor.finish()

    // Deliberately unselected: `library list` reports the catalog of libraries,
    // so a `--library` selection must not narrow it to the selected one.
    let service = try makeService(context).scoped(toLibrary: nil)
    let libraries = try service.listLibraries()
    switch output {
    case .json:
      return try renderJSON(libraries.map(libraryJSON))
    case .text:
      guard !libraries.isEmpty else {
        return "No libraries."
      }
      return libraries.map(renderLibraryLine).joined(separator: "\n")
    }
  }

  private func runLibraryShow(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    guard let name = cursor.next() else {
      throw Error.invalidUsage("library show requires <name>")
    }
    let output = try cursor.extractOutputMode()
    try cursor.finish()

    let service = try makeService(context).scoped(toLibrary: nil)
    guard let library = try visibleLibrary(named: name, in: service) else {
      throw Error.invalidUsage("library not found: \(name)")
    }
    switch output {
    case .json:
      return try renderJSON(libraryJSON(library))
    case .text:
      let count = library.notebookCount.map { "\($0)" } ?? "unknown"
      return """
      \(library.libraryId)  \(library.name)
      title:          \(library.title)
      authRequired:   \(library.authRequired)
      default:        \(library.isDefault)
      notebooks:      \(count)
      created:        \(library.createdAt)
      """
    }
  }

  private func runLibraryCreate(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    guard let name = cursor.next() else {
      throw Error.invalidUsage("library create requires <name>")
    }
    let title = try cursor.extractOption("--title")
    let authRequired = try cursor.extractAuthRequirement() ?? true
    let output = try cursor.extractOutputMode()
    try cursor.finish()

    let service = try makeService(context)
    let library = try service.createLibrary(
      name: name,
      title: title,
      authRequired: authRequired
    )
    switch output {
    case .json:
      return try renderJSON(libraryJSON(library))
    case .text:
      let requirement = library.authRequired ? "authenticated callers only" : "open to anyone"
      return "Created library \(library.name) (\(library.libraryId)): \(requirement)"
    }
  }

  private func runLibraryUpdate(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    guard let name = cursor.next() else {
      throw Error.invalidUsage("library update requires <name>")
    }
    let title = try cursor.extractOption("--title")
    let authRequired = try cursor.extractAuthRequirement()
    let output = try cursor.extractOutputMode()
    try cursor.finish()

    guard title != nil || authRequired != nil else {
      throw Error.invalidUsage("library update requires --title or --auth")
    }
    let service = try makeService(context)
    let library = try service.updateLibrary(
      name: name,
      title: title,
      authRequired: authRequired
    )
    switch output {
    case .json:
      return try renderJSON(libraryJSON(library))
    case .text:
      return "Updated library \(library.name): " + renderLibraryLine(library)
    }
  }

  private func runLibraryDelete(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    guard let name = cursor.next() else {
      throw Error.invalidUsage("library delete requires <name>")
    }
    try cursor.finish()

    let service = try makeService(context)
    try service.deleteLibrary(name: name)
    return "Deleted library \(name)"
  }

  private func runLibraryMove(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    guard let notebookId = cursor.nextIdentifier(as: NotebookID.self) else {
      throw Error.invalidUsage("library move requires <notebook-id> --to <name>")
    }
    let destination = try cursor.extractOption("--to")
    try cursor.finish()

    guard let destination else {
      throw Error.invalidUsage("library move requires --to <name>")
    }
    let service = try makeService(context)
    let library = try service.moveNotebook(notebookId, toLibrary: destination)
    return "Moved \(notebookId) to library \(library.name)"
  }

  /// Reports the credential scope a library reads from, so the operator never
  /// assembles a `kinko --path ... exec -- kaiba --library ...` line by hand.
  /// Values are never printed: this names variables and scopes only.
  private func runLibraryEnv(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    guard let name = cursor.next() else {
      throw Error.invalidUsage("library env requires <name>")
    }
    let output = try cursor.extractOutputMode()
    try cursor.finish()

    let service = try makeService(context).scoped(toLibrary: nil)
    guard let library = try visibleLibrary(named: name, in: service) else {
      throw Error.invalidUsage("library not found: \(name)")
    }
    let binding = context.configuration.libraryBinding(named: library.name)
    let kinkoPath = binding?.kinkoPath ?? "logical:kaiba/\(library.name)"
    let variables = context.configuration.environmentVariableNames(
      forLibrary: library.name
    )
    switch output {
    case .json:
      return try renderJSON([
        "library": .string(library.name),
        "kinkoPath": .string(kinkoPath),
        "storageProfile": .optionalString(binding?.storageProfile),
        "environmentVariables": .strings(variables)
      ])
    case .text:
      let variableLines = variables.isEmpty
        ? "  (none configured)"
        : variables.map { "  \($0)" }.joined(separator: "\n")
      return """
      library:      \(library.name)
      kinko path:   \(kinkoPath)
      storage:      \(binding?.storageProfile ?? "(default)")
      environment variables:
      \(variableLines)

      kinko --path \(kinkoPath) exec -- kaiba --library \(library.name) serve
      """
    }
  }

  private func runLibraryGrant(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    guard let name = cursor.next() else {
      throw Error.invalidUsage("library grant requires <name> --user <user-id>")
    }
    let userId = try cursor.extractIdentifierOption("--user", as: UserID.self)
    let role = try cursor.extractLibraryRole() ?? .member
    let output = try cursor.extractOutputMode()
    try cursor.finish()

    guard let userId else {
      throw Error.invalidUsage("library grant requires --user <user-id>")
    }
    let service = try makeService(context)
    let member = try service.grantLibraryAccess(libraryName: name, userId: userId, role: role)
    switch output {
    case .json:
      return try renderJSON(libraryMemberJSON(member))
    case .text:
      return "Granted \(member.userId) \(member.role.rawValue) access to \(name)"
    }
  }

  private func runLibraryRevoke(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    guard let name = cursor.next() else {
      throw Error.invalidUsage("library revoke requires <name> --user <user-id>")
    }
    let userId = try cursor.extractIdentifierOption("--user", as: UserID.self)
    try cursor.finish()

    guard let userId else {
      throw Error.invalidUsage("library revoke requires --user <user-id>")
    }
    let service = try makeService(context)
    try service.revokeLibraryAccess(libraryName: name, userId: userId)
    return "Revoked \(userId) access to \(name)"
  }

  private func runLibraryMembers(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    guard let name = cursor.next() else {
      throw Error.invalidUsage("library members requires <name>")
    }
    let output = try cursor.extractOutputMode()
    try cursor.finish()

    let service = try makeService(context).scoped(toLibrary: nil)
    let members = try service.listLibraryMembers(libraryName: name)
    switch output {
    case .json:
      return try renderJSON(members.map(libraryMemberJSON))
    case .text:
      guard !members.isEmpty else {
        return "No members. An open library needs none; one that requires auth is reachable only by its members."
      }
      return members.map { member in
        var parts = ["\(member.userId)  \(member.displayName ?? "")"]
        if let email = member.email {
          parts.append("<\(email)>")
        }
        parts.append("[\(member.role.rawValue)]")
        return parts.joined(separator: "  ")
      }.joined(separator: "\n")
    }
  }

  /// Resolves a library by name through the caller's own visibility, so an
  /// unscoped caller cannot confirm that an authenticated library exists by
  /// naming it.
  private func visibleLibrary(named name: String, in service: NoteService) throws -> NoteLibrary? {
    let normalized = try normalizedLibraryName(name)
    return try service.listLibraries().first { $0.name == normalized }
  }
}

extension CommandCursor {
  /// `--role owner|member`. Absent takes the default on grant.
  mutating func extractLibraryRole() throws -> NoteLibraryRole? {
    guard let raw = try extractOption("--role") else {
      return nil
    }
    guard let role = NoteLibraryRole(rawValue: raw) else {
      throw AppCommand.Error.invalidUsage("--role expects owner or member, got: \(raw)")
    }
    return role
  }

  /// `--auth required|none`. Absent returns nil, which leaves the current
  /// setting untouched on update and takes the default on create.
  mutating func extractAuthRequirement() throws -> Bool? {
    guard let raw = try extractOption("--auth") else {
      return nil
    }
    switch raw {
    case "required": return true
    case "none": return false
    default:
      throw AppCommand.Error.invalidUsage("--auth expects required or none, got: \(raw)")
    }
  }
}

func libraryJSON(_ library: NoteLibrary) -> JSONObject {
  var object: JSONObject = [
    "libraryId": .id(library.libraryId),
    "name": .string(library.name),
    "title": .string(library.title),
    "authRequired": .bool(library.authRequired),
    "isDefault": .bool(library.isDefault),
    "createdAt": .string(library.createdAt)
  ]
  object["createdBy"] = library.createdBy.map(JSONValue.id)
  object["notebookCount"] = library.notebookCount.map { .integer(Int64($0)) }
  return object
}

func libraryMemberJSON(_ member: NoteLibraryMember) -> JSONObject {
  var object: JSONObject = [
    "libraryId": .id(member.libraryId),
    "userId": .id(member.userId),
    "role": .string(member.role.rawValue),
    "grantedAt": .string(member.grantedAt)
  ]
  object["displayName"] = member.displayName.map(JSONValue.string)
  object["email"] = member.email.map(JSONValue.string)
  object["grantedBy"] = member.grantedBy.map(JSONValue.id)
  return object
}

func renderLibraryLine(_ library: NoteLibrary) -> String {
  var parts = ["\(library.name)  \(library.title)"]
  parts.append(library.authRequired ? "[auth required]" : "[open]")
  if library.isDefault {
    parts.append("[default]")
  }
  if let count = library.notebookCount {
    parts.append("(\(count) notebooks)")
  }
  return parts.joined(separator: "  ")
}
