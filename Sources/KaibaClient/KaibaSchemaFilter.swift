import Foundation

public struct KaibaSchemaSelection: Codable, Equatable, Sendable {
  public internal(set) var filter: String?
  public internal(set) var queryFields: [KaibaSchemaField]
  public internal(set) var mutationFields: [KaibaSchemaField]
  public internal(set) var types: [KaibaSchemaType]

  public init(
    filter: String?,
    queryFields: [KaibaSchemaField],
    mutationFields: [KaibaSchemaField],
    types: [KaibaSchemaType]
  ) {
    self.filter = filter
    self.queryFields = queryFields
    self.mutationFields = mutationFields
    self.types = types
  }

  private enum CodingKeys: String, CodingKey {
    case filter
    case queryFields
    case mutationFields
    case types
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    filter = try container.decodeIfPresent(String.self, forKey: .filter)
    queryFields = try container.decode([KaibaSchemaField].self, forKey: .queryFields)
    mutationFields = try container.decode([KaibaSchemaField].self, forKey: .mutationFields)
    types = try container.decode([KaibaSchemaType].self, forKey: .types)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    if let filter {
      try container.encode(filter, forKey: .filter)
    } else {
      try container.encodeNil(forKey: .filter)
    }
    try container.encode(queryFields, forKey: .queryFields)
    try container.encode(mutationFields, forKey: .mutationFields)
    try container.encode(types, forKey: .types)
  }
}

extension KaibaGraphQLSchema {
  public func selecting(matching pattern: String?) throws -> KaibaSchemaSelection {
    guard let pattern else {
      return KaibaSchemaSelection(
        filter: nil,
        queryFields: queryFields,
        mutationFields: mutationFields,
        types: types
      )
    }
    let regex: NSRegularExpression
    do {
      regex = try NSRegularExpression(pattern: pattern)
    } catch {
      throw KaibaClientError.invalidRegex
    }
    func matches(_ candidates: [String]) -> Bool {
      candidates.contains { value in
        regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
      }
    }
    let selectedQueries = queryFields.filter { matches([$0.name, "Query.\($0.name)"]) }
    let selectedMutations = mutationFields.filter { matches([$0.name, "Mutation.\($0.name)"]) }
    let directlySelectedTypes = types.filter { type in
      guard type.kind != .interface && type.kind != .union else { return false }
      return matches([type.name, "Type.\(type.name)"])
    }
    var typesByName: [String: KaibaSchemaType] = [:]
    for type in types {
      guard typesByName.updateValue(type, forKey: type.name) == nil else {
        throw KaibaClientError.schemaUnavailable("duplicate type definition")
      }
    }
    var pending = selectedQueries.flatMap(Self.references(in:))
      + selectedMutations.flatMap(Self.references(in:))
      + directlySelectedTypes.map(\.name)
    var visited = Set<String>()
    while let name = pending.popLast() {
      guard visited.insert(name).inserted, let type = typesByName[name] else { continue }
      pending += type.fields.flatMap(Self.references(in:))
      pending += type.inputFields.map { $0.type.namedTypeName }
      pending += type.interfaces + type.possibleTypes
    }
    return KaibaSchemaSelection(
      filter: pattern,
      queryFields: selectedQueries,
      mutationFields: selectedMutations,
      types: types.filter { visited.contains($0.name) }
    )
  }
}
