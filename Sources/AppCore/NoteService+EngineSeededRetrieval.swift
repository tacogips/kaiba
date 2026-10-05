import Foundation

private struct PreparedEngineSeededRetrieval {
  var scope: NoteSearchScope
  var tagFilterIds: [TagID]
  var hierarchyTagIds: [TagID]
  var expansionTagIds: [TagID]
}

public extension NoteService {
  func retrieveNotes(
    query: String,
    tagFilter: [String] = [],
    classFilter: [String] = [],
    notebookId: NotebookID? = nil,
    sort: NoteListSort = .createdAtDesc,
    createdAfter: String? = nil,
    createdBefore: String? = nil,
    includeLinked: Bool = false,
    depth: Int = 1,
    limit: Int = 20,
    offset: Int = 0
  ) async throws -> NoteRetrievalOutcome {
    func fts() throws -> NoteRetrievalOutcome {
      NoteRetrievalOutcome(
        results: try searchNotes(
          query: query,
          tagFilter: tagFilter,
          classFilter: classFilter,
          notebookId: notebookId,
          sort: sort,
          createdAfter: createdAfter,
          createdBefore: createdBefore,
          includeLinked: includeLinked,
          depth: depth,
          limit: limit,
          offset: offset
        ),
        usedSearchEngine: false
      )
    }

    let requestedOffset = max(0, offset)
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let (window, windowOverflowed) = requestedOffset.addingReportingOverflow(limit)
    guard let engine = searchEngine,
          !trimmedQuery.isEmpty,
          limit > 0,
          !windowOverflowed,
          window <= NoteRetrievalFusionPolicy.maximumFusedWindow else {
      return try fts()
    }

    let prepared = try driver.withDatabase { database -> PreparedEngineSeededRetrieval? in
      let scope = try makeNoteSearchScope(
        notebookId: notebookId,
        createdAfter: createdAfter,
        createdBefore: createdBefore,
        in: database
      )
      guard scope.reachableLibraryIds != [] else { return nil }

      let tagFilterIds: [TagID]
      let hierarchyTagIds: [TagID]
      if tagFilter.isEmpty {
        tagFilterIds = []
        hierarchyTagIds = []
      } else {
        guard let resolved = try resolveTagIds(named: tagFilter, in: database), !resolved.isEmpty else {
          return nil
        }
        hierarchyTagIds = resolved
        tagFilterIds = try expandedTagFilterIds(resolved, in: database)
      }
      return PreparedEngineSeededRetrieval(
        scope: scope,
        tagFilterIds: tagFilterIds,
        hierarchyTagIds: hierarchyTagIds,
        expansionTagIds: try ontologyExpansionTagIds(query: trimmedQuery, in: database)
      )
    }
    guard let prepared else { return try fts() }

    let (requestedSize, sizeOverflowed) = window.addingReportingOverflow(20)
    let engineSize = sizeOverflowed
      ? NoteRetrievalFusionPolicy.maximumEngineCandidates
      : min(requestedSize, NoteRetrievalFusionPolicy.maximumEngineCandidates)
    let engineHits: [SearchEngineHit]
    do {
      engineHits = try await engine.search(SearchEngineQuery(
        text: trimmedQuery,
        filter: searchEngineFilter(
          for: prepared.scope,
          tagIds: [],
          excludedNoteIds: [],
          hierarchyTagIds: prepared.hierarchyTagIds
        ),
        from: 0,
        size: engineSize,
        expansionTagIds: prepared.expansionTagIds
      ))
    } catch {
      return try fts()
    }

    let results = try driver.withDatabase { database -> [NoteSearchResult] in
      var uniqueHits: [SearchEngineHit] = []
      var seenHitIds = Set<NoteID>()
      for hit in engineHits
        where uniqueHits.count < NoteRetrievalFusionPolicy.maximumEngineCandidates && seenHitIds.insert(hit.noteId).inserted {
        uniqueHits.append(hit)
      }
      let eligibleIds = try eligibleSearchCandidateIds(
        uniqueHits.map(\.noteId),
        scope: prepared.scope,
        tagFilterIds: prepared.tagFilterIds,
        classFilter: classFilter,
        in: database
      )
      let eligibleHits = uniqueHits.filter { eligibleIds.contains($0.noteId) }
      let fullTextResults = try searchNotesInDatabase(
        query: trimmedQuery,
        tagFilter: tagFilter,
        classFilter: classFilter,
        scope: prepared.scope,
        sort: sort,
        graphOptions: NoteSearchGraphOptions(includeLinked: false, depth: depth),
        limit: window,
        offset: 0,
        in: database
      )
      let fullTextById = Dictionary(uniqueKeysWithValues: fullTextResults.map { ($0.note.noteId, $0) })
      let hitsById = Dictionary(uniqueKeysWithValues: eligibleHits.map { ($0.noteId, $0) })
      let ftsList = NoteRetrievalCandidateList(
        label: .fullText,
        weight: 1,
        tier: .direct,
        entries: fullTextResults.map {
          NoteRetrievalCandidateEntry(noteId: $0.note.noteId, provenance: NoteRetrievalProvenance())
        }
      )
      let engineList = NoteRetrievalCandidateList(
        label: .searchEngine,
        weight: 1,
        tier: .direct,
        entries: eligibleHits.map { hit in
          NoteRetrievalCandidateEntry(
            noteId: hit.noteId,
            provenance: NoteRetrievalProvenance(reasons: hit.reasons.map(\.kind))
          )
        }
      )
      let directFused = NoteRetrievalReranker.fuse([ftsList, engineList], limit: window)
      let notesById = try requireNotes(directFused.map(\.noteId), in: database)
      let searchTexts = try noteSearchTexts(directFused.map(\.noteId), in: database)
      let terms = indexableSearchTerms(from: trimmedQuery)
      var directResults: [NoteSearchResult] = []
      for candidate in directFused {
        guard let note = notesById[candidate.noteId] else {
          throw NoteServiceError.notFound("note not found: \(candidate.noteId)")
        }
        let retrievalText = noteRetrievalText(
          bodyMarkdown: note.bodyMarkdown,
          searchText: searchTexts[note.noteId]
        )
        let ftsResult = fullTextById[note.noteId]
        let hit = hitsById[note.noteId]
        let highlight = hit?.highlight?.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = highlight.flatMap { $0.isEmpty ? nil : $0 }
          ?? ftsResult?.snippet
          ?? snippet(from: retrievalText, query: trimmedQuery)
        let searchableText = "\(note.title ?? "") \(retrievalText)"
        let coverage = terms.isEmpty
          ? 0
          : Double(terms.filter { searchableText.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }.count)
            / Double(terms.count)
        directResults.append(NoteSearchResult(
          note: note,
          snippet: snippet,
          rank: candidate.score,
          matchedTags: note.tags.map(\.tag),
          termCoverage: ftsResult?.termCoverage ?? coverage,
          provenance: candidate.provenance
        ))
      }

      guard includeLinked else { return Array(directResults.dropFirst(requestedOffset).prefix(limit)) }
      let graphResults = try appendLinkedNeighborResults(
        to: directResults,
        query: trimmedQuery,
        tagFilterIds: prepared.tagFilterIds,
        classFilter: classFilter,
        scope: prepared.scope,
        sort: sort,
        depth: depth,
        limit: window,
        in: database
      )
      let neighbors = graphResults.filter(\.isLinkedNeighbor)
      let neighborList = NoteRetrievalCandidateList(
        label: .graphNeighbor,
        weight: 1,
        tier: .neighbor,
        entries: neighbors.map {
          NoteRetrievalCandidateEntry(noteId: $0.note.noteId, provenance: NoteRetrievalProvenance())
        }
      )
      let graphFused = NoteRetrievalReranker.fuse([ftsList, engineList, neighborList], limit: window)
      let neighborsById = Dictionary(uniqueKeysWithValues: neighbors.map { ($0.note.noteId, $0) })
      let directById = Dictionary(uniqueKeysWithValues: directResults.map { ($0.note.noteId, $0) })
      let orderedResults = graphFused.compactMap { candidate -> NoteSearchResult? in
        if let neighbor = neighborsById[candidate.noteId] {
          var result = neighbor
          result.provenance = NoteRetrievalProvenance(sources: [.graphNeighbor])
          return result
        }
        guard var result = directById[candidate.noteId] else { return nil }
        result.rank = candidate.score
        result.provenance = candidate.provenance
        return result
      }
      return Array(orderedResults.dropFirst(requestedOffset).prefix(limit))
    }
    return NoteRetrievalOutcome(results: results, usedSearchEngine: true)
  }
}

