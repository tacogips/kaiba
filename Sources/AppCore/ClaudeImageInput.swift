import Foundation

/// agent-gateway forwards CLI prompt stdin verbatim. Claude's stream-json
/// input carries image bytes directly, without a Read tool or path instruction.
enum ClaudeImageInput {
  static let arguments = ["--input-format", "stream-json"] + restrictedArguments
  static let restrictedArguments = [
    "--tools", "",
    "--disable-slash-commands", "--no-session-persistence",
    "--setting-sources", "", "--settings", "{\"disableAllHooks\":true}",
    "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}"
  ]

  static func encode(prompt: String, imageURL: URL) throws -> Data {
    let attributes = try imageURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard attributes.isRegularFile == true, let size = attributes.fileSize,
      size > 0, size <= 20 * 1024 * 1024 else {
      throw DocumentConversionError.failed("Claude image input must be a nonempty regular file of at most 20 MiB")
    }
    let mimeType: String
    switch imageURL.pathExtension.lowercased() {
    case "png": mimeType = "image/png"
    case "jpg", "jpeg": mimeType = "image/jpeg"
    case "gif": mimeType = "image/gif"
    case "webp": mimeType = "image/webp"
    default: throw DocumentConversionError.failed("unsupported Claude image format")
    }
    let bytes = try Data(contentsOf: imageURL)
    guard bytes.count <= 20 * 1024 * 1024 else {
      throw DocumentConversionError.failed("Claude image input exceeds 20 MiB")
    }
    let object: [String: Any] = [
      "type": "user",
      "message": [
        "role": "user",
        "content": [
          ["type": "image", "source": ["type": "base64", "media_type": mimeType, "data": bytes.base64EncodedString()]],
          ["type": "text", "text": prompt]
        ]
      ]
    ]
    var encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    encoded.append(0x0a)
    return encoded
  }
}
