import Foundation

/// One consolidated memory: the summary an aggregation pass produced from a set
/// of source notes, plus the window it covers and the notes it came from.
public struct LongTermMemoryEntryInput: Equatable, Sendable {
  public var bodyMarkdown: String
  public var topicTags: [String]
  /// Notes this entry was consolidated from. Ids that no longer resolve are kept
  /// in metadata instead of becoming links, so a memory survives the deletion of
  /// the short-term notes it was distilled from.
  public var sourceNoteIds: [NoteID]
  public var relatedNoteIds: [NoteID]
  public var periodStart: Date?
  public var periodEnd: Date?
  /// Caller extras merged into the stored metadata. Must encode a JSON object;
  /// the reserved long-term-memory keys always win over colliding caller keys.
  public var metaJSON: String?

  public init(
    bodyMarkdown: String,
    topicTags: [String] = [],
    sourceNoteIds: [NoteID] = [],
    relatedNoteIds: [NoteID] = [],
    periodStart: Date? = nil,
    periodEnd: Date? = nil,
    metaJSON: String? = nil
  ) {
    self.bodyMarkdown = bodyMarkdown
    self.topicTags = topicTags
    self.sourceNoteIds = sourceNoteIds
    self.relatedNoteIds = relatedNoteIds
    self.periodStart = periodStart
    self.periodEnd = periodEnd
    self.metaJSON = metaJSON
  }
}

public struct LongTermMemoryAppendResult: Equatable, Sendable {
  public var notes: [Note]
  /// True when the idempotency key had already been persisted and `notes` are
  /// the entries from that earlier append rather than newly written rows.
  public var idempotentReplay: Bool

  public init(notes: [Note], idempotentReplay: Bool) {
    self.notes = notes
    self.idempotentReplay = idempotentReplay
  }
}

/// A recall hit: either a direct full-text match inside the long-term notebook,
/// or a note reached from one of those matches through the note graph, in which
/// case the traversal evidence explains why it surfaced.
public struct LongTermMemoryRecallResult: Equatable, Sendable {
  public var note: Note
  public var snippet: String
  public var rank: Double
  public var isAssociation: Bool
  public var edgeKind: NoteGraphEdgeKind?
  public var weight: Double?
  public var hopCount: Int?
  public var pathNoteIds: [NoteID]

  public init(
    note: Note,
    snippet: String,
    rank: Double,
    isAssociation: Bool = false,
    edgeKind: NoteGraphEdgeKind? = nil,
    weight: Double? = nil,
    hopCount: Int? = nil,
    pathNoteIds: [NoteID] = []
  ) {
    self.note = note
    self.snippet = snippet
    self.rank = rank
    self.isAssociation = isAssociation
    self.edgeKind = edgeKind
    self.weight = weight
    self.hopCount = hopCount
    self.pathNoteIds = pathNoteIds
  }
}

extension NoteService {
  public static let longTermMemoryNotebookTitle = "Kaiba Long-Term Memory"
  public static let longTermMemorySourceLinkKind = "memory-source"
  public static let longTermMemoryRelatedLinkKind = "related"
  public static let longTermMemoryAssociationLinkKind = "memory-association"
  public static let longTermMemoryAssignedBy = "kaiba-long-term-memory"
  static let longTermMemoryMaximumLimit = 100
  public static let longTermMemoryDefaultRecencyWeight = 0.5
  static let longTermMemoryReservedTagPrefixes = ["notebook-kind:", "long-term-memory:"]

