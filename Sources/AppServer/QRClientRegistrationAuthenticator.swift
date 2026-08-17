import Foundation
import AppGraphQL

import AppCore

#if canImport(CoreGraphics)
import CoreGraphics
#endif

#if canImport(CoreImage)
import CoreImage
#endif

#if canImport(Security)
import Security
#endif

public struct NoteAPIRegistrationChallenge: Codable, Equatable, Sendable {
  public var code: String
  public var expiresAt: String
  public var registrationURL: String
  public var qrText: String

  public init(code: String, expiresAt: String, registrationURL: String, qrText: String) {
    self.code = code
    self.expiresAt = expiresAt
    self.registrationURL = registrationURL
    self.qrText = qrText
  }
}

public struct NoteAPIRegistrationCredential: Codable, Equatable, Sendable {
  public var clientId: APIClientID
  public var displayName: String
  public var bearerToken: String
  public var createdAt: String

  public init(clientId: APIClientID, displayName: String, bearerToken: String, createdAt: String) {
    self.clientId = clientId
    self.displayName = displayName
    self.bearerToken = bearerToken
    self.createdAt = createdAt
  }
}

public struct NoteAPITimeProvider: Sendable {
  public var now: @Sendable () -> Date

  public init(now: @escaping @Sendable () -> Date = Date.init) {
    self.now = now
  }
}

public actor QRClientRegistrationAuthenticator: NoteAPIAuthenticating, NoteAPIClientRegistering {
  public static let maximumRegistrationTTLSeconds = 300
  public static let maximumPendingRegistrationCodes = 128

  private let service: NoteService
  private let registrationScope: String
  private let challengeStore: NoteAPIRegistrationChallengeStore
  private let timeProvider: NoteAPITimeProvider
  private let ttlSeconds: Int
  private let randomData: @Sendable (Int) throws -> Data

  public init(
    service: NoteService,
    registrationScope: String,
    ttlSeconds: Int = maximumRegistrationTTLSeconds,
    challengeStore: NoteAPIRegistrationChallengeStore = .shared,
    timeProvider: NoteAPITimeProvider = NoteAPITimeProvider(),
    randomData: (@Sendable (Int) throws -> Data)? = nil
  ) {
    self.service = service
    self.registrationScope = registrationScope
    self.challengeStore = challengeStore
    self.ttlSeconds = min(max(1, ttlSeconds), Self.maximumRegistrationTTLSeconds)
    self.timeProvider = timeProvider
    self.randomData = randomData ?? secureRandomData(byteCount:)
  }

  public func createRegistrationChallenge(publicBaseURL: String) throws -> NoteAPIRegistrationChallenge {
    let now = timeProvider.now()
    let code = try randomURLSafeToken(byteCount: 24, randomData: randomData)
    let expiresAtDate = now.addingTimeInterval(TimeInterval(ttlSeconds))
    try challengeStore.insert(
      PendingRegistrationCode(code: code, scope: registrationScope, expiresAt: expiresAtDate),
      maxPendingCodes: Self.maximumPendingRegistrationCodes,
      now: now
    )
    let registrationURL = noteRegistrationURL(publicBaseURL: publicBaseURL, code: code)
    return NoteAPIRegistrationChallenge(
      code: code,
      expiresAt: isoString(expiresAtDate),
      registrationURL: registrationURL,
      qrText: terminalQRText(for: registrationURL)
    )
  }

  public func createRegistrationChallenge(
    request: ServerRequestEnvelope,
    context: ServerRequestContext
  ) async -> ServerResponseDescriptor {
    .init(status: 403, body: [
      "error": .string("registration challenge creation requires an operator-controlled request")
    ])
  }

  public func redeemRegistrationCode(
    request: ServerRequestEnvelope,
    context: ServerRequestContext
  ) async -> ServerResponseDescriptor {
    guard let body = request.body,
          let payload = try? JSONDecoder().decode(NoteAPIRegistrationRequest.self, from: body) else {
      return .init(status: 400, body: ["error": .string("registration request body must include code and displayName")])
    }
    do {
      let credential = try redeemRegistrationCode(code: payload.code, displayName: payload.displayName)
      return .init(status: 200, body: [
        "credential": try encodedJSONObject(credential)
      ])
    } catch let error as NoteAPIRegistrationError {
      return .init(status: error.status, body: ["error": .string(error.message)])
    } catch {
      logNoteAPIServerError("note client registration failed", error: error)
      return .init(status: 500, body: ["error": .string("registration failed")])
    }
  }

  public func redeemRegistrationCode(code: String, displayName: String) throws -> NoteAPIRegistrationCredential {
    let now = timeProvider.now()
    guard let pending = challengeStore.removeValue(forKey: code, scope: registrationScope) else {
      throw NoteAPIRegistrationError(status: 404, message: "registration code not found")
    }
    guard now <= pending.expiresAt else {
      throw NoteAPIRegistrationError(status: 410, message: "registration code expired")
    }
    pruneExpiredChallenges(now: now)
    let token = try makeNoteAPIBearerToken(randomData: randomData)
    let client = try service.registerAPIClient(displayName: displayName, bearerToken: token)
    return NoteAPIRegistrationCredential(
      clientId: client.clientId,
      displayName: client.displayName,
      bearerToken: token,
      createdAt: client.createdAt
    )
  }

  public func authenticate(
    request: ServerRequestEnvelope,
    context: ServerRequestContext
  ) async -> NoteAPIAuthenticationResult {
    guard let token = context.bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines),
          !token.isEmpty else {
      return .rejected(noteAPIUnauthorizedResponse("note API requires a bearer token"))
    }
    do {
      guard let client = try service.authenticateAPIClient(bearerToken: token) else {
        return .rejected(noteAPIUnauthorizedResponse("note API bearer token is invalid or revoked"))
      }
      return .accepted(NoteAPIAuthenticatedClient(
        clientId: client.clientId,
        displayName: client.displayName,
        userId: client.userId
      ))
    } catch {
      logNoteAPIServerError("note API authentication failed", error: error)
      return .rejected(noteAPIUnavailableResponse("note API authentication is unavailable"))
    }
  }

  public func pruneExpiredChallenges(now: Date) {
    challengeStore.pruneExpired(now: now)
  }
}

