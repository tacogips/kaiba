import Foundation

// The action history model behind undo/redo
// (`design-docs/specs/action-history-undo.md`). Entries live in the
// append-only `note_action_log` table; the undo/redo "stacks" are queries over
// it (U3), and payloads are deltas rather than copies of live data (U4).

/// What kind of store object an action touched.
public enum NoteActionEntityType: String, Sendable {
  case note
  case notebook
  case comment
}

/// The verbs the log records. `action` is stored without a CHECK constraint so
/// a build that predates a verb can still read the row; parsing keeps the raw
/// string for that reason.
public enum NoteActionKind: String, Sendable {
  case noteCreated = "note-created"
  case noteBodyUpdated = "note-body-updated"
  case noteTagsApplied = "note-tags-applied"
  case noteTagRemoved = "note-tag-removed"
  case noteReadOnlySet = "note-read-only-set"
  case noteDeleted = "note-deleted"
  case notebookCreated = "notebook-created"
  case notebookReadOnlySet = "notebook-read-only-set"
  case notebookDeleted = "notebook-deleted"
  case notebookIngested = "notebook-ingested"
  case commentAdded = "comment-added"
  case undone
  case redone

  /// Creation-shaped actions store no content at record time; their snapshot
  /// is captured only when they are undone (U4, the deferred snapshot).
  var isCreationShaped: Bool {
    switch self {
    case .noteCreated, .notebookCreated, .commentAdded:
      return true
    case .noteBodyUpdated, .noteTagsApplied, .noteTagRemoved, .noteReadOnlySet,
         .noteDeleted, .notebookReadOnlySet, .notebookDeleted, .notebookIngested,
         .undone, .redone:
      return false
    }
  }
}

/// One row of the action log.
public struct NoteActionLogEntry: Equatable, Sendable {
  public var seq: Int64
  public var occurredAt: String
  public var actorUserId: UserID
  public var provenance: NoteProvenance
  public var entityType: NoteActionEntityType
  public var entityId: String
  public var notebookId: NotebookID?
  /// The verb as stored. Kept raw so rows written by a newer build survive
  /// listing; anything undo/redo must act on goes through `kind`.
  public var action: String
  public var display: JSONValue
  public var delta: JSONValue?
  public var undoable: Bool
  public var undoOfSeq: Int64?
  public var undoneBySeq: Int64?

  public var kind: NoteActionKind? {
    NoteActionKind(rawValue: action)
  }
}

/// Input to `recordAction`: everything of an entry the recorder does not
/// stamp itself (seq, timestamp, actor).
struct NoteActionRecord {
  var kind: NoteActionKind
  var provenance: NoteProvenance
  var entityType: NoteActionEntityType
  var entityId: String
  var notebookId: NotebookID?
  var display: JSONObject
  var delta: JSONValue?
  var undoable: Bool
  var undoOfSeq: Int64?

  init(
    kind: NoteActionKind,
    provenance: NoteProvenance,
    entityType: NoteActionEntityType,
    entityId: String,
    notebookId: NotebookID?,
    display: JSONObject,
    delta: JSONValue? = nil,
    undoable: Bool,
    undoOfSeq: Int64? = nil
  ) {
    self.kind = kind
    self.provenance = provenance
    self.entityType = entityType
    self.entityId = entityId
    self.notebookId = notebookId
    self.display = display
    self.delta = delta
    self.undoable = undoable
    self.undoOfSeq = undoOfSeq
  }
}

/// The current undo/redo affordances for one actor: what `undo` would revert
/// and what `redo` would re-apply, if anything.
public struct NoteUndoState: Equatable, Sendable {
  /// The entry `undoLastAction` would target.
  public var undoTarget: NoteActionLogEntry?
  /// The `undone` entry `redoLastAction` would consume. Its `undoOfSeq` names
  /// what gets re-applied.
  public var redoTarget: NoteActionLogEntry?
}

/// The outcome of an undo or redo: the freshly appended `undone`/`redone`
/// entry and the entry it acted on.
public struct NoteActionUndoResult: Equatable, Sendable {
  public var entry: NoteActionLogEntry
  public var target: NoteActionLogEntry
}

// MARK: - Body splice patch

/// A note-body edit as the changed span only (U4): the common prefix and
/// suffix of the two versions are dropped, and just the differing middle is
/// kept, in both directions. `p`/`s` are UTF-8 byte counts of the shared
/// prefix/suffix; both boundaries fall on character boundaries of *both*
/// versions, so splicing bytes always reassembles valid UTF-8.
public struct NoteBodyPatch: Equatable, Sendable {
  public var prefixByteCount: Int
  public var suffixByteCount: Int
  /// The middle of the pre-edit body.
  public var removed: String
  /// The middle of the post-edit body.
  public var inserted: String

  public var jsonValue: JSONValue {
    .object([
      "p": .integer(Int64(prefixByteCount)),
      "s": .integer(Int64(suffixByteCount)),
      "del": .string(removed),
      "ins": .string(inserted)
    ])
  }

  public init(prefixByteCount: Int, suffixByteCount: Int, removed: String, inserted: String) {
    self.prefixByteCount = prefixByteCount
    self.suffixByteCount = suffixByteCount
    self.removed = removed
    self.inserted = inserted
  }