  @discardableResult
  func bootstrapLongTermMemoryNotebook() throws -> Notebook {
    try driver.withDatabase { database in
      try database.transaction { db in
        let notebookIds = try longTermMemoryNotebookIds(in: db)
        if notebookIds.count > 1 {
          throw NoteServiceError.invalidInput(
            "multiple notebooks carry \(NoteStoreSchema.longTermMemoryNotebookKindTag)"
          )
        }
        if let notebookId = notebookIds.first {
          try validateCanonicalLongTermMemoryNotebook(notebookId: notebookId, in: db)
          return try requireNotebook(notebookId, in: db)
        }

        let notebookId = NotebookID.generate()
        let now = NoteStoreClock.system.now()
        // Unlike the removed short-term store this notebook is not read-only
        // locked: consolidation runs through the ordinary public append path and
        // curators are expected to edit their own memories.
        try db.execute(
          """
          INSERT INTO notebooks (
            notebook_id, title, read_only, owner_user_id, created_by, updated_by,
            created_at, updated_at, meta_json
          ) VALUES (?, ?, 0, ?, ?, ?, ?, ?, NULL)
          """,
          bindings: [
            .id(notebookId),
            .text(Self.longTermMemoryNotebookTitle),
            .id(writeOwnerUserId()),
            .id(writeOwnerUserId()),
            .id(writeOwnerUserId()),
            .text(now),
            .text(now)
          ]
        )
        try applyNotebookTag(
          notebookId: notebookId,
          tagId: NoteStoreSchema.longTermMemoryNotebookKindTagId,
          provenance: .system,
          assignedBy: "kaiba-note",
          deletable: false,
          allowsLongTermMemoryIdentityCreation: true,
          in: db
        )
        return try requireNotebook(notebookId, in: db)
      }
    }
  }

  public func longTermMemoryNotebook() throws -> Notebook {
    try requireUnscopedLongTermMemoryAccess()
    return try driver.withDatabase { database in
      try requireNotebook(try requireLongTermMemoryNotebookId(in: database), in: database)
    }
  }

  /// Appends consolidated memories as notes in the canonical notebook.
  ///
  /// The whole batch is one transaction: a single unusable entry leaves no note,
  /// tag or link behind. Note ids are derived from `idempotencyKey`, so a retry
  /// of an interrupted call returns the already-persisted entries instead of
  /// duplicating them.
  @discardableResult
  public func appendLongTermMemoryNotes(
    _ entries: [LongTermMemoryEntryInput],
    idempotencyKey: String
  ) throws -> LongTermMemoryAppendResult {
    try requireUnscopedLongTermMemoryAccess()
    guard !entries.isEmpty else {
      throw NoteServiceError.invalidInput("long-term memory append requires at least one entry")
    }
    let normalizedKey = try normalizedLongTermMemoryIdempotencyKey(idempotencyKey)
    let normalizedEntries = try entries.map(normalizedLongTermMemoryEntry)
    let result = try driver.withDatabase { database in
      try database.transaction { db -> (result: LongTermMemoryAppendResult, dispatches: [QueuedAutoActionDispatch]) in
        let notebookId = try requireLongTermMemoryNotebookId(in: db)
        if let existing = try existingLongTermMemoryBatch(
          notebookId: notebookId,
          idempotencyKey: normalizedKey,
          expectedCount: normalizedEntries.count,
          in: db
        ) {
          return (
            LongTermMemoryAppendResult(notes: existing, idempotentReplay: true),
            []
          )
        }
        let now = NoteStoreClock.system.now()
        let firstNoteNumber = try nextNoteNumber(notebookId: notebookId, in: db)
        var notes: [Note] = []
        var dispatches: [QueuedAutoActionDispatch] = []
        for (index, entry) in normalizedEntries.enumerated() {
          let noteId = longTermMemoryNoteId(idempotencyKey: normalizedKey, index: index)
          try insertLongTermMemoryNote(
            noteId: noteId,
            notebookId: notebookId,
            noteNumber: firstNoteNumber + index,
            entry: entry,
            timestamp: now,
            in: db
          )
          notes.append(try requireNote(noteId, in: db))
          dispatches.append(contentsOf: try enqueueAutoActions(
            for: makeAutoActionEvent(
              trigger: .noteCreated,
              notebookId: notebookId,
              noteId: noteId,
              noteBodyMarkdown: entry.bodyMarkdown
            ),
            in: db
          ))
        }
        try db.execute(
          "UPDATE notebooks SET updated_at = ?, updated_by = owner_user_id WHERE notebook_id = ?",
          bindings: [.text(now), .id(notebookId)]
        )
        return (
          LongTermMemoryAppendResult(notes: notes, idempotentReplay: false),
          dispatches
        )
      }
    }
    dispatchQueuedAutoActions(result.dispatches)
    return result.result
  }

