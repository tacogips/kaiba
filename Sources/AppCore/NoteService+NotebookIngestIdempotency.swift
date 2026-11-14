import Foundation

final class NotebookIngestExecutionRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var activeScopeKeys: Set<String> = []
  private var releaseWaiters: [String: [UUID: AsyncStream<Void>.Continuation]] = [:]

  func acquire(_ scopeKey: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return activeScopeKeys.insert(scopeKey).inserted
  }

  func release(_ scopeKey: String) {
    let waiters: [AsyncStream<Void>.Continuation]
    lock.lock()
    activeScopeKeys.remove(scopeKey)
    waiters = releaseWaiters.removeValue(forKey: scopeKey).map { Array($0.values) } ?? []
    lock.unlock()
    waiters.forEach {
      $0.yield()
      $0.finish()
    }
  }

  func waitForRelease(_ scopeKey: String, timeout: Duration) async throws {
    guard timeout > .zero else { return }
    let notifications = releaseNotifications(for: scopeKey)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for await _ in notifications {
          return
        }
        try Task.checkCancellation()
      }
      group.addTask {
        try await Task.sleep(for: timeout)
      }
      defer { group.cancelAll() }
      _ = try await group.next()
    }
  }

  private func releaseNotifications(for scopeKey: String) -> AsyncStream<Void> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let waiterId = UUID()
      lock.lock()
      guard activeScopeKeys.contains(scopeKey) else {
        lock.unlock()
        continuation.yield()
        continuation.finish()
        return
      }
      releaseWaiters[scopeKey, default: [:]][waiterId] = continuation
      lock.unlock()
      continuation.onTermination = { [weak self] _ in
        self?.removeReleaseWaiter(scopeKey: scopeKey, waiterId: waiterId)
      }
    }
  }

  private func removeReleaseWaiter(scopeKey: String, waiterId: UUID) {
    lock.lock()
    releaseWaiters[scopeKey]?[waiterId] = nil
    if releaseWaiters[scopeKey]?.isEmpty == true {
      releaseWaiters[scopeKey] = nil
    }
    lock.unlock()
  }
}

package struct NotebookIngestRequestIdentity: Equatable, Sendable {
  package let scopeKey: String
  package let requestDigest: String
  let settingKey: String
}

package struct NotebookIngestRequestRecovery: Equatable, Sendable {
  package let identity: NotebookIngestRequestIdentity
  package let notebookId: NotebookID
  package let noteIds: [NoteID]
  package let resultJSON: String
  package let enqueueAutoActions: Bool
  package let originatingActionId: AutoActionID?
}

package struct NotebookIngestRequestCreated: Equatable, Sendable {
  package let identity: NotebookIngestRequestIdentity
  package let notebookId: NotebookID
  package let noteIds: [NoteID]
}

package enum NotebookIngestRequestClaim: Equatable, Sendable {
  case execute(NotebookIngestRequestIdentity)
  case replay(String)
  case pending(NotebookIngestRequestIdentity)
  case resume(NotebookIngestRequestCreated)
  case recover(NotebookIngestRequestRecovery)
}

