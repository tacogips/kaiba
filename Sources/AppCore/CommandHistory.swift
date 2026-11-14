import Foundation

// `kaiba history`, `kaiba undo`, `kaiba redo`
// (`design-docs/specs/action-history-undo.md`).

extension AppCommand {
  func runHistory(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let limit = try cursor.extractOption("--limit").flatMap(Int.init) ?? 50
    let beforeSeq = try cursor.extractOption("--before-seq").flatMap(Int64.init)
    let output = try cursor.extractOutputMode()
    try cursor.finish()

    let service = try makeService(context)
    let entries = try service.actionHistory(limit: limit, beforeSeq: beforeSeq)
    switch output {
    case .json:
      return try renderJSON(entries.map(jsonObject(_:)))
    case .text:
      guard !entries.isEmpty else {
        return "No recorded actions"
      }
      return entries.map(historyLine(for:)).joined(separator: "\n")
    }
  }

  func runUndo(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let output = try cursor.extractOutputMode()
    try cursor.finish()

    let service = try makeService(context)
    guard let outcome = try service.undoLastAction() else {
      return output == .json
        ? try renderJSON(["status": .string("nothing-to-undo")] as JSONObject)
        : "Nothing to undo"
    }
    switch output {
    case .json:
      return try renderJSON([
        "status": .string("ok"),
        "target": .object(jsonObject(outcome.target)),
        "applied": .object(jsonObject(outcome.entry))
      ] as JSONObject)
    case .text:
      return "Undid \(historyLine(for: outcome.target))"
    }
  }

  func runRedo(_ context: CommandContext) throws -> String {
    var cursor = context.cursor
    let output = try cursor.extractOutputMode()
    try cursor.finish()

    let service = try makeService(context)
    guard let outcome = try service.redoLastAction() else {
      return output == .json
        ? try renderJSON(["status": .string("nothing-to-redo")] as JSONObject)
        : "Nothing to redo"
    }
    switch output {
    case .json:
      return try renderJSON([
        "status": .string("ok"),
        "target": .object(jsonObject(outcome.target)),
        "applied": .object(jsonObject(outcome.entry))
      ] as JSONObject)
    case .text:
      return "Redid \(historyLine(for: outcome.target))"
    }
  }
}

private func historyLine(for entry: NoteActionLogEntry) -> String {
  let title = entry.display["title"]?.asString ?? entry.entityId
  var suffix = ""
  if entry.undoneBySeq != nil {
    suffix = " [undone]"
  } else if !entry.undoable {
    suffix = " [not undoable]"
  }
  return "#\(entry.seq) \(entry.occurredAt) \(entry.action) \(entry.entityType.rawValue) \"\(title)\" (\(entry.provenance.rawValue))\(suffix)"
}

private func jsonObject(_ entry: NoteActionLogEntry) -> JSONObject {
  [
    "seq": .integer(entry.seq),
    "occurredAt": .string(entry.occurredAt),
    "actorUserId": .id(entry.actorUserId),
    "provenance": .string(entry.provenance.rawValue),
    "entityType": .string(entry.entityType.rawValue),
    "entityId": .string(entry.entityId),
    "notebookId": .optionalID(entry.notebookId),
    "action": .string(entry.action),
    "title": .optionalString(entry.display["title"]?.asString),
    "undoable": .bool(entry.undoable),
    "undoOfSeq": entry.undoOfSeq.map(JSONValue.integer) ?? .null,
    "undoneBySeq": entry.undoneBySeq.map(JSONValue.integer) ?? .null
  ]
}