  /// Newest-first listing of the canonical notebook, optionally narrowed to
  /// entries whose aggregation window overlaps `periodStart...periodEnd` and
  /// that carry every tag in `tagFilters`. Entries without a stored window fall
  /// back to their creation timestamp.
  public func listLongTermMemoryNotes(
    periodStart: Date? = nil,
    periodEnd: Date? = nil,
    tagFilters: [String] = [],
    limit: Int = 20
  ) throws -> [Note] {
    try requireUnscopedLongTermMemoryAccess()
    let boundedLimit = max(1, min(limit, Self.longTermMemoryMaximumLimit))
    return try driver.withDatabase { database in
      let notebookId = try requireLongTermMemoryNotebookId(in: database)
      var sql = """
        SELECT n.note_id
        FROM notes n
        WHERE n.notebook_id = ?
          AND json_extract(n.meta_json, '$.longTermMemoryVersion') = 1
        """
      var bindings: [SQLiteValue] = [.id(notebookId)]
      if let periodStart {
        sql += """

          AND coalesce(
            json_extract(n.meta_json, '$.periodEnd'),
            json_extract(n.meta_json, '$.periodStart'),
            n.created_at
          ) >= ?
          """
        bindings.append(.text(longTermMemoryTimestamp(periodStart)))
      }
      if let periodEnd {
        sql += """

          AND coalesce(
            json_extract(n.meta_json, '$.periodStart'),
            json_extract(n.meta_json, '$.periodEnd'),
            n.created_at
          ) <= ?
          """
        bindings.append(.text(longTermMemoryTimestamp(periodEnd)))
      }
      for tagName in orderedUnique(tagFilters) {
        sql += """

          AND EXISTS (
            SELECT 1
            FROM note_tags nt
            INNER JOIN tags t ON t.tag_id = nt.tag_id
            WHERE nt.note_id = n.note_id AND t.name = ?
          )
          """
        bindings.append(.text(tagName))
      }
      sql += "\nORDER BY n.created_at DESC, n.note_id DESC\nLIMIT ?"
      bindings.append(.int(Int64(boundedLimit)))
      let noteIds = try database.query(sql, bindings: bindings).compactMap { $0.identifier("note_id", as: NoteID.self) }
      return try noteIds.map { try requireNote($0, in: database) }
    }
  }

