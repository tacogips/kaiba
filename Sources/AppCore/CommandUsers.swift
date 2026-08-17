import Foundation

// `kaiba user` — the only way an account comes into existence. The store seeds
// its default user on creation (`design-docs/specs/multi-user.md`); everything
// beyond that is explicit, so nobody is signed up by visiting a URL.

extension AppCommand {
  func runUser(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    guard let subcommand = cursor.next() else {
      throw Error.invalidUsage("user requires a subcommand: add|list|disable|enable")
    }
    var subContext = context
    subContext.cursor = cursor
    switch subcommand {
    case "add": return try runUserAdd(subContext)
    case "list": return try runUserList(subContext)
    case "disable": return try runUserDisabled(subContext, disabled: true)
    case "enable": return try runUserDisabled(subContext, disabled: false)
    default:
      throw Error.invalidUsage("unknown user subcommand: \(subcommand)")
    }
  }

  private func runUserAdd(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let email = try cursor.extractOption("--email")
    let name = try cursor.extractOption("--name")
    let output = try cursor.extractOutputMode()
    try cursor.finish()

    guard let email else {
      throw Error.invalidUsage("user add requires --email <address>")
    }
    let service = try makeService(context)
    let user = try service.createUser(email: email, displayName: name ?? email)
    switch output {
    case .json:
      return try renderJSON(userJSON(user))
    case .text:
      return "Added user \(user.userId) (\(user.displayName)) <\(user.email ?? "")>"
    }
  }

  private func runUserList(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let includeDisabled = cursor.extractFlag("--all")
    let output = try cursor.extractOutputMode()
    try cursor.finish()

    let service = try makeService(context)
    let users = try service.listUsers(includeDisabled: includeDisabled)
    switch output {
    case .json:
      return try renderJSON(users.map(userJSON))
    case .text:
      guard !users.isEmpty else {
        return "No users."
      }
      return users.map { user in
        var parts = ["\(user.userId)  \(user.displayName)"]
        if let email = user.email {
          parts.append("<\(email)>")
        }
        if user.isDefault {
          parts.append("[default]")
        }
        if let disabledAt = user.disabledAt {
          parts.append("[disabled \(disabledAt)]")
        }
        return parts.joined(separator: "  ")
      }.joined(separator: "\n")
    }
  }

  private func runUserDisabled(_ context: CommandContext, disabled: Bool) throws -> String {
    var cursor = context.cursor
    guard let userId = cursor.nextIdentifier(as: UserID.self) else {
      throw Error.invalidUsage("user \(disabled ? "disable" : "enable") requires <user-id>")
    }
    try cursor.finish()

    let service = try makeService(context)
    let user = try service.setUserDisabled(userId: userId, disabled: disabled)
    return "\(disabled ? "Disabled" : "Enabled") user \(user.userId) (\(user.displayName))"
  }

  private func userJSON(_ user: NoteUser) -> JSONObject {
    var object: JSONObject = [
      "userId": .id(user.userId),
      "displayName": .string(user.displayName),
      "isDefault": .bool(user.isDefault),
      "createdAt": .string(user.createdAt)
    ]
    object["email"] = user.email.map(JSONValue.string)
    object["disabledAt"] = user.disabledAt.map(JSONValue.string)
    return object
  }
}
