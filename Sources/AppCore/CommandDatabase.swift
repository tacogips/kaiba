import Foundation

/// `kaiba db ...` — store maintenance. `check` audits file, foreign-key, and
/// search-index integrity (with `--repair` rebuilding a drifted search
/// index); `optimize` refreshes planner statistics and optionally compacts
/// the file. Both are store-wide operator commands, gated like `storage gc`.
extension AppCommand {
  func runDb(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    guard let subcommand = cursor.next() else {
      throw Error.invalidUsage("db requires a subcommand: check|optimize")
    }
    switch subcommand {
    case "check":
      let repair = cursor.extractFlag("--repair")
      let outputMode = try cursor.extractOutputMode()
      try cursor.finish()
      let report = try makeService(context).checkStore(repair: repair)
      return try renderCheckReport(report, as: outputMode)
    case "optimize":
      let vacuum = cursor.extractFlag("--vacuum")
      let outputMode = try cursor.extractOutputMode()
      try cursor.finish()
      let report = try makeService(context).optimizeStore(vacuum: vacuum)
      return try renderOptimizationReport(report, as: outputMode)
    default:
      throw Error.invalidUsage("unknown db subcommand: \(subcommand)")
    }
  }
}

private func renderCheckReport(
  _ report: NoteStoreCheckReport,
  as outputMode: OutputMode
) throws -> String {
  if outputMode == .json {
    return try renderJSON([
      "schemaVersion": .integer(Int64(report.schemaVersion)),
      "healthy": .bool(report.isHealthy),
      "integrityMessages": .array(report.integrityMessages.map(JSONValue.string)),
      "foreignKeyViolations": .array(report.foreignKeyViolations.map(JSONValue.string)),
      "searchIndexHealthy": .bool(report.searchIndexHealthy),
      "notesMissingFromSearchIndex": .ids(report.notesMissingFromSearchIndex),
      "orphanedSearchIndexRows": .integer(Int64(report.orphanedSearchIndexRows)),
      "unreferencedFiles": .integer(Int64(report.unreferencedFiles)),
      "searchIndexRepaired": .bool(report.searchIndexRepaired)
    ] as JSONObject)
  }
  var lines = ["schema-version \(report.schemaVersion)"]
  lines.append(
    report.integrityMessages == ["ok"]
      ? "integrity ok"
      : "integrity FAILED: \(report.integrityMessages.joined(separator: "; "))"
  )
  lines.append(
    report.foreignKeyViolations.isEmpty
      ? "foreign-keys ok"
      : "foreign-keys \(report.foreignKeyViolations.count) violation(s)"
  )
  lines.append(contentsOf: report.foreignKeyViolations.map { "  \($0)" })
  var searchLine = report.searchIndexHealthy
    && report.notesMissingFromSearchIndex.isEmpty
    && report.orphanedSearchIndexRows == 0
    ? "search-index ok"
    : "search-index DAMAGED"
  if !report.notesMissingFromSearchIndex.isEmpty {
    searchLine += " missing:\(report.notesMissingFromSearchIndex.count)"
  }
  if report.orphanedSearchIndexRows > 0 {
    searchLine += " orphaned:\(report.orphanedSearchIndexRows)"
  }
  if report.searchIndexRepaired {
    searchLine += " (repaired: index rebuilt)"
  }
  lines.append(searchLine)
  lines.append(contentsOf: report.notesMissingFromSearchIndex.map { "  missing \($0)" })
  lines.append("unreferenced-files \(report.unreferencedFiles)  # reclaim with: storage gc")
  lines.append(
    report.isHealthy
      ? "store is healthy"
      : "PROBLEMS FOUND\(report.searchIndexRepaired ? "" : " (search-index drift is repairable with --repair)")"
  )
  return lines.joined(separator: "\n")
}

private func renderOptimizationReport(
  _ report: NoteStoreOptimizationReport,
  as outputMode: OutputMode
) throws -> String {
  if outputMode == .json {
    return try renderJSON([
      "vacuumed": .bool(report.vacuumed),
      "bytesBefore": .integer(report.bytesBefore),
      "bytesAfter": .integer(report.bytesAfter),
      "freelistPagesBefore": .integer(report.freelistPagesBefore),
      "freelistPagesAfter": .integer(report.freelistPagesAfter)
    ] as JSONObject)
  }
  var lines = [
    "analyzed statistics and ran PRAGMA optimize",
    "size \(report.bytesBefore) -> \(report.bytesAfter) bytes",
    "freelist \(report.freelistPagesBefore) -> \(report.freelistPagesAfter) page(s)"
  ]
  if !report.vacuumed {
    lines.append("run with --vacuum to compact the file")
  }
  return lines.joined(separator: "\n")
}