func eligibleSearchCandidateIds(
  _ ids: [NoteID],
  scope: NoteSearchScope,
  tagFilterIds: [TagID],
  classFilter: [String],
  in database: SQLiteDatabase
) throws -> Set<NoteID> {
  let uniqueIds = orderedUnique(ids)
  guard !uniqueIds.isEmpty else { return [] }
  var predicates = ["n.note_id IN (\(placeholders(count: uniqueIds.count)))"]
  var bindings = uniqueIds.sqliteBindings
  appendLibraryScopePredicate(
    alias: "n",
    reachableLibraryIds: scope.reachableLibraryIds,
    predicates: &predicates,
    bindings: &bindings
  )
  appendOwnerScopePredicate(
    alias: "n",
    actingUserId: scope.actingUserId,
    predicates: &predicates,
    bindings: &bindings
  )
  appendPendingNotebookIngestExclusionPredicate(
    alias: "n",
    excludesPendingNotebookIngests: scope.excludesPendingNotebookIngests,
    predicates: &predicates
  )
  if scope.excludesLongTermMemory, scope.actingUserId == nil {
    appendLongTermMemoryExclusionPredicate(
      alias: "n",
      excludesLongTermMemory: true,
      predicates: &predicates,
      bindings: &bindings
    )
  }
  if let notebookId = scope.notebookId {
    predicates.append("n.notebook_id = ?")
    bindings.append(.id(notebookId))
  }
  appendCreatedAtPredicates(
    alias: "n",
    createdAfter: scope.createdAfter,
    createdBefore: scope.createdBefore,
    predicates: &predicates,
    bindings: &bindings
  )
  appendTagPredicates(
    alias: "n",
    tagFilterIds: tagFilterIds,
    classFilter: classFilter,
    predicates: &predicates,
    bindings: &bindings
  )
  let rows = try database.query(
    "SELECT n.note_id FROM notes n WHERE \(predicates.joined(separator: " AND "))",
    bindings: bindings
  )
  return Set(rows.compactMap { $0.identifier("note_id", as: NoteID.self) })
}
