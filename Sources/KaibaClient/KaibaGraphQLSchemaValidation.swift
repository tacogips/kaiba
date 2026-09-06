import Foundation

extension KaibaGraphQLSchema {
  mutating func canonicalizeAndValidate(validateDeclaredReferenceKinds: Bool = false) throws {
    queryFields = queryFields.map(Self.canonicalField)
    mutationFields = mutationFields.map(Self.canonicalField)
    types = types.map { type in
      var canonical = type
      canonical.fields = type.fields.map(Self.canonicalField).sorted { $0.name < $1.name }
      canonical.inputFields.sort { $0.name < $1.name }
      canonical.enumValues.sort { $0.name < $1.name }
      canonical.interfaces.sort()
      canonical.possibleTypes.sort()
      return canonical
    }
    queryFields.sort { $0.name < $1.name }
    mutationFields.sort { $0.name < $1.name }
    try Self.requireValidGraphQLNames(
      queryFields: queryFields,
      mutationFields: mutationFields,
      types: types
    )
    try Self.requireApplicableMembers(types)
    guard Set(types.map(\.name)).count == types.count else {
      throw KaibaClientError.schemaUnavailable("duplicate type definition")
    }
    try Self.requireUniqueFields(queryFields, owner: "Query")
    try Self.requireUniqueFields(mutationFields, owner: "Mutation")
    for type in types {
      try Self.requireUniqueFields(type.fields, owner: type.name)
      guard Set(type.inputFields.map(\.name)).count == type.inputFields.count,
            Set(type.enumValues.map(\.name)).count == type.enumValues.count,
            Set(type.interfaces).count == type.interfaces.count,
            Set(type.possibleTypes).count == type.possibleTypes.count else {
        throw KaibaClientError.schemaUnavailable("duplicate member in type \(type.name)")
      }
    }
    let objectTypes = types.filter { $0.kind == .object }
    for index in types.indices where types[index].kind == .interface {
      let interfaceName = types[index].name
      let implementors = objectTypes.filter { $0.interfaces.contains(interfaceName) }.map(\.name)
      types[index].possibleTypes = Array(Set(types[index].possibleTypes + implementors)).sorted()
    }
    let references = queryFields.flatMap(Self.references(in:))
      + mutationFields.flatMap(Self.references(in:))
      + types.flatMap { type in
        type.fields.flatMap(Self.references(in:))
          + type.inputFields.map { $0.type.namedTypeName }
          + type.interfaces + type.possibleTypes
      }
    let builtins = Set(["String", "Int", "Float", "Boolean", "ID"])
    let names = Set(types.map(\.name)).union(builtins)
    guard references.allSatisfy(names.contains) else {
      throw KaibaClientError.schemaUnavailable("schema contains a dangling type reference")
    }
    let existingNames = Set(types.map(\.name))
    types += Set(references).intersection(builtins).subtracting(existingNames).map {
      KaibaSchemaType(kind: .scalar, name: $0)
    }
    var kindsByName: [String: KaibaSchemaTypeKind] = [:]
    for type in types {
      guard kindsByName.updateValue(type.kind, forKey: type.name) == nil else {
        throw KaibaClientError.schemaUnavailable("duplicate type definition")
      }
    }
    queryFields = try queryFields.map {
      try Self.resolvedField(
        $0,
        kindsByName: kindsByName,
        validateDeclaredReferenceKinds: validateDeclaredReferenceKinds
      )
    }
    mutationFields = try mutationFields.map {
      try Self.resolvedField(
        $0,
        kindsByName: kindsByName,
        validateDeclaredReferenceKinds: validateDeclaredReferenceKinds
      )
    }
    types = try types.map { type in
      var resolved = type
      resolved.fields = try type.fields.map {
        try Self.resolvedField(
          $0,
          kindsByName: kindsByName,
          validateDeclaredReferenceKinds: validateDeclaredReferenceKinds
        )
      }
      resolved.inputFields = try type.inputFields.map {
        try Self.resolvedInputValue(
          $0,
          kindsByName: kindsByName,
          validateDeclaredReferenceKinds: validateDeclaredReferenceKinds
        )
      }
      guard type.interfaces.allSatisfy({ kindsByName[$0] == .interface }) else {
        throw KaibaClientError.schemaUnavailable("object references a non-interface type")
      }
      guard type.possibleTypes.allSatisfy({ kindsByName[$0] == .object }) else {
        throw KaibaClientError.schemaUnavailable("interface or union references a non-object type")
      }
      return resolved
    }
    types.sort { lhs, rhs in
      let left = Self.kindOrder(lhs.kind)
      let right = Self.kindOrder(rhs.kind)
      return left == right ? lhs.name < rhs.name : left < right
    }
  }

  private static func canonicalField(_ field: KaibaSchemaField) -> KaibaSchemaField {
    var canonical = field
    canonical.arguments.sort { $0.name < $1.name }
    return canonical
  }

