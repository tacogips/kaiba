import Foundation

#if canImport(Security)
import Security
#endif

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
    // Without --user the key belongs to the default account, which is what a
    // single-user store has always been.
    let userId = try cursor.extractIdentifierOption("--user", as: UserID.self)
    let output = try cursor.extractOutputMode()
    guard let name else {
      throw Error.invalidUsage("client issue requires --name <display-name>")
    }
    try cursor.finish()

    let service = try makeService(context)
    let token = try makeAPIKeyToken()
    let client = try service.registerAPIClient(
      displayName: name,
      bearerToken: token,
      userId: userId
    )
    switch output {
    case .json:
      return try renderJSON([
        "clientId": .id(client.clientId),
        "displayName": .string(client.displayName),
        "userId": .id(client.userId),
        "createdAt": .string(client.createdAt),
        "apiKey": .string(token)
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

    let service = try makeService(context)
    let clients = try service.listAPIClients(includeRevoked: includeRevoked)
    switch output {
    case .json:
      return try renderJSON(clients.map { client -> JSONObject in
        var object: JSONObject = [
          "clientId": .id(client.clientId),
          "displayName": .string(client.displayName),
          "userId": .id(client.userId),
          "createdAt": .string(client.createdAt)
        ]
        object["lastSeenAt"] = client.lastSeenAt.map(JSONValue.string)
        object["revokedAt"] = client.revokedAt.map(JSONValue.string)
        return object
      })
    case .text:
      guard !clients.isEmpty else {
        return "No API clients."
      }
      return clients.map { client in
        var parts = ["\(client.clientId)  \(client.displayName)  user \(client.userId)  created \(client.createdAt)"]
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
    guard let clientId = cursor.nextIdentifier(as: APIClientID.self) else {
      throw Error.invalidUsage("client revoke requires <client-id>")
    }
    try cursor.finish()

    let service = try makeService(context)
    let client = try service.revokeAPIClient(clientId: clientId)
    return "Revoked client \(client.clientId) (\(client.displayName))"
  }

  /// 32 bytes of secure randomness, URL-safe base64 without padding.
  func makeAPIKeyToken() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    #if canImport(Security)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
      throw Error.invalidUsage("secure random generation failed (\(status))")
    }
    #else
    for index in bytes.indices {
      bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
    }
    #endif
    return Data(bytes)
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
