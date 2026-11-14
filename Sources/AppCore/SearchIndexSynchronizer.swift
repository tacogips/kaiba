import Foundation

/// Counts one or more durable search-index drain passes (design SE3).
public struct SearchIndexDrainReport: Equatable, Sendable {
  public let pushed: Int
  public let failed: Int
  public let remaining: Int
  public let remainingDue: Int

  public init(pushed: Int, failed: Int, remaining: Int, remainingDue: Int) {
    self.pushed = pushed
    self.failed = failed
    self.remaining = remaining
    self.remainingDue = remainingDue
  }
}

/// Drains the store's durable outbox without performing engine I/O in a store transaction.
public struct SearchIndexSynchronizer: Sendable {
  private let service: NoteService
  private let now: @Sendable () -> Date

  public init(service: NoteService, now: @escaping @Sendable () -> Date = { Date() }) {
    self.service = service
    self.now = now
  }

  /// Pushes one claimed batch, then settles each result through the SE3 outbox.
  public func drainOnce(
    engine: any SearchEngine,
    batchSize: Int = 100
  ) async throws -> SearchIndexDrainReport {
    let claimToken = UUID().uuidString
    let rows = try service.claimSearchIndexOutbox(limit: batchSize, claimToken: claimToken, now: now())
    guard !rows.isEmpty else {
      return try report(pushed: 0, failed: 0)
    }

    let built = try service.driver.withDatabase { database -> (
      [(SearchIndexOutboxRow, SearchIndexOperation)], [SearchIndexOutboxFailure]
    ) in
      var operations: [(SearchIndexOutboxRow, SearchIndexOperation)] = []
      var failures: [SearchIndexOutboxFailure] = []
      operations.reserveCapacity(rows.count)
      failures.reserveCapacity(rows.count)

      for row in rows {
        do {
          if let document = try searchIndexDocument(noteId: row.noteId, in: database) {
            operations.append((row, .upsert(document)))
          } else {
            operations.append((row, .delete(row.noteId)))
          }
        } catch {
          failures.append(SearchIndexOutboxFailure(row: row, message: "document build failed: \(error)"))
        }
      }
      return (operations, failures)
    }

    var succeeded: [SearchIndexOutboxRow] = []
    var failures = built.1
    if !built.0.isEmpty {
      let operations = built.0.map(\.1)
      do {
        let results = try await engine.apply(operations)
        let resultsById = Dictionary(results.map { ($0.noteId, $0.outcome) }, uniquingKeysWith: { _, last in last })
        for (row, _) in built.0 {
          guard let outcome = resultsById[row.noteId] else {
            failures.append(SearchIndexOutboxFailure(row: row, message: "missing result"))
            continue
          }
          switch outcome {
          case .succeeded:
            succeeded.append(row)
          case let .failed(message):
            failures.append(SearchIndexOutboxFailure(row: row, message: message))
          }
        }
      } catch {
        for row in rows where !failures.contains(where: { $0.row.noteId == row.noteId }) {
          failures.append(SearchIndexOutboxFailure(row: row, message: String(describing: error)))
        }
      }
    }

    try service.settleSearchIndexOutbox(
      succeeded: succeeded,
      failed: failures,
      claimToken: claimToken,
      now: now()
    )
    return try report(pushed: succeeded.count, failed: failures.count)
  }

  /// Drains due work until no due rows remain or a pass makes no progress.
  public func drainUntilIdle(
    engine: any SearchEngine,
    batchSize: Int = 100
  ) async throws -> SearchIndexDrainReport {
    var pushed = 0
    var failed = 0
    var latest = try report(pushed: 0, failed: 0)
    repeat {
      latest = try await drainOnce(engine: engine, batchSize: batchSize)
      pushed += latest.pushed
      failed += latest.failed
      if latest.remainingDue == 0 || latest.pushed == 0 { break }
    } while true
    return SearchIndexDrainReport(
      pushed: pushed,
      failed: failed,
      remaining: latest.remaining,
      remainingDue: latest.remainingDue
    )
  }

  private func report(pushed: Int, failed: Int) throws -> SearchIndexDrainReport {
    let status = try service.searchIndexOutboxStatus(now: now())
    return SearchIndexDrainReport(
      pushed: pushed,
      failed: failed,
      remaining: status.pending,
      remainingDue: status.due
    )
  }
}

/// Builds the same indexed fields as `currentFTSPayload`, plus access metadata.
func searchIndexDocument(noteId: NoteID, in database: SQLiteDatabase) throws -> SearchIndexDocument? {
  guard !(try database.query(
    "SELECT 1 FROM notes WHERE note_id = ? LIMIT 1",
    bindings: [.id(noteId)]
  )).isEmpty else { return nil }

  let note = try loadNote(noteId, in: database)
  guard let notebookRow = try database.query(
    "SELECT library_id, owner_user_id FROM notebooks WHERE notebook_id = ? LIMIT 1",
    bindings: [.id(note.notebookId)]
  ).first,
        let libraryId = notebookRow.identifier("library_id", as: LibraryID.self) else {
    throw NoteServiceError.invalidRow("notebook library metadata missing for note \(noteId)")
  }
  let tags = note.tags.map(\.tag).sorted {
    if $0.name == $1.name { return $0.tagId < $1.tagId }
    return $0.name < $1.name
  }
  let linkedNotes = try searchIndexLinkedNoteIds(noteId: noteId, in: database)
  return SearchIndexDocument(
    noteId: note.noteId,
    notebookId: note.notebookId,
    libraryId: libraryId,
    ownerUserId: notebookRow["owner_user_id"].map(UserID.init),
    title: note.title ?? "",
    body: noteRetrievalText(
      bodyMarkdown: note.bodyMarkdown,
      searchText: try noteSearchText(noteId, in: database)
    ),
    tagIds: tags.map(\.tagId).sorted(),
    tagNames: tags.map(\.name),
    context: try ftsContextPayload(noteId: noteId, in: database),
    isLongTermMemory: try isLongTermMemoryDocumentNotebook(note.notebookId, in: database),
    createdAt: note.createdAt,
    updatedAt: note.updatedAt,
    tagApplications: try searchIndexTagApplications(noteId: noteId, in: database),
    pathTags: try searchIndexPathTags(directTagIds: tags.map(\.tagId), in: database),
    outgoingLinkNoteIds: linkedNotes.outgoing,
    incomingLinkNoteIds: linkedNotes.incoming
  )
}

private func isLongTermMemoryDocumentNotebook(_ notebookId: NotebookID, in database: SQLiteDatabase) throws -> Bool {
  try !database.query(
    "SELECT 1 FROM notebook_tags WHERE notebook_id = ? AND tag_id = ? LIMIT 1",
    bindings: [.id(notebookId), .id(NoteStoreSchema.longTermMemoryNotebookKindTagId)]
  ).isEmpty
}
