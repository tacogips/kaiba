import Foundation

extension AppCommand {
  func runClient(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    guard let subcommand = cursor.next() else {
      throw Error.invalidUsage("client requires a subcommand: issue|list|revoke")
    }
    var subContext = context
    subContext.cursor = cursor
    switch subcommand {
    case "issue": return try runClientIssue(subContext)
    case "list": return try runClientList(subContext)
    case "revoke": return try runClientRevoke(subContext)
    default:
      throw Error.invalidUsage("unknown client subcommand: \(subcommand)")
    }
  }

  private func runClientIssue(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let name = try cursor.extractOption("--name")
    let output = try cursor.extractOutputMode()
    guard let name else {
      throw Error.invalidUsage("client issue requires --name <display-name>")
    }
    try cursor.finish()

    let service = try makeService(root: context.noteRoot)
    let token = try makeAPIKeyToken()
    let client = try service.registerAPIClient(displayName: name, bearerToken: token)
    switch output {
    case .json:
      return try renderJSON([
        "clientId": client.clientId,
        "displayName": client.displayName,
        "createdAt": client.createdAt,
        "apiKey": token
      ])
    case .text:
      return """
      Issued API key for client \(client.clientId) (\(client.displayName)).
      API key (shown once, store it now):
      \(token)

      Use it as a bearer token: Authorization: Bearer <api-key>
      """
    }
  }

  private func runClientList(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let includeRevoked = cursor.extractFlag("--all")
    let output = try cursor.extractOutputMode()
    try cursor.finish()

    let service = try makeService(root: context.noteRoot)
    let clients = try service.listAPIClients(includeRevoked: includeRevoked)
    switch output {
    case .json:
      return try renderJSON(clients.map { client -> [String: Any] in
        var object: [String: Any] = [
          "clientId": client.clientId,
          "displayName": client.displayName,
          "createdAt": client.createdAt
        ]
        object["lastSeenAt"] = client.lastSeenAt
        object["revokedAt"] = client.revokedAt
        return object
      })
    case .text:
      guard !clients.isEmpty else {
        return "No API clients."
      }
      return clients.map { client in
        var parts = ["\(client.clientId)  \(client.displayName)  created \(client.createdAt)"]
        if let lastSeen = client.lastSeenAt {
          parts.append("last-seen \(lastSeen)")
        }
        if let revoked = client.revokedAt {
          parts.append("[revoked \(revoked)]")
        }
        return parts.joined(separator: "  ")
      }.joined(separator: "\n")
    }
  }

  private func runClientRevoke(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    guard let clientId = cursor.next() else {
      throw Error.invalidUsage("client revoke requires <client-id>")
    }
    try cursor.finish()

    let service = try makeService(root: context.noteRoot)
    let client = try service.revokeAPIClient(clientId: clientId)
    return "Revoked client \(client.clientId) (\(client.displayName))"
  }

  /// 32 bytes of secure randomness, URL-safe base64 without padding.
  func makeAPIKeyToken() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
      throw Error.invalidUsage("secure random generation failed (\(status))")
    }
    return Data(bytes)
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