public final class NoteAPIRegistrationChallengeStore: @unchecked Sendable {
  public static let shared = NoteAPIRegistrationChallengeStore()

  private let lock = NSLock()
  private var pendingCodes: [String: PendingRegistrationCode] = [:]

  public init() {}

  fileprivate func insert(
    _ pending: PendingRegistrationCode,
    maxPendingCodes: Int,
    now: Date
  ) throws {
    try lock.withLock {
      pendingCodes = pendingCodes.filter { _, pending in
        now <= pending.expiresAt
      }
      guard pendingCodes.count < maxPendingCodes else {
        throw NoteAPIRegistrationError(status: 429, message: "too many pending registration codes")
      }
      pendingCodes[pending.code] = pending
    }
  }

  fileprivate func removeValue(forKey code: String, scope: String) -> PendingRegistrationCode? {
    lock.withLock {
      guard pendingCodes[code]?.scope == scope else {
        return nil
      }
      return pendingCodes.removeValue(forKey: code)
    }
  }

  fileprivate func pruneExpired(now: Date) {
    lock.withLock {
      pendingCodes = pendingCodes.filter { _, pending in
        now <= pending.expiresAt
      }
    }
  }
}

public func makeNoteAPIBearerToken(randomData: (@Sendable (Int) throws -> Data)? = nil) throws -> String {
  "rn_\(try randomURLSafeToken(byteCount: 32, randomData: randomData ?? secureRandomData(byteCount:)))"
}

private struct PendingRegistrationCode: Equatable, Sendable {
  var code: String
  var scope: String
  var expiresAt: Date
}

private struct NoteAPIRegistrationRequest: Decodable {
  var code: String
  var displayName: String
}

private struct NoteAPIRegistrationError: Error, Equatable {
  var status: Int
  var message: String
}

/// Records an internal note API error to the server log only. Underlying error
/// text (DB paths, SQL, S3 endpoints) must never reach a client response body.
func logNoteAPIServerError(_ message: String, error: Error) {
  let line = "[kaiba-note] \(message): \(error)\n"
  FileHandle.standardError.write(Data(line.utf8))
}

