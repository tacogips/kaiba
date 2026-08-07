import Foundation
import AppGraphQL

public struct NoteAPIAuthenticatedClient: Codable, Equatable, Sendable {
  public var clientId: String
  public var displayName: String

  public init(clientId: String, displayName: String) {
    self.clientId = clientId
    self.displayName = displayName
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
