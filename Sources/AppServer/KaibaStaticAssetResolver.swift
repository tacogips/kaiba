import Foundation

private let kaibaSPAServiceNamespaces = [
  "/api",
  "/graphql",
  "/healthz",
  "/note",
  "/overview"
]

private func isKaibaSPAServicePath(_ path: String) -> Bool {
  kaibaSPAServiceNamespaces.contains { namespace in
    path == namespace || path.hasPrefix(namespace + "/")
  }
}

public struct KaibaStaticAssetResolver: Sendable {
  public var rootURL: URL

  public init(rootURL: URL) {
    self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
  }

  public func response(for request: KaibaHTTPRequest) -> KaibaHTTPResponse? {
    guard request.method == "GET" || request.method == "HEAD" else {
      return nil
    }
    guard !isKaibaSPAServicePath(request.path) else {
      return nil
    }
    guard !request.path.unicodeScalars.contains(where: { $0.value == 0 }),
          !request.percentEncodedPath.lowercased().contains("%00"),
          let decodedPath = request.percentEncodedPath.removingPercentEncoding,
          decodedPath == request.path else {
      return KaibaHTTPResponse.text(status: 404, "Not Found")
    }
    let requestedPath = request.path == "/" ? "index.html" : String(request.path.dropFirst())
    if let response = fileResponse(relativePath: requestedPath) {
      return response
    }
    guard requestedPath.split(separator: "/").last?.contains(".") != true else {
      return KaibaHTTPResponse.text(status: 404, "Not Found")
    }
    return fileResponse(relativePath: "index.html") ?? KaibaHTTPResponse.text(status: 404, "Not Found")
  }

  private func fileResponse(relativePath: String) -> KaibaHTTPResponse? {
    guard !relativePath.isEmpty,
          !relativePath.contains(".."),
          !relativePath.contains("\\") else {
      return nil
    }
    let candidate = rootURL.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
    let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
    guard candidate.path.hasPrefix(rootPath) else {
      return nil
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
          !isDirectory.boolValue,
          let data = try? Data(contentsOf: candidate, options: .mappedIfSafe) else {
      return nil
    }
    let immutable = candidate.lastPathComponent.contains("-") && candidate.pathExtension != "html"
    return KaibaHTTPResponse(
      status: 200,
      headers: [
        "Content-Type": Self.contentType(for: candidate.pathExtension),
        "Cache-Control": immutable ? "public, max-age=31536000, immutable" : "no-cache",
        "Content-Security-Policy": "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'"
      ],
      body: data
    )
  }

  private static func contentType(for pathExtension: String) -> String {
    switch pathExtension.lowercased() {
    case "html": "text/html; charset=utf-8"
    case "js", "mjs": "text/javascript; charset=utf-8"
    case "css": "text/css; charset=utf-8"
    case "json", "map": "application/json; charset=utf-8"
    case "svg": "image/svg+xml"
    case "png": "image/png"
    case "jpg", "jpeg": "image/jpeg"
    case "ico": "image/x-icon"
    case "woff": "font/woff"
    case "woff2": "font/woff2"
    default: "application/octet-stream"
    }
  }
}

public struct KaibaStaticSPAHTTPRouter: KaibaHTTPRouteHandling {
  public var service: any KaibaHTTPRouteHandling
  public var assets: KaibaStaticAssetResolver

  public init(service: any KaibaHTTPRouteHandling, webRoot: URL) {
    self.service = service
    assets = KaibaStaticAssetResolver(rootURL: webRoot)
  }

  public func response(for request: KaibaHTTPRequest) async -> KaibaHTTPResponse {
    if request.method == "GET", request.path == "/note/register" {
      var bootstrapRequest = request
      bootstrapRequest.path = "/"
      bootstrapRequest.percentEncodedPath = "/"
      return assets.response(for: bootstrapRequest)
        ?? KaibaHTTPResponse.text(status: 404, "Not Found")
    }
    if isServiceRoute(request) {
      return await service.response(for: request)
    }
    if let assetResponse = assets.response(for: request) {
      return assetResponse
    }
    return await service.response(for: request)
  }

  private func isServiceRoute(_ request: KaibaHTTPRequest) -> Bool {
    isKaibaSPAServicePath(request.path)
  }
}