  /// Full-text recall over the canonical notebook, optionally widened along the
  /// note graph.
  ///
  /// Associations are deliberately not restricted to the long-term notebook:
  /// the `memory-source` edges written at append time are how a recalled memory
  /// leads back to the notes it was distilled from, and those live elsewhere.
  /// `recencyWeight` blends a recency ranking into the lexical ranking of the
  /// matched pool (`design-docs/specs/note-retrieval-fusion.md`, RF4). It
  /// reorders near-ties toward the memory whose period ended most recently
  /// and never adds a note the query did not match; 0 disables it.
  public func recallLongTermMemories(
    query: String,
    limit: Int = 20,
    includeAssociations: Bool = false,
    associationDepth: Int = NoteGraphPolicy.associationMaxDepth,
    recencyWeight: Double = Self.longTermMemoryDefaultRecencyWeight
  ) throws -> [LongTermMemoryRecallResult] {
    try requireUnscopedLongTermMemoryAccess()
    guard recencyWeight >= 0, recencyWeight.isFinite else {
      throw NoteServiceError.invalidInput("recencyWeight must be a non-negative number")
    }
    let boundedLimit = max(1, min(limit, Self.longTermMemoryMaximumLimit))
    return try driver.withDatabase { database in
      let notebookId = try requireLongTermMemoryNotebookId(in: database)
      let pool = try longTermMemoryDirectHits(
        query: query,
        notebookId: notebookId,
        limit: min(boundedLimit * 2, Self.longTermMemoryMaximumLimit),
        in: database
      )
      let direct = Array(
        rerankLongTermMemoriesByRecency(pool, recencyWeight: recencyWeight).prefix(boundedLimit)
      )
      guard includeAssociations, !direct.isEmpty, direct.count < boundedLimit else {
        return direct
      }
      let directNoteIds = direct.map(\.note.noteId)
      let directNoteIdSet = Set(directNoteIds)
      let depth = min(
        max(associationDepth, NoteGraphPolicy.associationMaxDepth),
        NoteGraphPolicy.maximumDepth
      )
      let neighbors = try filterReachable(
        try noteGraphNeighborsInDatabase(
          noteIds: Array(directNoteIds.prefix(NoteGraphPolicy.maximumSeedCount)),
          maxDepth: depth,
          limit: NoteGraphPolicy.maximumLimit,
          resultExclusions: directNoteIdSet,
          in: database
        ),
        in: database
      )
      let associations = neighbors
        .filter { !directNoteIdSet.contains($0.note.noteId) }
        .prefix(boundedLimit - direct.count)
        .map { neighbor in
          LongTermMemoryRecallResult(
            note: neighbor.note,
            snippet: snippet(from: neighbor.note.bodyMarkdown, query: query),
            rank: neighbor.weight,
            isAssociation: true,
            edgeKind: neighbor.edgeKind,
            weight: neighbor.weight,
            hopCount: neighbor.hopCount,
            pathNoteIds: neighbor.pathNoteIds
          )
        }
      return direct + associations
    }
  }

  /// Connects one long-term memory into the memory graph by materializing the
  /// deterministic link proposals as `memory-association` edges. Proposals that
  /// are already linked in either direction are skipped, so repeated calls
  /// converge instead of growing the graph.
  @discardableResult
  public func linkLongTermMemoryAssociations(
    noteId: NoteID,
    limit: Int = 8
  ) throws -> [NoteLink] {
    try requireUnscopedLongTermMemoryAccess()
    let boundedLimit = max(1, min(limit, NoteGraphPolicy.maximumLimit))
    try driver.withDatabase { database in
      let notebookId = try requireLongTermMemoryNotebookId(in: database)
      let note = try requireNote(noteId, in: database)
      guard note.notebookId == notebookId else {
        throw NoteServiceError.invalidInput(
          "note \(noteId) does not belong to the long-term-memory notebook"
        )
      }
    }
    let proposals = try proposeLinks(noteId: noteId, limit: boundedLimit)
    guard !proposals.isEmpty else {
      return []
    }
    return try driver.withDatabase { database in
      try database.transaction { db in
        var created: [NoteLink] = []
        for proposal in proposals {
          let targetNoteId = proposal.targetNote.noteId
          guard try !longTermMemoryAssociationExists(
            noteId: noteId,
            targetNoteId: targetNoteId,
            in: db
          ) else {
            continue
          }
          created.append(try linkNotesInDatabase(
            from: noteId,
            to: targetNoteId,
            linkKind: Self.longTermMemoryAssociationLinkKind,
            provenance: .ai,
            in: db
          ))
        }
        return created
      }
    }
  }
}

/// Reciprocal rank fusion of the lexical order (position in `hits`) with a
/// recency order keyed on the entry's `periodEnd`, falling back to
/// `createdAt`. The lexical list keeps weight 1, so with the default weight a
/// one-position recency gap cannot overturn a one-position lexical gap.
func rerankLongTermMemoriesByRecency(
  _ hits: [LongTermMemoryRecallResult],
  recencyWeight: Double
) -> [LongTermMemoryRecallResult] {
  guard recencyWeight > 0, hits.count > 1 else {
    return hits
  }
  let lexicalOrder = hits.map(\.note.noteId)
  let recencyOrder = hits
    .map { hit in (noteId: hit.note.noteId, key: longTermMemoryRecencyKey(hit.note)) }
    .sorted { lhs, rhs in
      if lhs.key != rhs.key { return lhs.key > rhs.key }
      return lhs.noteId < rhs.noteId
    }
    .map(\.noteId)
  let fused = reciprocalRankFusion(lists: [
    (weight: 1, ids: lexicalOrder),
    (weight: recencyWeight, ids: recencyOrder)
  ])
  let lexicalPosition = Dictionary(uniqueKeysWithValues: lexicalOrder.enumerated().map { ($1, $0) })
  return hits.sorted { lhs, rhs in
    let lhsScore = fused[lhs.note.noteId] ?? 0
    let rhsScore = fused[rhs.note.noteId] ?? 0
    if lhsScore != rhsScore { return lhsScore > rhsScore }
    return (lexicalPosition[lhs.note.noteId] ?? 0) < (lexicalPosition[rhs.note.noteId] ?? 0)
  }
}

