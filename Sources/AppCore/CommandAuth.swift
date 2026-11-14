import Foundation

// `kaiba auth` — the token side of the account model. A token is what travels
// between processes: the server mints one for the signed-in user, hands it to
// an agent, and the agent runs `kaiba --jwt <token> ...`, so the note the agent
// writes belongs to the person who asked for it rather than to the machine
// account (`design-docs/specs/note-api-auth.md`).

extension AppCommand {
  func runAuth(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    guard let subcommand = cursor.next() else {
      throw Error.invalidUsage("auth requires a subcommand: token|whoami")
    }
    var subContext = context
    subContext.cursor = cursor
    switch subcommand {
    case "token": return try runAuthToken(subContext)
    case "whoami": return try runAuthWhoami(subContext)
    case "login": return try runAuthLogin(subContext)
    default:
      throw Error.invalidUsage("unknown auth subcommand: \(subcommand)")
    }
  }

  private func runAuthLogin(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    guard let action = cursor.next() else {
      throw Error.invalidUsage("auth login requires: request|verify")
    }
    var subContext = context
    subContext.cursor = cursor
    switch action {
    case "request": return try runAuthLoginRequest(subContext)
    case "verify": return try runAuthLoginVerify(subContext)
    default:
      throw Error.invalidUsage("unknown auth login action: \(action)")
    }
  }

  /// Mails a one-time code. The answer never says whether the address has an
  /// account: a login endpoint that does is an account-enumeration oracle.
  private func runAuthLoginRequest(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let email = try cursor.extractOption("--email")
    let sender = try cursor.extractOption("--mail-sender") ?? "log"
    let fromAddress = try cursor.extractOption("--from")
    let commandPath = try cursor.extractOption("--mail-command")
    let output = try cursor.extractOutputMode()
    try cursor.finish()

    guard let email else {
      throw Error.invalidUsage("auth login request requires --email <address>")
    }
    let mailSender: any KaibaMailSending
    switch sender {
    case "log":
      mailSender = LogMailSender()
    case "resend":
      mailSender = ResendGatewayCLIMailSender(
        commandPath: commandPath,
        environment: environment
      )
    default:
      throw Error.invalidUsage("--mail-sender must be log or resend")
    }
    if sender == "resend", fromAddress == nil {
      throw Error.invalidUsage("--mail-sender resend requires --from <address>")
    }

    // Issuing is an operator-side action against the whole store: the requester
    // has no credential yet, which is the point of the flow.
    let service = try makeService(root: context.noteRoot)
    let delivered = try runBlocking {
      try await service.sendEmailLoginCode(
        email: email,
        mailSender: mailSender,
        fromAddress: fromAddress ?? "kaiba@localhost"
      )
    }
    switch output {
    case .json:
      return try renderJSON([
        "email": .string(email),
        "accepted": .bool(true),
        "delivered": .bool(delivered)
      ])
    case .text:
      return "If \(email) has an account, a sign-in code is on its way."
    }
  }

  private func runAuthLoginVerify(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let email = try cursor.extractOption("--email")
    let code = try cursor.extractOption("--code")
    let output = try cursor.extractOutputMode()
    try cursor.finish()

    guard let email, let code else {
      throw Error.invalidUsage("auth login verify requires --email <address> --code <code>")
    }
    let service = try makeService(root: context.noteRoot)
    let token = try service.verifyEmailLoginCode(email: email, code: code)
    switch output {
    case .json:
      return try renderJSON(["email": .string(email), "token": .string(token)])
    case .text:
      return """
        Signed in as \(email).
        \(token)

        Pass it as: kaiba --jwt <token> <command>
        """
    }
  }

  private func runAuthToken(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    guard let action = cursor.next(), action == "issue" else {
      throw Error.invalidUsage("auth token requires: issue --user <user-id>")
    }
    let userId = try cursor.extractIdentifierOption("--user", as: UserID.self)
    let ttlMinutes = try cursor.extractOption("--ttl-minutes")
    let output = try cursor.extractOutputMode()
    try cursor.finish()

    guard let userId else {
      throw Error.invalidUsage("auth token issue requires --user <user-id>")
    }
    let ttlSeconds: Int
    if let ttlMinutes {
      guard let minutes = Int(ttlMinutes), minutes > 0, minutes <= 24 * 60 else {
        throw Error.invalidUsage("--ttl-minutes must be between 1 and 1440")
      }
      ttlSeconds = minutes * 60
    } else {
      ttlSeconds = KaibaJWT.defaultTTLSeconds
    }

    // Token issuance is a store-control operation. Retain --jwt scoping so
    // only an enabled administrator may issue a token for any account.
    let service = try makeService(context)
    let token = try service.issueAuthToken(userId: userId, ttlSeconds: ttlSeconds)
    switch output {
    case .json:
      return try renderJSON([
        "userId": .id(userId),
        "token": .string(token),
        "expiresInSeconds": .integer(Int64(ttlSeconds))
      ])
    case .text:
      return """
      Issued a token for \(userId), valid for \(ttlSeconds / 60) minutes:
      \(token)

      Pass it as: kaiba --jwt <token> <command>
      """
    }
  }

  private func runAuthWhoami(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let output = try cursor.extractOutputMode()
    try cursor.finish()

    let service = try makeService(context)
    let user = try service.actingUserId.flatMap { try service.user(id: $0) }
    switch output {
    case .json:
      return try renderJSON([
        "userId": .optionalID(user?.userId),
        "displayName": .optionalString(user?.displayName),
        "isAdmin": .bool(user?.isAdmin ?? false),
        "scoped": .bool(user != nil)
      ])
    case .text:
      guard let user else {
        return "Unscoped (no --jwt): the whole store is visible."
      }
      let role = user.isAdmin ? " [admin: every library]" : ""
      return "Acting as \(user.userId) (\(user.displayName))\(role)"
    }
  }
}
