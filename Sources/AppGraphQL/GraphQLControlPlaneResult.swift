import Foundation

/// Shared acceptance envelope carried by every note GraphQL mutation payload.
/// Vendored from riela's control-plane contracts; kaiba keeps only this struct.
public struct GraphQLControlPlaneResult: Codable, Equatable, Sendable {
  public var accepted: Bool
  public var status: String
  public var diagnostics: [String]

  public init(accepted: Bool, status: String, diagnostics: [String] = []) {
    self.accepted = accepted
    self.status = status
    self.diagnostics = diagnostics
  }
}
