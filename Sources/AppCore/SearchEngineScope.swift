import Foundation

func searchEngineFilter(
  for scope: NoteSearchScope,
  tagIds: [TagID],
  excludedNoteIds: [NoteID]
) -> SearchEngineFilter {
  SearchEngineFilter(
    libraryIds: scope.reachableLibraryIds,
    ownerUserId: scope.actingUserId,
    notebookId: scope.notebookId,
    tagIds: tagIds,
    excludesLongTermMemory: scope.excludesLongTermMemory,
    excludedNoteIds: excludedNoteIds
  )
}

func scopedNoteIds(
  _ noteIds: [NoteID],
  scope: NoteSearchScope,
  in database: SQLiteDatabase
) throws -> Set<NoteID> {
  let ids = orderedUnique(noteIds)
  guard !ids.isEmpty else { return [] }

  var sql = "SELECT n.note_id FROM notes n WHERE n.note_id IN (\(placeholders(count: ids.count)))"
  var bindings = ids.sqliteBindings
  if let notebookId = scope.notebookId {
    sql += "\n  AND n.notebook_id = ?"
    bindings.append(.id(notebookId))
  }
  appendLibraryScopePredicate(
    alias: "n",
    reachableLibraryIds: scope.reachableLibraryIds,
    sql: &sql,
    bindings: &bindings
  )
  appendOwnerScopePredicate(alias: "n", actingUserId: scope.actingUserId, sql: &sql, bindings: &bindings)
  appendPendingNotebookIngestExclusionPredicate(
    alias: "n",
    excludesPendingNotebookIngests: scope.excludesPendingNotebookIngests,
    sql: &sql
  )
  if scope.excludesLongTermMemory, scope.actingUserId == nil {
    sql += "\n  AND n.notebook_id NOT IN (SELECT notebook_id FROM notebook_tags WHERE tag_id = ?)"
    bindings.append(.id(NoteStoreSchema.longTermMemoryNotebookKindTagId))
  }
  var createdAtPredicates: [String] = []
  appendCreatedAtPredicates(
    alias: "n",
    createdAfter: scope.createdAfter,
    createdBefore: scope.createdBefore,
    predicates: &createdAtPredicates,
    bindings: &bindings
  )
  for predicate in createdAtPredicates {
    sql += "\n  AND \(predicate)"
  }
  let rows = try database.query(sql, bindings: bindings)
  return Set(rows.compactMap { $0.identifier("note_id", as: NoteID.self) })
}