private func secureRandomData(byteCount: Int) throws -> Data {
  var bytes = [UInt8](repeating: 0, count: byteCount)
  #if canImport(Security)
  let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
  guard status == errSecSuccess else {
    throw NoteAPIRegistrationError(status: 500, message: "secure random generation failed")
  }
  #else
  for index in bytes.indices {
    bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
  }
  #endif
  return Data(bytes)
}

private func randomURLSafeToken(byteCount: Int, randomData: @Sendable (Int) throws -> Data) throws -> String {
  try randomData(byteCount)
    .base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
}

private func noteRegistrationURL(publicBaseURL: String, code: String) -> String {
  let encodedCode = code.addingPercentEncoding(withAllowedCharacters: noteRegistrationCodeAllowedCharacters) ?? code
  return publicBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    + "/note/register?code=\(encodedCode)"
}

private let noteRegistrationCodeAllowedCharacters = CharacterSet(charactersIn:
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
)

private func terminalQRText(for payload: String) -> String {
  if let qrCode = renderedTerminalQRCode(for: payload) {
    return """
    Kaiba note client registration:
    \(qrCode)
    \(payload)
    """
  }
  return """
  Kaiba note client registration:
  \(payload)
  """
}

#if canImport(CoreGraphics) && canImport(CoreImage)
private func renderedTerminalQRCode(for payload: String) -> String? {
  guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
    return nil
  }
  filter.setValue(Data(payload.utf8), forKey: "inputMessage")
  filter.setValue("M", forKey: "inputCorrectionLevel")
  guard let outputImage = filter.outputImage else {
    return nil
  }
  return TerminalQRCodeRenderer(image: outputImage).render()
}
#else
private func renderedTerminalQRCode(for payload: String) -> String? {
  nil
}
#endif

private func encodedJSONObject<T: Encodable>(_ value: T) throws -> JSONValue {
  try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}

private func isoString(_ date: Date) -> String {
  ISO8601DateFormatter().string(from: date)
}

#if canImport(CoreGraphics) && canImport(CoreImage)
private struct TerminalQRCodeRenderer {
  private static let quietZoneModules = 2

  var image: CIImage

  func render() -> String? {
    let extent = image.extent.integral
    let width = Int(extent.width)
    let height = Int(extent.height)
    guard width > 0, height > 0 else {
      return nil
    }
    let rowBytes = width * 4
    var pixels = [UInt8](repeating: 0, count: rowBytes * height)
    CIContext(options: [.useSoftwareRenderer: true]).render(
      image,
      toBitmap: &pixels,
      rowBytes: rowBytes,
      bounds: extent,
      format: .RGBA8,
      colorSpace: CGColorSpaceCreateDeviceRGB()
    )
    return renderBlocks(pixels: pixels, width: width, height: height, rowBytes: rowBytes)
  }

  private func renderBlocks(pixels: [UInt8], width: Int, height: Int, rowBytes: Int) -> String {
    let quietZone = Self.quietZoneModules
    let minimumY = -quietZone
    let maximumY = height + quietZone
    let minimumX = -quietZone
    let maximumX = width + quietZone
    var lines: [String] = []
    for y in stride(from: minimumY, to: maximumY, by: 2) {
      var line = ""
      for x in minimumX..<maximumX {
        line += blockCharacter(
          upperIsBlack: isBlack(x: x, y: y, pixels: pixels, width: width, height: height, rowBytes: rowBytes),
          lowerIsBlack: isBlack(x: x, y: y + 1, pixels: pixels, width: width, height: height, rowBytes: rowBytes)
        )
      }
      lines.append(line)
    }
    return lines.joined(separator: "\n")
  }

  private func isBlack(x: Int, y: Int, pixels: [UInt8], width: Int, height: Int, rowBytes: Int) -> Bool {
    guard x >= 0, x < width, y >= 0, y < height else {
      return false
    }
    let offset = (y * rowBytes) + (x * 4)
    return pixels[offset] < 128
  }

  private func blockCharacter(upperIsBlack: Bool, lowerIsBlack: Bool) -> String {
    switch (upperIsBlack, lowerIsBlack) {
    case (true, true):
      return "█"
    case (true, false):
      return "▀"
    case (false, true):
      return "▄"
    case (false, false):
      return " "
    }
  }
}
#endif
