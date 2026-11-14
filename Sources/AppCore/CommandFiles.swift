import Foundation
import UniformTypeIdentifiers

extension AppCommand {
  func runAttach(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let roleRaw = try cursor.extractOption("--role") ?? NoteFileRole.related.rawValue
    let mediaTypeOverride = try cursor.extractOption("--media-type")
    guard let noteId = cursor.next(), let path = cursor.next() else {
      throw Error.invalidUsage("attach requires <note-id> <file-path>")
    }
    guard let role = NoteFileRole(rawValue: roleRaw) else {
      throw Error.invalidUsage("--role expects related, embedded, or source-page-image")
    }
    try cursor.finish()

    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    let data = try Data(contentsOf: url)
    let service = try makeService(root: context.noteRoot)
    let attachment = try service.attachFile(
      noteId: noteId,
      data: data,
      role: role,
      mediaType: mediaTypeOverride ?? inferredMediaType(for: url),
      originalFilename: url.lastPathComponent
    )
    return "Attached \(attachment.file.fileId) (\(attachment.file.mediaType), "
      + "\(attachment.file.byteSize) bytes) to note \(noteId) as \(attachment.role.rawValue)"
  }

  func runFile(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let outPath = try cursor.extractOption("--out")
    let output = try cursor.extractOutputMode()
    guard let fileId = cursor.next() else {
      throw Error.invalidUsage("file requires <file-id>")
    }
    try cursor.finish()

    let service = try makeService(root: context.noteRoot)
    let record = try service.getFileRecord(fileId: fileId)
    if let outPath {
      let data = try service.resolveFileContent(fileId: fileId)
      let destination = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
      try data.write(to: destination)
      return "Wrote \(data.count) bytes to \(destination.path)"
    }
    switch output {
    case .json:
      return try renderJSON(jsonObject(record))
    case .text:
      let name = record.originalFilename ?? "(unnamed)"
      var lines = [
        "file \(record.fileId)  \(name)",
        "storage \(record.storageKind.rawValue)  \(record.mediaType)  \(record.byteSize) bytes",
        "sha256 \(record.sha256)"
      ]
      if let localPath = record.localPath {
        lines.append("local-path files/\(localPath)")
      }
      if let bucket = record.s3Bucket, let key = record.s3Key {
        lines.append("s3 \(bucket)/\(key) (profile \(record.s3Profile ?? "-"))")
      }
      return lines.joined(separator: "\n")
    }
  }

  func runStorage(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    guard let subcommand = cursor.next() else {
      throw Error.invalidUsage("storage requires a subcommand: migrate|gc")
    }
    if subcommand == "gc" {
      let graceHours = try cursor.extractIntOption("--grace-hours") ?? 24
      try cursor.finish()
      let service = try makeService(root: context.noteRoot)
      let result = try service.reclaimUnreferencedFiles(
        olderThan: TimeInterval(graceHours) * 60 * 60
      )
      var lines = [
        "Reclaimed \(result.deletedFileIds.count) unreferenced file record(s), "
          + "swept \(result.sweptPaths.count) stray blob(s)."
      ]
      lines.append(contentsOf: result.deletedFileIds.map { "deleted \($0)" })
      lines.append(contentsOf: result.sweptPaths.map { "swept \($0)" })
      return lines.joined(separator: "\n")
    }
    guard subcommand == "migrate" else {
      throw Error.invalidUsage("unknown storage subcommand: \(subcommand)")
    }
    let all = cursor.extractFlag("--all")
    let profileName = try cursor.extractOption("--profile")
    let endpointRaw = try cursor.extractOption("--endpoint")
    let region = try cursor.extractOption("--region")
    let bucket = try cursor.extractOption("--bucket")
    let accessKeyEnv = try cursor.extractOption("--access-key-env")
    let secretKeyEnv = try cursor.extractOption("--secret-key-env")
    let keyPrefix = try cursor.extractOption("--key-prefix") ?? ""
    let fileId = cursor.next()
    try cursor.finish()

    guard all != (fileId != nil) else {
      throw Error.invalidUsage("storage migrate requires exactly one of <file-id> or --all")
    }
    guard
      let profileName, let endpointRaw, let region, let bucket,
      let accessKeyEnv, let secretKeyEnv
    else {
      throw Error.invalidUsage(
        "storage migrate requires --profile, --endpoint, --region, --bucket, "
          + "--access-key-env, and --secret-key-env"
      )
    }
    guard let endpoint = URL(string: endpointRaw), endpoint.scheme != nil else {
      throw Error.invalidUsage("--endpoint expects a URL, got: \(endpointRaw)")
    }

    let profile = try S3StorageProfile.environmentBacked(
      name: profileName,
      endpoint: endpoint,
      region: region,
      bucket: bucket,
      accessKeyIdEnv: accessKeyEnv,
      secretAccessKeyEnv: secretKeyEnv,
      keyPrefix: keyPrefix,
      environment: environment
    )

    let service = try makeService(root: context.noteRoot)
    if let fileId {
      let record = try service.migrateFileStorage(fileId: fileId, to: profile)
      return "Migrated \(record.fileId) to s3://\(record.s3Bucket ?? "")/\(record.s3Key ?? "")"
    }
    let result = try service.migrateAllLocalFiles(to: profile)
    var lines = ["Migrated \(result.migrated.count) file(s) to profile \(profileName)."]
    for failure in result.failures {
      lines.append("failed \(failure.fileId): \(failure.message)")
    }
    for failure in result.cleanupFailures {
      lines.append("cleanup-warning \(failure.fileId): \(failure.message)")
    }
    return lines.joined(separator: "\n")
  }

  func inferredMediaType(for url: URL) -> String {
    let ext = url.pathExtension
    guard !ext.isEmpty, let type = UTType(filenameExtension: ext),
      let mimeType = type.preferredMIMEType
    else {
      return "application/octet-stream"
    }
    return mimeType
  }
}