/// ISO-8601 timestamps compare lexically; `periodEnd` wins over `createdAt`
/// because a consolidated memory is dated by the window it covers.
private func longTermMemoryRecencyKey(_ note: Note) -> String {
  if let metaJSON = note.metaJSON,
     let object = (try? JSONValue(parsing: metaJSON))?.asObject,
     let periodEnd = object["periodEnd"]?.asString,
     !periodEnd.isEmpty {
    return periodEnd
  }
  return note.createdAt
}

private extension NoteService {
  func requireUnscopedLongTermMemoryAccess() throws {
    guard actingUserId == nil, !isUnauthenticatedPrincipal else {
      throw NoteServiceError.notFound("long-term memory not found")
    }
  }

  func requireLongTermMemoryNotebookId(in database: SQLiteDatabase) throws -> NotebookID {
    let notebookIds = try longTermMemoryNotebookIds(in: database)
    guard notebookIds.count == 1, let notebookId = notebookIds.first else {
      if notebookIds.isEmpty {
        throw NoteServiceError.notFound("long-term-memory notebook not found")
      }
      throw NoteServiceError.invalidInput(
        "multiple notebooks carry \(NoteStoreSchema.longTermMemoryNotebookKindTag)"
      )
    }
    return notebookId
  }

  func longTermMemoryDirectHits(
    query: String,
    notebookId: NotebookID,
    limit: Int,
    in database: SQLiteDatabase
  ) throws -> [LongTermMemoryRecallResult] {
    var ranksByNoteId: [(noteId: NoteID, rank: Double)] = []
    if let matchQuery = ftsMatchQuery(from: query) {
      ranksByNoteId = try database.query(
        """
        SELECT m.note_id, \(NoteSearchFusionPolicy.weightedBM25) AS rank
        FROM note_fts
        INNER JOIN note_fts_map m ON m.fts_rowid = note_fts.rowid
        INNER JOIN notes n ON n.note_id = m.note_id
        WHERE note_fts MATCH ? AND n.notebook_id = ?
        ORDER BY rank, n.created_at DESC, n.note_id
        LIMIT ?
        """,
        bindings: [.text(matchQuery), .id(notebookId), .int(Int64(limit))]
      ).compactMap { row in
        row.identifier("note_id", as: NoteID.self).map { ($0, Double(row["rank"] ?? "") ?? 0) }
      }
    }
    // The trigram index cannot match sub-trigram or symbol-only queries, so top
    // the result set up with a substring scan the way `searchNotesInDatabase`
    // does rather than reporting an empty recall.
    if ranksByNoteId.count < limit {
      let found = Set(ranksByNoteId.map(\.noteId))
      ranksByNoteId.append(contentsOf: try longTermMemoryLikeHits(
        query: query,
        notebookId: notebookId,
        excludedNoteIds: found,
        limit: limit - ranksByNoteId.count,
        in: database
      ))
    }
    let notesById = try requireNotes(ranksByNoteId.map(\.noteId), in: database)
    return try ranksByNoteId.map { hit in
      guard let note = notesById[hit.noteId] else {
        throw NoteServiceError.notFound("note not found: \(hit.noteId)")
      }
      return LongTermMemoryRecallResult(
        note: note,
        snippet: snippet(from: note.bodyMarkdown, query: query),
        rank: hit.rank
      )
    }
  }

