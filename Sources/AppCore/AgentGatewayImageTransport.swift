import Foundation

/// Image argument and stdin rules shared by agent-gateway chat transport.
enum AgentGatewayImageTransport {
  static let imageCapableVendors = AgentGatewayImageOCRConverter.supportedVendors

  struct PreparedRequest {
    var request: AgentInvocationRequest
    var image: AgentInvocationImage?
    var imageURL: URL?
    var cleanup: (() -> Void)?
  }

  struct TemporaryImage {
    var url: URL
    var cleanup: () -> Void
  }

  static func makeTemporaryImage(_ image: AgentInvocationImage) throws -> TemporaryImage {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("kaiba-gateway-image-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      let file = directory.appendingPathComponent("page")
        .appendingPathExtension(DocumentImageNaming.fileExtension(forMediaType: image.mediaType))
      try image.data.write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      return TemporaryImage(url: file, cleanup: {
        try? FileManager.default.removeItem(at: directory)
      })
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw AgentInvocationError.failed("agent-gateway image temporary file unavailable")
    }
  }

  static func prepare(
    request: AgentInvocationRequest,
    vendor: String,
    mode: AgentGatewayExecutionMode,
    arguments: inout [String]
  ) throws -> PreparedRequest {
    guard !request.images.isEmpty else {
      return PreparedRequest(request: request, image: nil, imageURL: nil, cleanup: nil)
    }
    guard imageCapableVendors.contains(vendor), let image = request.images.first, image.isTransportable else {
      return PreparedRequest(request: request.droppingImagesWithNotice(), image: nil, imageURL: nil, cleanup: nil)
    }
    // P6 supplies one image; if a caller sends more, only the first is transported.
    let temporary = try makeTemporaryImage(image)
    arguments += preContextArguments(vendor: vendor, mode: mode, imageURL: temporary.url)
    return PreparedRequest(
      request: request,
      image: image,
      imageURL: temporary.url,
      cleanup: temporary.cleanup
    )
  }

  static func preContextArguments(vendor: String, mode: AgentGatewayExecutionMode, imageURL: URL) -> [String] {
    guard mode == .local else { return [] }
    switch vendor {
    case "claude-code": return ["--"] + ClaudeImageInput.arguments
    case "codex": return ["--", "--image", imageURL.path]
    default: return ["--image", imageURL.path]
    }
  }

  static func applyPostContext(
    vendor: String,
    mode: AgentGatewayExecutionMode,
    imageURL: URL,
    context: inout AgentGatewayExecutionContext
  ) throws {
    guard mode != .local else { return }
    if vendor == "claude-code" {
      context.arguments += ["--input-format", "stream-json"]
      return
    }
    guard let workspace = context.workspace else {
      throw AgentInvocationError.failed("image workspace unavailable")
    }
    let stagedImage = workspace.appendingPathComponent("page")
      .appendingPathExtension(imageURL.pathExtension)
    do {
      try FileManager.default.copyItem(at: imageURL, to: stagedImage)
    } catch {
      throw AgentInvocationError.failed("agent-gateway image workspace unavailable")
    }
    context.arguments += ["--image", stagedImage.path]
  }

  static func stdin(prompt: String, vendor: String, image: AgentInvocationImage?) throws -> Data {
    guard let image else { return Data(prompt.utf8) }
    guard vendor == "claude-code" else { return Data(prompt.utf8) }
    return try ClaudeImageInput.encode(
      prompt: prompt,
      imageData: image.data,
      mediaType: image.mediaType
    )
  }
}