package extension NoteService {
  /// Claims one principal-scoped ingest request. The canonical request must not
  /// include transport-only state; identical completed requests replay their
  /// exact GraphQL result while changed input under the same key is rejected.
  func claimNotebookIngestRequest(
    idempotencyKey: String,
    canonicalRequest: Data
  ) throws -> NotebookIngestRequestClaim {
    let key = idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty, key.utf8.count <= 256,
          !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
      throw NoteServiceError.invalidInput("ingest idempotency key must be 1...256 non-control UTF-8 bytes")
    }
    let principal = writeOwnerUserId()
    let scopeHash = sha256Hex(Data("\(principal.rawValue)\u{0}\(key)".utf8))
    let identity = NotebookIngestRequestIdentity(
      scopeKey: scopeHash,
      requestDigest: sha256Hex(canonicalRequest),
      settingKey: "auth.ingest.\(scopeHash.prefix(40))"
    )
    let claim: NotebookIngestRequestClaim = try driver.withDatabase { database in
      try database.transaction { db in
        if let stored = try notebookIngestRecord(settingKey: identity.settingKey, in: db) {
          guard stored["requestDigest"]?.asString == identity.requestDigest else {
            throw NoteServiceError.invalidInput(
              "ingest idempotency key conflicts with a different request"
            )
          }
          if stored["state"]?.asString == "completed",
             let resultJSON = stored["resultJSON"]?.asString {
            return .replay(resultJSON)
          }
          if stored["state"]?.asString == "recovery" {
            return .recover(try notebookIngestRecovery(identity: identity, stored: stored))
          }
          if stored["state"]?.asString == "created" {
            return .resume(try notebookIngestCreated(identity: identity, stored: stored))
          }
          if stored["state"]?.asString == "pending" {
            // The process-local registry distinguishes a live executor from a
            // durable claim left behind by a stopped process.
            return .execute(identity)
          }
          throw NoteServiceError.invalidRow("invalid notebook ingest request state")
        }
        try writeNotebookIngestRecord(
          settingKey: identity.settingKey,
          value: .object([
            "requestDigest": .string(identity.requestDigest),
            "state": .string("pending")
          ]),
          in: db
        )
        return .execute(identity)
      }
    }
    switch claim {
    case let .execute(identity):
      guard notebookIngestExecutionRegistry.acquire(identity.scopeKey) else {
        return .pending(identity)
      }
    case let .resume(created):
      guard notebookIngestExecutionRegistry.acquire(created.identity.scopeKey) else {
        return .pending(created.identity)
      }
    default:
      break
    }
    return claim
  }

  func waitForNotebookIngestExecutionChange(
    _ identity: NotebookIngestRequestIdentity,
    timeout: Duration
  ) async throws {
    try await notebookIngestExecutionRegistry.waitForRelease(identity.scopeKey, timeout: timeout)
  }

  /// Returns a capability-limited copy for the owner of a claimed ingest.
  /// Its intermediate mutations stay hidden and produce no change-feed events.
  func pendingNotebookIngestScope() -> NoteService {
    var copy = self
    copy.allowsPendingNotebookIngestAccess = true
    copy.suppressesChangePublication = true
    copy.suppressesActionHistory = true
    return copy
  }

  /// Creates the hidden notebook and persists its exact identities in the
  /// same transaction. A process may stop immediately after commit and a
  /// later request can deterministically resume reconciliation.
  func createClaimedNotebookIngest(
    _ identity: NotebookIngestRequestIdentity,
    title: String,
    kindTagName: String?,
    callerMetadataJSON: String?,
    pages: [NotePageDraft],
    originatingActionId: AutoActionID?
  ) throws -> NotebookIngestResult {
    guard !pages.isEmpty else {
      throw NoteServiceError.invalidInput("notebook ingest pages must not be empty")
    }
    try validateNotebookIngestPageNumbers(pages)
    let metadata = try pendingNotebookIngestMetadata(
      callerMetadataJSON: callerMetadataJSON,
      identity: identity
    )
    return try driver.withDatabase { database in
      try database.transaction { db in
        guard let stored = try notebookIngestRecord(settingKey: identity.settingKey, in: db),
              stored["requestDigest"]?.asString == identity.requestDigest,
              stored["state"]?.asString == "pending" else {
          throw NoteServiceError.conflict("ingest request is not pending")
        }
        let existingTagIds = Set(try db.query("SELECT tag_id FROM tags").compactMap {
          $0.identifier("tag_id", as: TagID.self)
        })
        let pendingCreator = pendingNotebookIngestScope()
        let inserted = try pendingCreator.insertNotebookWithNotes(
          title: title,
          kindTagName: kindTagName,
          metaJSON: metadata,
          pages: pages,
          notebookReadOnly: false,
          provenance: .system,
          assignedBy: "kaiba-note-ingest",
          originatingActionId: originatingActionId,
          enqueueAutoActions: false,
          recordIngestAction: false,
          in: db
        )
        var ingestResult = inserted.ingestResult
        let assignedTagIds = Set(
          ingestResult.notebook.tags.map(\.tag.tagId)
            + ingestResult.notes.flatMap { $0.tags.map(\.tag.tagId) }
        )
        let createdTagIds = assignedTagIds.subtracting(existingTagIds)
        if !createdTagIds.isEmpty {
          let trackedMetadata = try pendingNotebookIngestMetadata(
            callerMetadataJSON: callerMetadataJSON,
            identity: identity,
            createdTagIds: createdTagIds
          )
          try db.execute(
            "UPDATE notebooks SET meta_json = jsonb(?) WHERE notebook_id = ?",
            bindings: [.text(trackedMetadata), .id(ingestResult.notebook.notebookId)]
          )
          ingestResult.notebook.metaJSON = trackedMetadata
        }
        try writeNotebookIngestRecord(
          settingKey: identity.settingKey,
          value: .object([
            "notebookId": .string(ingestResult.notebook.notebookId.rawValue),
            "noteIds": .array(ingestResult.notes.map { .string($0.noteId.rawValue) }),
            "requestDigest": .string(identity.requestDigest),
            "state": .string("created")
          ]),
          in: db
        )
        return ingestResult
      }
    }
  }

  func pendingNotebookIngestMetadata(
    callerMetadataJSON: String?,
    identity: NotebookIngestRequestIdentity
  ) throws -> String {
    try pendingNotebookIngestMetadata(
      callerMetadataJSON: callerMetadataJSON,
      identity: identity,
      createdTagIds: []
    )
  }

  static func pendingNotebookIngestCreatedTagIds(_ metaJSON: String?) -> Set<TagID> {
    guard let metaJSON,
          let root = try? JSONValue(parsing: metaJSON),
          let ingest = root["_kaibaNotebookIngest"]?.asObject,
          ingest["state"]?.asString == "pending" else { return [] }
    return Set(ingest["createdTagIds"]?.asArray?.compactMap(\.asString).map(TagID.init) ?? [])
  }

  private func pendingNotebookIngestMetadata(
    callerMetadataJSON: String?,
    identity: NotebookIngestRequestIdentity,
    createdTagIds: Set<TagID>
  ) throws -> String {
    var metadata = try notebookIngestCallerMetadata(callerMetadataJSON)
    var ingestMetadata: JSONObject = [
      "scopeKey": .string(identity.scopeKey),
      "state": .string("pending")
    ]
    if !createdTagIds.isEmpty {
      ingestMetadata["createdTagIds"] = .array(
        createdTagIds.sorted().map { .string($0.rawValue) }
      )
    }
    metadata["_kaibaNotebookIngest"] = .object(ingestMetadata)
    return try JSONValue.object(metadata).encodedString()
  }

  /// Validates caller metadata before the durable idempotency claim is written.
  func validateNotebookIngestMetadata(_ callerMetadataJSON: String?) throws {
    _ = try notebookIngestCallerMetadata(callerMetadataJSON)
  }

  /// Atomically reveals a terminal ingest, persists its replay result and,
  /// for a successful ingest, makes deferred auto-actions eligible. Exactly
  /// one finalized change follows the transaction.
  func completeNotebookIngestRequest(
    _ identity: NotebookIngestRequestIdentity,
    ingest: NotebookIngestResult,
    resultJSON: String,
    enqueueAutoActions shouldEnqueueAutoActions: Bool,
    originatingActionId: AutoActionID? = nil
  ) throws {
    let outcome = try driver.withDatabase { database in
      try database.transaction { db -> (Notebook, [QueuedAutoActionDispatch]) in
        guard let stored = try notebookIngestRecord(settingKey: identity.settingKey, in: db),
              stored["requestDigest"]?.asString == identity.requestDigest,
              ["created", "recovery"].contains(stored["state"]?.asString) else {
          throw NoteServiceError.conflict("ingest request is not pending")
        }
        let ingestScope = pendingNotebookIngestScope()
        let notebook = try ingestScope.requireNotebook(ingest.notebook.notebookId, in: db)
        guard Self.pendingNotebookIngestScopeKey(notebook.metaJSON) == identity.scopeKey else {
          throw NoteServiceError.conflict("ingest notebook does not belong to the request")
        }
        let notes = try ingest.notes.map { note in
          let current = try ingestScope.requireNote(note.noteId, in: db)
          guard current.notebookId == notebook.notebookId else {
            throw NoteServiceError.invalidInput("deferred ingest note does not belong to its notebook")
          }
          return current
        }
        var dispatches: [QueuedAutoActionDispatch] = []
        if shouldEnqueueAutoActions {
          dispatches = try ingestScope.enqueueAutoActions(
            for: ingestScope.makeAutoActionEvent(
              trigger: .notebookCreated,
              notebookId: notebook.notebookId,
              originatingActionId: originatingActionId
            ),
            in: db
          )
          for note in notes {
            dispatches.append(contentsOf: try ingestScope.enqueueAutoActions(
              for: ingestScope.makeAutoActionEvent(
                trigger: .noteCreated,
                notebookId: notebook.notebookId,
                noteId: note.noteId,
                noteBodyMarkdown: note.bodyMarkdown,
                originatingActionId: originatingActionId
              ),
              in: db
            ))
          }
        }
        var metadata = (try? notebook.metaJSON.flatMap { try JSONValue(parsing: $0).asObject }) ?? [:]
        metadata.removeValue(forKey: "_kaibaNotebookIngest")
        let cleanMetadata = metadata.isEmpty ? nil : try JSONValue.object(metadata).encodedString()
        let existingIngestAction = try db.query(
          "SELECT 1 FROM note_action_log WHERE notebook_id = ? AND action = ? LIMIT 1",
          bindings: [.id(notebook.notebookId), .text(NoteActionKind.notebookIngested.rawValue)]
        ).isEmpty == false
        if !existingIngestAction {
          var terminalRecorder = self
          terminalRecorder.suppressesActionHistory = false
          try terminalRecorder.recordAction(
            NoteActionRecord(
              kind: .notebookIngested,
              provenance: .system,
              entityType: .notebook,
              entityId: notebook.notebookId.rawValue,
              notebookId: notebook.notebookId,
              display: [
                "title": .string(notebook.title),
                "noteCount": .integer(Int64(notes.count))
              ],
              undoable: false
            ),
            in: db
          )
        }
        try db.execute(
          "UPDATE notebooks SET meta_json = ? WHERE notebook_id = ?",
          bindings: [.optionalText(cleanMetadata), .id(notebook.notebookId)]
        )
        try writeNotebookIngestRecord(
          settingKey: identity.settingKey,
          value: .object([
            "requestDigest": .string(identity.requestDigest),
            "resultJSON": .string(resultJSON),
            "state": .string("completed")
          ]),
          in: db
        )
        var finalized = notebook
        finalized.metaJSON = cleanMetadata
        return (finalized, dispatches)
      }
    }
    dispatchQueuedAutoActions(outcome.1)
    changeObserver?.noteStoreDidChange(NoteChangeEvent(
      kind: NoteChangeEventKind.notebookCreated,
      notebookId: outcome.0.notebookId,
      tagNames: folderTagNames(of: outcome.0)
    ))
    notebookIngestExecutionRegistry.release(identity.scopeKey)
  }

  /// Persists enough committed identity and terminal-result evidence to retry
  /// only the reveal transition after a transactional completion fault.
  func recordNotebookIngestRecovery(
    _ identity: NotebookIngestRequestIdentity,
    ingest: NotebookIngestResult,
    resultJSON: String,
    enqueueAutoActions: Bool,
    originatingActionId: AutoActionID? = nil
  ) throws {
    try driver.withDatabase { database in
      try database.transaction { db in
        guard let stored = try notebookIngestRecord(settingKey: identity.settingKey, in: db),
              stored["requestDigest"]?.asString == identity.requestDigest,
              ["created", "recovery"].contains(stored["state"]?.asString) else {
          throw NoteServiceError.conflict("ingest request is not pending")
        }
        let ingestScope = pendingNotebookIngestScope()
        let notebook = try ingestScope.requireNotebook(ingest.notebook.notebookId, in: db)
        guard Self.pendingNotebookIngestScopeKey(notebook.metaJSON) == identity.scopeKey else {
          throw NoteServiceError.conflict("ingest notebook does not belong to the request")
        }
        for note in ingest.notes {
          guard try ingestScope.requireNote(note.noteId, in: db).notebookId == notebook.notebookId else {
            throw NoteServiceError.invalidInput("deferred ingest note does not belong to its notebook")
          }
        }
        var recovery: JSONObject = [
          "enqueueAutoActions": .bool(enqueueAutoActions),
          "notebookId": .string(notebook.notebookId.rawValue),
          "noteIds": .array(ingest.notes.map { .string($0.noteId.rawValue) }),
          "requestDigest": .string(identity.requestDigest),
          "resultJSON": .string(resultJSON),
          "state": .string("recovery")
        ]
        if let originatingActionId {
          recovery["originatingActionId"] = .string(originatingActionId.rawValue)
        }
        try writeNotebookIngestRecord(
          settingKey: identity.settingKey,
          value: .object(recovery),
          in: db
        )
      }
    }
    notebookIngestExecutionRegistry.release(identity.scopeKey)
  }

  func abandonNotebookIngestRequest(_ identity: NotebookIngestRequestIdentity) throws {
    try driver.withDatabase { database in
      try database.execute(
        "DELETE FROM app_settings WHERE setting_key = ? AND json_extract(value_json, '$.state') = 'pending'",
        bindings: [.text(identity.settingKey)]
      )
    }
    notebookIngestExecutionRegistry.release(identity.scopeKey)
  }

  func releaseNotebookIngestExecution(_ identity: NotebookIngestRequestIdentity) {
    notebookIngestExecutionRegistry.release(identity.scopeKey)
  }

  func completedNotebookIngestResult(
    _ identity: NotebookIngestRequestIdentity
  ) throws -> String? {
    try driver.withDatabase { database in
      guard let stored = try notebookIngestRecord(settingKey: identity.settingKey, in: database),
            stored["requestDigest"]?.asString == identity.requestDigest,
            stored["state"]?.asString == "completed" else { return nil }
      return stored["resultJSON"]?.asString
    }
  }

  func recoverableNotebookIngestRequest(
    _ identity: NotebookIngestRequestIdentity
  ) throws -> NotebookIngestRequestRecovery? {
    try driver.withDatabase { database in
      guard let stored = try notebookIngestRecord(settingKey: identity.settingKey, in: database),
            stored["requestDigest"]?.asString == identity.requestDigest,
            stored["state"]?.asString == "recovery" else { return nil }
      return try notebookIngestRecovery(identity: identity, stored: stored)
    }
  }

  func createdNotebookIngestRequest(
    _ identity: NotebookIngestRequestIdentity
  ) throws -> NotebookIngestRequestCreated? {
    try driver.withDatabase { database in
      guard let stored = try notebookIngestRecord(settingKey: identity.settingKey, in: database),
            stored["requestDigest"]?.asString == identity.requestDigest,
            stored["state"]?.asString == "created" else { return nil }
      return try notebookIngestCreated(identity: identity, stored: stored)
    }
  }

  static func isPendingNotebookIngestMetadata(_ metaJSON: String?) -> Bool {
    pendingNotebookIngestScopeKey(metaJSON) != nil
  }
}