  func longTermMemoryLikeHits(
    query: String,
    notebookId: NotebookID,
    excludedNoteIds: Set<NoteID>,
    limit: Int,
    in database: SQLiteDatabase
  ) throws -> [(noteId: NoteID, rank: Double)] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedQuery.isEmpty, limit > 0 else {
      return []
    }
    let likePattern = "%\(longTermMemoryLikePattern(normalizedQuery))%"
    var sql = """
      SELECT n.note_id
      FROM notes n
      WHERE n.notebook_id = ?
        AND (n.title LIKE ? ESCAPE '\\' OR n.body_markdown LIKE ? ESCAPE '\\')
      """
    var bindings: [SQLiteValue] = [
      .id(notebookId),
      .text(likePattern),
      .text(likePattern)
    ]
    if !excludedNoteIds.isEmpty {
      sql += "\n  AND n.note_id NOT IN (\(placeholders(count: excludedNoteIds.count)))"
      bindings.append(contentsOf: excludedNoteIds.sorted().sqliteBindings)
    }
    sql += "\nORDER BY n.created_at DESC, n.note_id\nLIMIT ?"
    bindings.append(.int(Int64(limit)))
    return try database.query(sql, bindings: bindings).compactMap { row in
      row.identifier("note_id", as: NoteID.self).map { ($0, 1) }
    }
  }

  func longTermMemoryAssociationExists(
    noteId: NoteID,
    targetNoteId: NoteID,
    in database: SQLiteDatabase
  ) throws -> Bool {
    try !database.query(
      """
      SELECT 1
      FROM note_links
      WHERE link_kind = ?
        AND (
          (from_note_id = ? AND to_note_id = ?)
          OR (from_note_id = ? AND to_note_id = ?)
        )
      LIMIT 1
      """,
      bindings: [
        .text(Self.longTermMemoryAssociationLinkKind),
        .id(noteId),
        .id(targetNoteId),
        .id(targetNoteId),
        .id(noteId)
      ]
    ).isEmpty
  }

  func insertLongTermMemoryNote(
    noteId: NoteID,
    notebookId: NotebookID,
    noteNumber: Int,
    entry: LongTermMemoryEntryInput,
    timestamp: String,
    in database: SQLiteDatabase
  ) throws {
    let resolvedSourceNoteIds = try resolvedLongTermMemoryNoteIds(entry.sourceNoteIds, in: database)
    let resolvedRelatedNoteIds = try resolvedLongTermMemoryNoteIds(entry.relatedNoteIds, in: database)
    let unresolvedRelatedNoteIds = entry.relatedNoteIds.filter {
      !resolvedRelatedNoteIds.contains($0)
    }
    try database.execute(
      """
      INSERT INTO notes (
        note_id, notebook_id, note_number, title, title_source, body_markdown,
        read_only, created_by, updated_by, created_at, updated_at, meta_json
      ) VALUES (
        ?, ?, ?, ?, 'derived', ?, 0,
        (SELECT owner_user_id FROM notebooks WHERE notebook_id = ?),
        (SELECT owner_user_id FROM notebooks WHERE notebook_id = ?),
        ?, ?, jsonb(?)
      )
      """,
      bindings: [
        .id(noteId),
        .id(notebookId),
        .int(Int64(noteNumber)),
        .optionalText(noteTitle(from: entry.bodyMarkdown)),
        .text(entry.bodyMarkdown),
        .id(notebookId),
        .id(notebookId),
        .text(timestamp),
        .text(timestamp),
        .text(try longTermMemoryMetaJSON(
          entry: entry,
          unresolvedRelatedNoteIds: unresolvedRelatedNoteIds
        ))
      ]
    )
    for tagName in entry.topicTags {
      try applyTag(
        noteId: noteId,
        tag: NoteTagInput(name: tagName, classId: .topic),
        provenance: .system,
        assignedBy: Self.longTermMemoryAssignedBy,
        deletable: true,
        in: database
      )
    }
    for sourceNoteId in entry.sourceNoteIds where resolvedSourceNoteIds.contains(sourceNoteId) {
      _ = try linkNotesInDatabase(
        from: noteId,
        to: sourceNoteId,
        linkKind: Self.longTermMemorySourceLinkKind,
        provenance: .system,
        in: database
      )
    }
    for relatedNoteId in entry.relatedNoteIds where resolvedRelatedNoteIds.contains(relatedNoteId) {
      _ = try linkNotesInDatabase(
        from: noteId,
        to: relatedNoteId,
        linkKind: Self.longTermMemoryRelatedLinkKind,
        provenance: .system,
        in: database
      )
    }
    try refreshFTS(noteId: noteId, previous: nil, in: database)
  }

  func resolvedLongTermMemoryNoteIds(
    _ noteIds: [NoteID],
    in database: SQLiteDatabase
  ) throws -> Set<NoteID> {
    let unique = orderedUnique(noteIds)
    guard !unique.isEmpty else {
      return []
    }
    return Set(try requireNotes(unique, in: database).keys)
  }

  func longTermMemoryMetaJSON(
    entry: LongTermMemoryEntryInput,
    unresolvedRelatedNoteIds: [NoteID]
  ) throws -> String {
    var object: JSONObject = [:]
    if let metaJSON = entry.metaJSON {
      guard let decoded = (try? JSONValue(parsing: metaJSON))?.asObject else {
        throw NoteServiceError.invalidInput(
          "long-term memory metaJSON must encode a JSON object"
        )
      }
      object = decoded
    }
    // Reserved keys are written last: the listing and recall predicates read
    // them, so caller extras must never be able to shadow them.
    object["longTermMemoryVersion"] = .integer(1)
    object["entryKind"] = .string("long-term-memory")
    object["sourceNoteIds"] = .ids(orderedUnique(entry.sourceNoteIds))
    object["unresolvedRelatedNoteIds"] = .ids(orderedUnique(unresolvedRelatedNoteIds))
    if let periodStart = entry.periodStart {
      object["periodStart"] = .string(longTermMemoryTimestamp(periodStart))
    } else {
      object.removeValue(forKey: "periodStart")
    }
    if let periodEnd = entry.periodEnd {
      object["periodEnd"] = .string(longTermMemoryTimestamp(periodEnd))
    } else {
      object.removeValue(forKey: "periodEnd")
    }
    do {
      return try JSONValue.object(object).encodedString()
    } catch {
      throw NoteServiceError.invalidInput("long-term memory metadata must be UTF-8 JSON")
    }
  }

  func normalizedLongTermMemoryEntry(
    _ entry: LongTermMemoryEntryInput
  ) throws -> LongTermMemoryEntryInput {
    guard !entry.bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw NoteServiceError.invalidInput("long-term memory entry body must not be empty")
    }
    if let periodStart = entry.periodStart,
       let periodEnd = entry.periodEnd,
       periodStart > periodEnd {
      throw NoteServiceError.invalidInput(
        "long-term memory period start must not be later than period end"
      )
    }
    var normalized = entry
    normalized.topicTags = try orderedUnique(entry.topicTags).map { tagName in
      let trimmed = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        throw NoteServiceError.invalidInput("long-term memory topic tag must not be empty")
      }
      let lowercased = trimmed.lowercased()
      for prefix in Self.longTermMemoryReservedTagPrefixes where lowercased.hasPrefix(prefix) {
        throw NoteServiceError.invalidInput(
          "long-term memory topic tag must not use the reserved prefix \(prefix): \(trimmed)"
        )
      }
      return trimmed
    }
    normalized.sourceNoteIds = orderedUnique(entry.sourceNoteIds)
    normalized.relatedNoteIds = orderedUnique(entry.relatedNoteIds)
    return normalized
  }

  func existingLongTermMemoryBatch(
    notebookId: NotebookID,
    idempotencyKey: String,
    expectedCount: Int,
    in database: SQLiteDatabase
  ) throws -> [Note]? {
    let prefix = longTermMemoryNoteIdPrefix(idempotencyKey: idempotencyKey)
    let noteIds = try database.query(
      """
      SELECT note_id FROM notes
      WHERE notebook_id = ? AND note_id LIKE ?
      ORDER BY note_id
      """,
      bindings: [.id(notebookId), .text("\(prefix)-%")]
    ).compactMap { $0.identifier("note_id", as: NoteID.self) }
    guard !noteIds.isEmpty else {
      return nil
    }
    let expectedNoteIds = (0..<expectedCount).map { NoteID("\(prefix)-\($0 + 1)") }
    guard noteIds.count == expectedNoteIds.count, Set(noteIds) == Set(expectedNoteIds) else {
      throw NoteServiceError.invalidInput(
        "long-term memory idempotency key has inconsistent persisted entry count"
      )
    }
    return try expectedNoteIds.map { try requireNote($0, in: database) }
  }

  func normalizedLongTermMemoryIdempotencyKey(_ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw NoteServiceError.invalidInput("long-term memory idempotency key must not be empty")
    }
    return trimmed
  }

  func longTermMemoryNoteIdPrefix(idempotencyKey: String) -> String {
    "note-long-term-memory-\(sha256Hex(Data(idempotencyKey.utf8)))"
  }

  func longTermMemoryNoteId(idempotencyKey: String, index: Int) -> NoteID {
    NoteID("\(longTermMemoryNoteIdPrefix(idempotencyKey: idempotencyKey))-\(index + 1)")
  }

  func longTermMemoryLikePattern(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
  }
}