  public init?(jsonValue: JSONValue) {
    guard let prefix = jsonValue["p"]?.asInt,
          let suffix = jsonValue["s"]?.asInt,
          prefix >= 0, suffix >= 0 else {
      return nil
    }
    // "del"/"ins" read via the raw object so an explicit empty string is kept;
    // the member subscript treats `.null` as absent, which also works here.
    self.prefixByteCount = prefix
    self.suffixByteCount = suffix
    self.removed = jsonValue["del"]?.asString ?? ""
    self.inserted = jsonValue["ins"]?.asString ?? ""
  }
}

public enum NoteBodyPatchDirection: Sendable {
  /// Current text is the post-edit version; produce the pre-edit one.
  case undo
  /// Current text is the pre-edit version; produce the post-edit one.
  case redo
}

/// The changed span between two body versions, or nil when they are equal.
/// Comparison walks extended grapheme clusters so both cut points are
/// character boundaries in both strings.
public func makeNoteBodyPatch(from old: String, to new: String) -> NoteBodyPatch? {
  guard old != new else {
    return nil
  }
  let oldChars = Array(old)
  let newChars = Array(new)
  var prefix = 0
  while prefix < oldChars.count, prefix < newChars.count, oldChars[prefix] == newChars[prefix] {
    prefix += 1
  }
  var suffix = 0
  while suffix < oldChars.count - prefix,
        suffix < newChars.count - prefix,
        oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] {
    suffix += 1
  }
  let removed = String(oldChars[prefix..<(oldChars.count - suffix)])
  let inserted = String(newChars[prefix..<(newChars.count - suffix)])
  return NoteBodyPatch(
    prefixByteCount: String(oldChars[0..<prefix]).utf8.count,
    suffixByteCount: String(oldChars[(oldChars.count - suffix)...]).utf8.count,
    removed: removed,
    inserted: inserted
  )
}

/// Applies the patch in the given direction, or nil when the current text does
/// not carry the expected span at the expected place — the conflict guard
/// (U6): a mismatch refuses rather than corrupting.
public func applyNoteBodyPatch(
  _ patch: NoteBodyPatch,
  to current: String,
  direction: NoteBodyPatchDirection
) -> String? {
  let expected: String
  let replacement: String
  switch direction {
  case .undo:
    expected = patch.inserted
    replacement = patch.removed
  case .redo:
    expected = patch.removed
    replacement = patch.inserted
  }
  let currentBytes = Array(current.utf8)
  let expectedBytes = Array(expected.utf8)
  let prefix = patch.prefixByteCount
  let suffix = patch.suffixByteCount
  guard currentBytes.count == prefix + expectedBytes.count + suffix,
        Array(currentBytes[prefix..<(prefix + expectedBytes.count)]) == expectedBytes else {
    return nil
  }
  var resultBytes = Array(currentBytes[0..<prefix])
  resultBytes.append(contentsOf: Array(replacement.utf8))
  resultBytes.append(contentsOf: currentBytes[(currentBytes.count - suffix)...])
  // The cut points are character boundaries of both versions (see
  // `makeNoteBodyPatch`), so this reassembly cannot fail on well-formed
  // patches; a corrupted patch answers nil like any other guard failure.
  return String(bytes: resultBytes, encoding: .utf8)
}

// MARK: - Row parsing

/// Columns every action-log SELECT must project. `json(...)` unwraps the JSONB
/// blobs into text the row reader can hand back.
let noteActionLogColumns = """
  seq, occurred_at, actor_user_id, provenance, entity_type, entity_id,
  notebook_id, action, json(display_json) AS display_json,
  CASE WHEN delta_json IS NULL THEN NULL ELSE json(delta_json) END AS delta_json,
  undoable, undo_of_seq, undone_by_seq
  """

func noteActionLogEntry(from row: SQLiteRow) throws -> NoteActionLogEntry {
  guard let seqText = row["seq"], let seq = Int64(seqText),
        let occurredAt = row["occurred_at"],
        let actorUserId = row.identifier("actor_user_id", as: UserID.self),
        let provenance = row["provenance"].flatMap(NoteProvenance.init(rawValue:)),
        let entityType = row["entity_type"].flatMap(NoteActionEntityType.init(rawValue:)),
        let entityId = row["entity_id"],
        let action = row["action"],
        let displayText = row["display_json"] else {
    throw NoteServiceError.invalidRow("action log row is missing required fields")
  }
  return NoteActionLogEntry(
    seq: seq,
    occurredAt: occurredAt,
    actorUserId: actorUserId,
    provenance: provenance,
    entityType: entityType,
    entityId: entityId,
    notebookId: row.identifier("notebook_id", as: NotebookID.self),
    action: action,
    display: try JSONValue(parsing: displayText),
    delta: try row["delta_json"].map { try JSONValue(parsing: $0) },
    undoable: row["undoable"] == "1",
    undoOfSeq: row["undo_of_seq"].flatMap(Int64.init),
    undoneBySeq: row["undone_by_seq"].flatMap(Int64.init)
  )
}