extension NoteService {
  func rejectReservedNotebookIngestMetadata(_ metaJSON: String?) throws {
    guard !allowsPendingNotebookIngestAccess,
          let metaJSON,
          let metadata = (try? JSONValue(parsing: metaJSON))?.asObject else { return }
    if metadata["_kaibaNotebookIngest"] != nil {
      throw NoteServiceError.invalidInput("_kaibaNotebookIngest notebook metadata is server-managed")
    }
    if metadata[Self.deferredIngestLifecycleMetadataKey] != nil {
      throw NoteServiceError.invalidInput("deferred notebook ingest metadata is server-managed")
    }
  }
}

private extension NoteService {
  func notebookIngestCallerMetadata(_ callerMetadataJSON: String?) throws -> JSONObject {
    let metadata: JSONObject
    if let callerMetadataJSON {
      guard let object = (try? JSONValue(parsing: callerMetadataJSON))?.asObject else {
        throw NoteServiceError.invalidInput("ingest metaJSON must encode a JSON object")
      }
      metadata = object
    } else {
      metadata = [:]
    }
    guard metadata["_kaibaNotebookIngest"] == nil else {
      throw NoteServiceError.invalidInput("ingest metaJSON contains a reserved member")
    }
    return metadata
  }

  static func pendingNotebookIngestScopeKey(_ metaJSON: String?) -> String? {
    guard let metaJSON,
          let root = try? JSONValue(parsing: metaJSON),
          let ingest = root["_kaibaNotebookIngest"]?.asObject,
          ingest["state"]?.asString == "pending" else { return nil }
    return ingest["scopeKey"]?.asString
  }