func longTermMemoryNotebookIds(in database: SQLiteDatabase) throws -> [NotebookID] {
  try database.query(
    """
    SELECT notebook_id
    FROM notebook_tags
    WHERE tag_id = ?
    ORDER BY notebook_id
    """,
    bindings: [.id(NoteStoreSchema.longTermMemoryNotebookKindTagId)]
  ).compactMap { $0.identifier("notebook_id", as: NotebookID.self) }
}

func validateLongTermMemoryNotebookTagAssignment(
  notebookId: NotebookID,
  allowsIdentityCreation: Bool,
  in database: SQLiteDatabase
) throws {
  let notebookIds = try longTermMemoryNotebookIds(in: database)
  if notebookIds == [notebookId] {
    return
  }
  guard allowsIdentityCreation, notebookIds.isEmpty else {
    throw NoteServiceError.invalidInput(
      "\(NoteStoreSchema.longTermMemoryNotebookKindTag) is reserved for the canonical long-term-memory notebook"
    )
  }
}

func validateCanonicalLongTermMemoryNotebook(
  notebookId: NotebookID,
  in database: SQLiteDatabase
) throws {
  guard let assignment = try notebookTagAssignment(
    notebookId: notebookId,
    tagId: NoteStoreSchema.longTermMemoryNotebookKindTagId,
    in: database
  ), assignment.tag.isSystem,
     assignment.tag.classId == .documentKind,
     assignment.provenance == .system,
     assignment.assignedBy == "kaiba-note",
     !assignment.deletable else {
    throw NoteServiceError.invalidInput(
      "\(NoteStoreSchema.longTermMemoryNotebookKindTag) is not owned by the canonical long-term-memory bootstrap"
    )
  }
}

func longTermMemoryTimestamp(_ date: Date) -> String {
  longTermMemoryTimestampFormatter.string(from: date)
}

private let longTermMemoryTimestampFormatter = LongTermMemoryTimestampFormatter()

/// Formats aggregation-window bounds exactly like `NoteStoreClock.system`, so
/// the stored `periodStart`/`periodEnd` strings and `notes.created_at` remain
/// mutually comparable under the lexicographic SQL predicates.
private final class LongTermMemoryTimestampFormatter: @unchecked Sendable {
  private let formatter: ISO8601DateFormatter
  private let lock = NSLock()

  init() {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    self.formatter = formatter
  }

  func string(from date: Date) -> String {
    lock.lock()
    defer {
      lock.unlock()
    }
    return formatter.string(from: date)
  }
}
