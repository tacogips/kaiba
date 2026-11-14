import Foundation

public struct KaibaGraphQLRequest: Equatable, Sendable {
  public var document: String
  public var variables: [String: KaibaJSONValue]
  public var operationName: String?

  public init(
    document: String,
    variables: [String: KaibaJSONValue] = [:],
    operationName: String? = nil
  ) {
    self.document = document
    self.variables = variables
    self.operationName = operationName
  }
}

public struct KaibaGraphQLResponse<Value: Sendable>: Sendable {
  public var data: Value

  public init(data: Value) {
    self.data = data
  }
}

extension KaibaGraphQLResponse: Equatable where Value: Equatable {}

struct KaibaGraphQLWireEnvelope: Codable {
  var data: KaibaJSONValue?
  var errors: [KaibaGraphQLError]?
}

struct KaibaGraphQLWireRequest: Codable {
  var query: String
  var variables: [String: KaibaJSONValue]?
  var operationName: String?
}
