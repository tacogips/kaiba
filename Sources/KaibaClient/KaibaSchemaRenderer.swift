import Foundation

public enum KaibaSchemaRenderer {
  public static func text(_ selection: KaibaSchemaSelection) -> String {
    guard !selection.queryFields.isEmpty || !selection.mutationFields.isEmpty || !selection.types.isEmpty else {
      return "# No schema elements matched."
    }
    var definitions: [String] = []
    if !selection.queryFields.isEmpty {
      definitions.append(renderComposite(name: "Query", fields: selection.queryFields))
    }
    if !selection.mutationFields.isEmpty {
      definitions.append(renderComposite(name: "Mutation", fields: selection.mutationFields))
    }
    definitions += selection.types.map(renderType)
    return definitions.joined(separator: "\n\n")
  }

  public static func json(_ selection: KaibaSchemaSelection) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let result = String(data: try encoder.encode(selection), encoding: .utf8) else {
      throw KaibaClientError.invalidResponse(status: nil, byteCount: 0)
    }
    return result
  }

  private static func renderType(_ type: KaibaSchemaType) -> String {
    switch type.kind {
    case .scalar:
      return "scalar \(type.name)"
    case .enumeration:
      let values = type.enumValues.map {
        "  \($0.name)\(renderDeprecation(isDeprecated: $0.isDeprecated, reason: $0.deprecationReason))"
      }.joined(separator: "\n")
      return "enum \(type.name) {\n\(values)\n}"
    case .union:
      return "union \(type.name) = \(type.possibleTypes.joined(separator: " | "))"
    case .inputObject:
      let fields = type.inputFields.map { "  \($0.name): \($0.type.rendered)" }.joined(separator: "\n")
      return "input \(type.name) {\n\(fields)\n}"
    case .object, .interface:
      let prefix = type.kind == .object ? "type" : "interface"
      return renderComposite(
        name: type.name,
        fields: type.fields,
        prefix: prefix,
        interfaces: type.interfaces
      )
    }
  }

  private static func renderComposite(
    name: String,
    fields: [KaibaSchemaField],
    prefix: String = "type",
    interfaces: [String] = []
  ) -> String {
    let body = fields.map { field in
      let arguments = field.arguments.isEmpty ? "" : "(" + field.arguments.map {
        "\($0.name): \($0.type.rendered)"
      }.joined(separator: ", ") + ")"
      let deprecated = renderDeprecation(
        isDeprecated: field.isDeprecated,
        reason: field.deprecationReason
      )
      return "  \(field.name)\(arguments): \(field.type.rendered)\(deprecated)"
    }.joined(separator: "\n")
    let implements = interfaces.isEmpty
      ? ""
      : " implements \(interfaces.sorted().joined(separator: " & "))"
    return "\(prefix) \(name)\(implements) {\n\(body)\n}"
  }

  private static func escaped(_ value: String) -> String {
    var result = ""
    for scalar in value.unicodeScalars {
      switch scalar.value {
      case 0x08: result += "\\b"
      case 0x09: result += "\\t"
      case 0x0A: result += "\\n"
      case 0x0C: result += "\\f"
      case 0x0D: result += "\\r"
      case 0x22: result += "\\\""
      case 0x5C: result += "\\\\"
      case 0x00...0x1F:
        result += String(format: "\\u%04X", scalar.value)
      default:
        result.unicodeScalars.append(scalar)
      }
    }
    return result
  }

  private static func renderDeprecation(isDeprecated: Bool, reason: String?) -> String {
    guard isDeprecated else { return "" }
    guard let reason else { return " @deprecated" }
    return " @deprecated(reason: \"\(escaped(reason))\")"
  }
}
