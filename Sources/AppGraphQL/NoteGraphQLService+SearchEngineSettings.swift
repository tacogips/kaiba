import Foundation

import AppCore

public struct GraphQLSearchEngineAdapterDTO: Codable, Equatable, Sendable {
  public var kind: String
  public var displayName: String
  public var authModes: [String]

  public init(adapter: SearchEngineAdapterDescriptor) {
    kind = adapter.kind
    displayName = adapter.displayName
    authModes = adapter.authModes.map(\.rawValue)
  }
}

public struct GraphQLSearchEngineSettingsDTO: Codable, Equatable, Sendable {
  public var managedBy: String
  public var kind: String
  public var url: String?
  public var indexPrefix: String?
  public var authMode: String
  public var username: String?
  public var hasSecret: Bool
  public var verifyTLS: Bool
  public var requestTimeoutSeconds: Int
  public var adapters: [GraphQLSearchEngineAdapterDTO]
  public var active: Bool

  public init(settings: SearchEngineSettingsView) {
    managedBy = settings.managedBy.rawValue
    kind = settings.kind
    url = settings.url
    indexPrefix = settings.indexPrefix
    authMode = settings.authMode.rawValue
    username = settings.username
    hasSecret = settings.hasSecret
    verifyTLS = settings.verifyTLS
    requestTimeoutSeconds = settings.requestTimeoutSeconds
    adapters = settings.adapters.map(GraphQLSearchEngineAdapterDTO.init)
    active = settings.active
  }
}

public struct GraphQLSearchEngineConnectionTestDTO: Codable, Equatable, Sendable {
  public var available: Bool
  public var status: String
  public var detail: String

  public init(result: SearchEngineConnectionTestResult) {
    available = result.available
    status = result.status.rawValue
    detail = result.detail
  }
}

public struct GraphQLSearchEngineSettingsPayload: Codable, Equatable, Sendable {
  public var result: GraphQLControlPlaneResult
  public var value: GraphQLSearchEngineSettingsDTO?
}

public struct GraphQLSearchEngineConnectionTestPayload: Codable, Equatable, Sendable {
  public var result: GraphQLControlPlaneResult
  public var value: GraphQLSearchEngineConnectionTestDTO?
}

public extension GraphQLNoteGraphQLService {
  func searchEngineSettings() -> GraphQLSearchEngineSettingsPayload {
    do {
      return GraphQLSearchEngineSettingsPayload(
        result: .init(accepted: true, status: "ok"),
        value: GraphQLSearchEngineSettingsDTO(settings: try service.searchEngineSettings())
      )
    } catch {
      return GraphQLSearchEngineSettingsPayload(result: searchEngineSettingsResult(for: error), value: nil)
    }
  }

  func updateSearchEngineSettings(
    _ input: GraphQLSearchEngineSettingsInput
  ) async -> GraphQLSearchEngineSettingsPayload {
    do {
      let settings = try await service.updateSearchEngineSettings(input.settingsInput)
      return GraphQLSearchEngineSettingsPayload(
        result: .init(accepted: true, status: "ok"), value: GraphQLSearchEngineSettingsDTO(settings: settings)
      )
    } catch {
      return GraphQLSearchEngineSettingsPayload(result: searchEngineSettingsResult(for: error), value: nil)
    }
  }

  func testSearchEngineConnection(
    _ input: GraphQLSearchEngineSettingsInput
  ) async -> GraphQLSearchEngineConnectionTestPayload {
    do {
      let result = try await service.testSearchEngineConnection(input.settingsInput)
      return GraphQLSearchEngineConnectionTestPayload(
        result: .init(accepted: true, status: "ok"), value: GraphQLSearchEngineConnectionTestDTO(result: result)
      )
    } catch {
      return GraphQLSearchEngineConnectionTestPayload(result: searchEngineSettingsResult(for: error), value: nil)
    }
  }
}

private func searchEngineSettingsResult(for error: Error) -> GraphQLControlPlaneResult {
  switch error {
  case SearchEngineSettingsError.managedByConfig:
    return .init(
      accepted: false,
      status: "settings-managed-by-config",
      diagnostics: ["search engine settings are managed by the configuration file"]
    )
  case let SearchEngineSettingsError.invalid(field):
    return .init(accepted: false, status: "invalid-settings", diagnostics: [field])
  default:
    return graphQLNoteResult(for: error)
  }
}
