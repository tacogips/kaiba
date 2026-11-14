import Foundation
import AppCore
import AppGraphQL

public struct NoteAPIAuthenticatedClient: Codable, Equatable, Sendable {
  public var clientId: APIClientID
  public var displayName: String
  /// The account this credential acts as. Requests are scoped to it, so a
  /// credential can never read another user's notebooks.
  public var userId: UserID

  public init(clientId: APIClientID, displayName: String, userId: UserID) {
    self.clientId = clientId
    self.displayName = displayName
    self.userId = userId
  }
}

public enum NoteAPIAuthenticationResult: Equatable, Sendable {
  case accepted(NoteAPIAuthenticatedClient)
  case rejected(ServerResponseDescriptor)
}

public protocol NoteAPIAuthenticating: Sendable {
  func authenticate(
    request: ServerRequestEnvelope,
    context: ServerRequestContext
  ) async -> NoteAPIAuthenticationResult
}

public protocol NoteAPIClientRegistering: Sendable {
  func createRegistrationChallenge(
    request: ServerRequestEnvelope,
    context: ServerRequestContext
  ) async -> ServerResponseDescriptor

  func redeemRegistrationCode(
    request: ServerRequestEnvelope,
    context: ServerRequestContext
  ) async -> ServerResponseDescriptor
}

func noteAPIUnauthorizedResponse(_ message: String) -> ServerResponseDescriptor {
  ServerResponseDescriptor(status: 401, body: [
    "error": .string(message),
    "graphql": .object([
      "errors": .array([.object(["message": .string(message)])])
    ])
  ])
}

func noteAPIUnavailableResponse(_ message: String) -> ServerResponseDescriptor {
  ServerResponseDescriptor(status: 503, body: [
    "error": .string(message),
    "graphql": .object([
      "errors": .array([.object(["message": .string(message)])])
    ])
  ])
}
