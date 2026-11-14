import Foundation

public enum KaibaReadinessStatus: String, Codable, Equatable, Sendable {
  case ready
  case authFailed
  case connectionFailed
  case serverRejected
  case incompatibleResponse
}

public struct KaibaReadinessResult: Codable, Equatable, Sendable {
  public var status: KaibaReadinessStatus
  public var authenticationMode: KaibaAuthenticationMode
  public var endpoint: String
  public var httpStatus: Int?
  public var nextAction: String?

  public init(
    status: KaibaReadinessStatus,
    authenticationMode: KaibaAuthenticationMode,
    endpoint: String,
    httpStatus: Int? = nil,
    nextAction: String? = nil
  ) {
    self.status = status
    self.authenticationMode = authenticationMode
    self.endpoint = endpoint
    self.httpStatus = httpStatus
    self.nextAction = nextAction
  }
}

extension KaibaClient {
  public func probeReadiness() async throws -> KaibaReadinessResult {
    let document = """
    query KaibaClientReadiness {
      kaibaReadiness: notes(limit: 0) { result { accepted status } }
    }
    """
    do {
      let response = try await execute(KaibaGraphQLRequest(document: document))
      let root = response.data.objectValue?["kaibaReadiness"]?.objectValue
      let result = root?["result"]?.objectValue
      guard case let .bool(accepted)? = result?["accepted"] else {
        return readiness(.incompatibleResponse, nextAction: "Verify server compatibility.")
      }
      return accepted
        ? readiness(.ready)
        : readiness(.serverRejected, nextAction: "Inspect server policy and readiness status.")
    } catch let error as CancellationError {
      throw error
    } catch let error as KaibaClientError {
      switch error {
      case let .authFailed(status):
        return readiness(.authFailed, httpStatus: status, nextAction: "Check the configured credential.")
      case .connectionFailed:
        return readiness(.connectionFailed, nextAction: "Check the endpoint and network path.")
      default:
        return readiness(.incompatibleResponse, nextAction: "Verify server compatibility.")
      }
    } catch {
      return readiness(.connectionFailed, nextAction: "Check the endpoint and network path.")
    }
  }

  private func readiness(
    _ status: KaibaReadinessStatus,
    httpStatus: Int? = nil,
    nextAction: String? = nil
  ) -> KaibaReadinessResult {
    KaibaReadinessResult(
      status: status,
      authenticationMode: authentication.mode,
      endpoint: endpoint.diagnosticDescription(authentication: authentication),
      httpStatus: httpStatus,
      nextAction: nextAction
    )
  }
}