  private static func resolvedField(
    _ field: KaibaSchemaField,
    kindsByName: [String: KaibaSchemaTypeKind],
    validateDeclaredReferenceKinds: Bool
  ) throws -> KaibaSchemaField {
    var resolved = field
    resolved.type = try resolvedReference(
      field.type,
      kindsByName: kindsByName,
      validateDeclaredReferenceKinds: validateDeclaredReferenceKinds
    )
    resolved.arguments = try field.arguments.map {
      try resolvedInputValue(
        $0,
        kindsByName: kindsByName,
        validateDeclaredReferenceKinds: validateDeclaredReferenceKinds
      )
    }
    return resolved
  }

  private static func resolvedInputValue(
    _ value: KaibaSchemaInputValue,
    kindsByName: [String: KaibaSchemaTypeKind],
    validateDeclaredReferenceKinds: Bool
  ) throws -> KaibaSchemaInputValue {
    var resolved = value
    resolved.type = try resolvedReference(
      value.type,
      kindsByName: kindsByName,
      validateDeclaredReferenceKinds: validateDeclaredReferenceKinds
    )
    return resolved
  }

  private static func resolvedReference(
    _ reference: KaibaSchemaTypeReference,
    kindsByName: [String: KaibaSchemaTypeKind],
    validateDeclaredReferenceKinds: Bool,
    depth: Int = 0
  ) throws -> KaibaSchemaTypeReference {
    guard depth <= 8 else {
      throw KaibaClientError.schemaUnavailable("type-reference wrapper depth exceeds eight")
    }
    switch reference {
    case let .named(declaredKind, name):
      guard let kind = kindsByName[name] else {
        throw KaibaClientError.schemaUnavailable("schema contains a dangling type reference")
      }
      guard !validateDeclaredReferenceKinds || declaredKind == kind else {
        throw KaibaClientError.schemaUnavailable("type-reference kind conflicts with definition")
      }
      return .named(kind: kind, name: name)
    case let .list(nested):
      return .list(try resolvedReference(
        nested,
        kindsByName: kindsByName,
        validateDeclaredReferenceKinds: validateDeclaredReferenceKinds,
        depth: depth + 1
      ))
    case let .nonNull(nested):
      if case .nonNull = nested {
        throw KaibaClientError.schemaUnavailable("NON_NULL cannot wrap NON_NULL")
      }
      return .nonNull(try resolvedReference(
        nested,
        kindsByName: kindsByName,
        validateDeclaredReferenceKinds: validateDeclaredReferenceKinds,
        depth: depth + 1
      ))
    }
  }

  private static func requireUniqueFields(
    _ fields: [KaibaSchemaField],
    owner: String
  ) throws {
    guard Set(fields.map(\.name)).count == fields.count,
          fields.allSatisfy({ Set($0.arguments.map(\.name)).count == $0.arguments.count }) else {
      throw KaibaClientError.schemaUnavailable("duplicate field or argument in type \(owner)")
    }
  }

  private static func requireApplicableMembers(_ types: [KaibaSchemaType]) throws {
    for type in types {
      let isValid = switch type.kind {
      case .object:
        type.inputFields.isEmpty && type.enumValues.isEmpty && type.possibleTypes.isEmpty
      case .interface:
        type.inputFields.isEmpty && type.enumValues.isEmpty
      case .union:
        type.fields.isEmpty && type.inputFields.isEmpty && type.enumValues.isEmpty
          && type.interfaces.isEmpty
      case .inputObject:
        type.fields.isEmpty && type.enumValues.isEmpty && type.interfaces.isEmpty
          && type.possibleTypes.isEmpty
      case .enumeration:
        type.fields.isEmpty && type.inputFields.isEmpty && type.interfaces.isEmpty
          && type.possibleTypes.isEmpty
      case .scalar:
        type.fields.isEmpty && type.inputFields.isEmpty && type.enumValues.isEmpty
          && type.interfaces.isEmpty && type.possibleTypes.isEmpty
      }
      guard isValid else {
        throw KaibaClientError.schemaUnavailable("type contains members that do not apply to its kind")
      }
    }
  }

  private static func requireValidGraphQLNames(
    queryFields: [KaibaSchemaField],
    mutationFields: [KaibaSchemaField],
    types: [KaibaSchemaType]
  ) throws {
    let fields = queryFields + mutationFields + types.flatMap(\.fields)
    let inputValues = fields.flatMap(\.arguments) + types.flatMap(\.inputFields)
    let identifiers = types.map(\.name)
      + fields.map(\.name)
      + inputValues.map(\.name)
      + types.flatMap { $0.enumValues.map(\.name) }
      + types.flatMap(\.interfaces)
      + types.flatMap(\.possibleTypes)
      + fields.map { $0.type.namedTypeName }
      + inputValues.map { $0.type.namedTypeName }
    guard identifiers.allSatisfy(isGraphQLName) else {
      throw KaibaClientError.schemaUnavailable("schema contains an invalid GraphQL name")
    }
  }

  private static func isGraphQLName(_ value: String) -> Bool {
    let scalars = value.unicodeScalars
    guard let first = scalars.first, isGraphQLNameStart(first) else { return false }
    return scalars.dropFirst().allSatisfy { isGraphQLNameStart($0) || (48...57).contains($0.value) }
  }

  private static func isGraphQLNameStart(_ scalar: UnicodeScalar) -> Bool {
    scalar == "_" || (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
  }
}
