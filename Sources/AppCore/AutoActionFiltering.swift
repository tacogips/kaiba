import Foundation

/// Decides which enabled auto actions a note or notebook event triggers, and
/// validates the `filter_json` an action is configured with.
extension NoteService {
  func matchingAutoActions(for event: NoteAutoActionEvent) throws -> [AutoAction] {
    try driver.withDatabase { database in
      try matchingAutoActions(for: event, in: database)
    }
  }

  func matchingAutoActions(for event: NoteAutoActionEvent, in database: SQLiteDatabase) throws -> [AutoAction] {
    let actions = try database.query(
      """
      SELECT action_id, trigger, workflow_id,
        CASE WHEN filter_json IS NULL THEN NULL ELSE json(filter_json) END AS filter_json,
        enabled, position, created_at
      FROM auto_actions
      WHERE enabled = 1 AND trigger = ?
      ORDER BY position, action_id
      """,
      bindings: [.text(event.trigger.rawValue)]
    ).map(autoAction(from:))
    var matching: [AutoAction] = []
    for action in actions {
      do {
        if try autoAction(action, matches: event, in: database) {
          matching.append(action)
        }
      } catch {
        autoActionDiagnosticRecorder?.record(NoteAutoActionDiagnostic(
          code: .filterEvaluationFailed,
          actionId: action.actionId,
          trigger: action.trigger,
          message: "skipped auto action because filter_json could not be evaluated: \(error)"
        ))
      }
    }
    return matching
  }
}

struct AutoActionFilter: Decodable {
  var noteTags: [String]?
  var notebookKindTag: String?
}

func validateAutoActionFilterJSON(_ filterJSON: String?) throws {
  guard let filterJSON else {
    return
  }
  guard let filterData = filterJSON.data(using: .utf8) else {
    throw NoteServiceError.invalidInput("auto action filter JSON must be UTF-8")
  }
  do {
    _ = try JSONDecoder().decode(AutoActionFilter.self, from: filterData)
  } catch {
    throw NoteServiceError.invalidInput("invalid auto action filter JSON: \(error)")
  }
}

func autoAction(_ action: AutoAction, matches event: NoteAutoActionEvent, in database: SQLiteDatabase) throws -> Bool {
  guard let filterJSON = action.filterJSON else {
    return true
  }
  guard let filterData = filterJSON.data(using: .utf8) else {
    return false
  }
  let filter = try JSONDecoder().decode(AutoActionFilter.self, from: filterData)
  if let requiredNoteTags = filter.noteTags, !requiredNoteTags.isEmpty {
    guard let noteId = event.noteId else {
      return false
    }
    let noteTags = try noteTagNames(noteId: noteId, in: database)
    guard Set(requiredNoteTags).isSubset(of: Set(noteTags)) else {
      return false
    }
  }
  if let notebookKindTag = filter.notebookKindTag {
    guard let notebookId = try eventNotebookId(event, in: database) else {
      return false
    }
    guard let kindTag = try findNonFolderTag(name: notebookKindTag, in: database),
          kindTag.classId == .documentKind,
          try notebookTagAssignment(
            notebookId: notebookId,
            tagId: kindTag.tagId,
            in: database
          ) != nil else {
      return false
    }
  }
  return true
}

func eventNotebookId(_ event: NoteAutoActionEvent, in database: SQLiteDatabase) throws -> NotebookID? {
  if let notebookId = event.notebookId {
    return notebookId
  }
  guard let noteId = event.noteId else {
    return nil
  }
  let rows = try database.query(
    "SELECT notebook_id FROM notes WHERE note_id = ? LIMIT 1",
    bindings: [.id(noteId)]
  )
  return rows.first?.identifier("notebook_id", as: NotebookID.self)
}

func noteTagNames(noteId: NoteID, in database: SQLiteDatabase) throws -> [String] {
  try database.query(
    """
    SELECT t.name
    FROM note_tags nt
    INNER JOIN tags t ON t.tag_id = nt.tag_id
    WHERE nt.note_id = ?
    ORDER BY t.name
    """,
    bindings: [.id(noteId)]
  ).compactMap { $0["name"] }
}
