import Foundation

import AppCore

enum NoteGraphQLDocumentExecutorError: Error, Equatable {
  case missingVariable(String)
  case invalidVariable(String)
  case invalidSelection(String)
  case operationFieldMismatch(operation: String, fieldName: String)
}
func encodedJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
  try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}

func requiredInput<T: Decodable>(_ key: String, variables: JSONObject) throws -> T {
  guard let value = variables[key], value != .null else {
    throw NoteGraphQLDocumentExecutorError.missingVariable(key)
  }
  return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

/// Reads a required id variable. GraphQL still carries ids as plain strings,
/// so this is the boundary where one becomes a typed identifier; the same
/// emptiness rules as `requiredString` apply first.
func requiredIdentifier<Identifier: KaibaIdentifier>(
  _ key: String,
  as type: Identifier.Type = Identifier.self,
  variables: JSONObject
) throws -> Identifier {
  Identifier(try requiredString(key, variables: variables))
}

func optionalIdentifier<Identifier: KaibaIdentifier>(
  _ key: String,
  as type: Identifier.Type = Identifier.self,
  variables: JSONObject
) throws -> Identifier? {
  try optionalString(key, variables: variables).map(Identifier.init)
}

func optionalIdentifierArray<Identifier: KaibaIdentifier>(
  _ key: String,
  as type: Identifier.Type = Identifier.self,
  variables: JSONObject
) throws -> [Identifier]? {
  try optionalStringArray(key, variables: variables)?.map(Identifier.init)
}

func optionalIdentifierArrayArray<Identifier: KaibaIdentifier>(
  _ key: String,
  as type: Identifier.Type = Identifier.self,
  variables: JSONObject
) throws -> [[Identifier]]? {
  try optionalStringArrayArray(key, variables: variables)?.map { $0.map(Identifier.init) }
}

func requiredString(_ key: String, variables: JSONObject) throws -> String {
  guard case let .string(value)? = variables[key] else {
    throw NoteGraphQLDocumentExecutorError.missingVariable(key)
  }
  guard !value.isEmpty else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable("\(key) must not be empty")
  }
  return value
}

func optionalString(_ key: String, variables: JSONObject) throws -> String? {
  guard let value = variables[key], value != .null else {
    return nil
  }
  guard case let .string(string) = value else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable("\(key) must be a string")
  }
  guard !string.isEmpty else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable("\(key) must not be empty")
  }
  return string
}

func requiredBool(_ key: String, variables: JSONObject) throws -> Bool {
  guard case let .bool(value)? = variables[key] else {
    throw NoteGraphQLDocumentExecutorError.missingVariable(key)
  }
  return value
}

func optionalBool(_ key: String, variables: JSONObject) throws -> Bool? {
  guard let value = variables[key], value != .null else {
    return nil
  }
  guard case let .bool(bool) = value else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable("\(key) must be a boolean")
  }
  return bool
}

func optionalInt(_ key: String, variables: JSONObject) throws -> Int? {
  guard let value = variables[key], value != .null else {
    return nil
  }
  switch value {
  case let .integer(integer):
    guard let converted = Int(exactly: integer) else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("\(key) is out of range")
    }
    return converted
  case let .number(number):
    guard let converted = Int(exactly: number) else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("\(key) must be an integer")
    }
    return converted
  default:
    throw NoteGraphQLDocumentExecutorError.invalidVariable("\(key) must be an integer")
  }
}

/// The maximum page size accepted by `limit` on every list/search field.
/// Mirrored in the SDL contract text (`GraphQLNoteSchemaContract.swift`).
let noteGraphQLMaximumLimit = 200
/// The maximum `offset` accepted on every list/search field.
let noteGraphQLMaximumOffset = 1_000_000

func validatedLimit(_ value: Int?, defaultValue: Int) throws -> Int {
  guard let value else {
    return defaultValue
  }
  guard (0...noteGraphQLMaximumLimit).contains(value) else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable(
      "limit must be between 0 and \(noteGraphQLMaximumLimit)"
    )
  }
  return value
}

/// Graph fields (`noteGraphNeighbors`, `proposeNoteLinks`) can return at most
/// `NoteGraphPolicy.maximumLimit` rows; the contract promise is "rejected
/// rather than silently clamped", so a larger `limit` is an error here instead
/// of being truncated by the service.
func validatedGraphLimit(_ value: Int?, defaultValue: Int) throws -> Int {
  guard let value else {
    return defaultValue
  }
  guard (0...NoteGraphPolicy.maximumLimit).contains(value) else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable(
      "limit must be between 0 and \(NoteGraphPolicy.maximumLimit) for graph fields"
    )
  }
  return value
}

func validatedOffset(_ value: Int?) throws -> Int {
  guard let value else {
    return 0
  }
  guard (0...noteGraphQLMaximumOffset).contains(value) else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable(
      "offset must be between 0 and \(noteGraphQLMaximumOffset)"
    )
  }
  return value
}

func optionalStringArray(_ key: String, variables: JSONObject) throws -> [String]? {
  guard let value = variables[key], value != .null else {
    return nil
  }
  guard case let .array(values) = value else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable("\(key) must be an array of strings")
  }
  return try values.map { value in
    guard case let .string(string) = value else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("\(key) must be an array of strings")
    }
    return string
  }
}

func optionalStringArrayArray(_ key: String, variables: JSONObject) throws -> [[String]]? {
  guard let value = variables[key], value != .null else {
    return nil
  }
  guard case let .array(groups) = value else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable(
      "\(key) must be an array of string arrays"
    )
  }
  return try groups.map { group in
    guard case let .array(values) = group else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable(
        "\(key) must be an array of string arrays"
      )
    }
    return try values.map { value in
      guard case let .string(string) = value else {
        throw NoteGraphQLDocumentExecutorError.invalidVariable(
          "\(key) must be an array of string arrays"
        )
      }
      return string
    }
  }
}