  func notebookIngestRecord(settingKey: String, in db: SQLiteDatabase) throws -> JSONObject? {
    guard let text = try db.query(
      "SELECT json(value_json) AS value_json FROM app_settings WHERE setting_key = ? LIMIT 1",
      bindings: [.text(settingKey)]
    ).first?["value_json"] ?? nil else { return nil }
    guard let object = (try? JSONValue(parsing: text))?.asObject else {
      throw NoteServiceError.invalidRow("invalid notebook ingest request record")
    }
    return object
  }

  func writeNotebookIngestRecord(
    settingKey: String,
    value: JSONValue,
    in db: SQLiteDatabase
  ) throws {
    try db.execute(
      """
      INSERT INTO app_settings (setting_key, value_json, updated_at)
      VALUES (?, jsonb(?), ?)
      ON CONFLICT(setting_key) DO UPDATE SET
        value_json = excluded.value_json,
        updated_at = excluded.updated_at
      """,
      bindings: [
        .text(settingKey),
        .text(try value.encodedString()),
        .text(NoteStoreClock.system.now())
      ]
    )
  }

  func notebookIngestRecovery(
    identity: NotebookIngestRequestIdentity,
    stored: JSONObject
  ) throws -> NotebookIngestRequestRecovery {
    guard let notebookId = stored["notebookId"]?.asString,
          let noteIds = stored["noteIds"]?.asArray?.compactMap(\.asString),
          noteIds.count == stored["noteIds"]?.asArray?.count,
          let resultJSON = stored["resultJSON"]?.asString,
          let enqueueAutoActions = stored["enqueueAutoActions"]?.asBool else {
      throw NoteServiceError.invalidRow("invalid notebook ingest recovery record")
    }
    return NotebookIngestRequestRecovery(
      identity: identity,
      notebookId: NotebookID(notebookId),
      noteIds: noteIds.map(NoteID.init),
      resultJSON: resultJSON,
      enqueueAutoActions: enqueueAutoActions,
      originatingActionId: stored["originatingActionId"]?.asString.map(AutoActionID.init)
    )
  }

  func notebookIngestCreated(
    identity: NotebookIngestRequestIdentity,
    stored: JSONObject
  ) throws -> NotebookIngestRequestCreated {
    guard let notebookId = stored["notebookId"]?.asString,
          let noteIds = stored["noteIds"]?.asArray?.compactMap(\.asString),
          noteIds.count == stored["noteIds"]?.asArray?.count else {
      throw NoteServiceError.invalidRow("invalid created notebook ingest record")
    }
    return NotebookIngestRequestCreated(
      identity: identity,
      notebookId: NotebookID(notebookId),
      noteIds: noteIds.map(NoteID.init)
    )
  }
}
