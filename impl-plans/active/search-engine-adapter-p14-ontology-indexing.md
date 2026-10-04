# P14 Ontology indexing: D1 document builder and write-path enqueues

**Status**: Ready
**planId**: P14-ontology-indexing
**Wave**: 2
**dependsOn**: P12-delta-contract. Accepted dependencies: P2-store-outbox and P4-sync-drain.
**Design Reference**: `design-docs/specs/search-engine-adapter.md` D1 "Document fields" and "Write paths that must enqueue"; SE3 (outbox, gated enqueue)
**Index**: `impl-plans/active/search-engine-adapter.md`

## Intent and context

Engine documents must carry the following, read from the store:

- direct tag applications with their provenance;
- all path tags (direct and ancestor), with names and classes;
- outgoing and incoming linked note ids.

Every write that changes one of these must enqueue the affected notes through the existing durable outbox, in the same transaction. Enqueueing stays a no-op until the store has been activated.

Repository facts, verified by the design review:

- `searchIndexDocument(noteId:in:)` is at `Sources/AppCore/SearchIndexSynchronizer.swift:130`. It builds the base fields.
- Outbox helpers are in `Sources/AppCore/SearchEngineSyncOutbox.swift`: `enqueueSearchEngineSync(noteIds:in:)` (line 72) and `enqueueSearchEngineSync(notebookId:in:)` (line 87). Both are gated by `EXISTS (SELECT 1 FROM search_engine_sync_state)`.
- `refreshFTS` (`NoteSearchIndex.swift:33`) already enqueues. Tag apply/remove, undo of tags, and reparent (through `refreshFTSForNotesUnderTag`, `NoteSearchIndex.swift:93`) are therefore already covered.
- Tag class writes do not enqueue:
  - `defineTag` (`NoteService+Catalog.swift:85`, `SET class_id = coalesce(?, class_id), parent_tag_id = coalesce(?, parent_tag_id)`);
  - `ensureTag` (`NoteTagWrites.swift:140`, which sets a class only when it was NULL).
- The `note_links` INSERT sites:
  - `NoteService.swift:758`, inside `promoteCommentToNotebook`;
  - `NoteService+Relations.swift:616`, in `linkNotesInDatabase`. The conversation-turn source links also go through it;
  - `NoteService+ActionHistory.swift:391`, in the `restoreNoteSnapshot` link restore.
- The single `note_links` DELETE is at `NoteService.swift:923`, inside `deleteNoteRows`.
- Notebook tag writes are in `NoteService+NotebookTags.swift`: `applyNotebookTags` (5), `applyNotebookTagIds` (45), `removeNotebookTag` (78) and `removeNotebookTagById` (117). They change the indexed `isLongTermMemory`.
- There is no tag rename, merge or delete API, and no API that moves a note to another notebook. Do not add any.
- `ftsContextPayload` (`NoteSearchIndex.swift:117`) shows the existing ancestor walk.

## Non-goals

- No change to the base document fields: `tagIds`, `tagNames`, `context` and the text fields.
- No Elasticsearch or query-service change.
- No schema change. The store version stays 23.
- No tag rename API.
- No GraphQL change.

## writePaths

- `Sources/AppCore/SearchIndexSynchronizer.swift`
- `Sources/AppCore/SearchIndexDocumentOntology.swift` (new; the D1 field queries)
- `Sources/AppCore/SearchEngineSyncOutbox.swift`
- `Sources/AppCore/NoteService+Catalog.swift`
- `Sources/AppCore/NoteTagWrites.swift`
- `Sources/AppCore/NoteService+Relations.swift`
- `Sources/AppCore/NoteService+ActionHistory.swift`
- `Sources/AppCore/NoteService.swift`
- `Sources/AppCore/NoteService+NotebookTags.swift`
- `Tests/AppCoreTests/SearchEngineOntologyIndexTests.swift` (new)
- `impl-plans/active/search-engine-adapter-p14-ontology-indexing.md`

## sharedPaths (read-only)

- `Sources/AppCore/SearchEngine.swift`: read-only. The P12 D1 types.
- `Sources/AppCore/NoteSearchIndex.swift`: read-only. `refreshFTS`, `refreshFTSForNotesUnderTag` and the `ftsContextPayload` ancestor walk.
- `Sources/AppCore/NoteTagHierarchy.swift`: read-only. The `expandedTagFilterIds` recursive CTE pattern.
- `Sources/AppCore/NoteStoreSchema.swift`: read-only. The `tags`, `note_tags` and `note_links` columns.
- `Tests/AppCoreTests/SearchEngineSyncOutboxTests.swift`: read-only. Activation and outbox-reading test helpers.
- `Tests/AppCoreTests/NoteServiceTests.swift`: read-only. `makeService` helpers.

## File-level changes

### `SearchIndexDocumentOntology.swift` (new, internal free functions)

- **`searchIndexTagApplications(noteId:in:) -> [SearchIndexTagApplication]`.** It runs `SELECT tag_id, provenance FROM note_tags WHERE note_id = ? ORDER BY tag_id`.
- **`searchIndexPathTags(directTagIds:in:) -> [SearchIndexPathTag]`.**
  - It is one recursive CTE that starts from the direct tag ids, walks `tags.parent_tag_id` upward, and caps the depth at 64 (`WHERE depth < 64`).
  - It uses `UNION`, not `UNION ALL`, so a corrupted cycle terminates.
  - It selects `tag_id, name, class_id` and returns one entry per tag, sorted by `tagId`, with `isDirect` true for direct ids.
  - It includes system tags.
- **`searchIndexLinkedNoteIds(noteId:in:) -> (outgoing: [NoteID], incoming: [NoteID])`.**
  - Outgoing: `SELECT DISTINCT to_note_id FROM note_links WHERE from_note_id = ? AND to_note_id <> ? ORDER BY to_note_id LIMIT 500`.
  - Incoming is symmetric.
  - It spans all link kinds.

### `SearchIndexSynchronizer.swift`

`searchIndexDocument(noteId:in:)` passes the three results to the new `SearchIndexDocument` init parameters. Nothing else changes.

### `SearchEngineSyncOutbox.swift`

Add `func enqueueSearchEngineSync(notesUnderTagId tagId: TagID, in database: SQLiteDatabase) throws`.

- It is the single set-based statement from the design. A `WITH RECURSIVE` descendant CTE over `tags.parent_tag_id` (depth at most 64, `UNION`) is joined to `note_tags`, and the result is inserted into `search_index_outbox` with the same gate and the same `ON CONFLICT` clause as `enqueueSearchEngineSync(noteIds:)`.
- SQLite needs `WHERE true` before `ON CONFLICT` in `INSERT ... SELECT` upserts. Imitate the activation backfill statement in the same file.

Also add `enqueueSearchEngineSync(linkEndpointsOf noteIds: [NoteID], in:)`.

- It enqueues every note linked to or from the given notes, excluding the given notes themselves.
- `deleteNoteRows` uses it before deleting the links.

### Call sites (one or two lines each; no other edits in these files)

- **`NoteService+Catalog.swift` `defineTag`.** Read the tag's current `class_id` before the UPDATE. After the UPDATE, when a class was supplied and differs from the old value, call the subtree enqueue for that tag. Reparent stays covered by the existing `refreshFTSForNotesUnderTag`; do not add a second enqueue for it.
- **`NoteTagWrites.swift` `ensureTag`.** When the class is actually set (old NULL, new non-nil), call the subtree enqueue. The tagged note is enqueued anyway by `refreshFTS`, and a duplicate enqueue only bumps the generation, which is harmless.
- **`NoteService+Relations.swift` `linkNotesInDatabase`.** After the upsert, enqueue `[fromNoteId, toNoteId]`.
- **`NoteService.swift` `promoteCommentToNotebook`.** After the inline link INSERT, enqueue both endpoints.
- **`NoteService.swift` `deleteNoteRows`.** Before `DELETE FROM note_links`, call `enqueueSearchEngineSync(linkEndpointsOf: ids)`. The deleted notes are already enqueued by the existing line.
- **`NoteService+ActionHistory.swift`, the `restoreNoteSnapshot` link restore.** Enqueue both endpoints of each restored link.
- **`NoteService+NotebookTags.swift`, all four functions.** After a successful write, call `enqueueSearchEngineSync(notebookId:)`, inside the same database transaction or closure as the write.

## Pitfalls

- **Same transaction.** Every enqueue must run on the same `database` handle, inside the write closure. Never call an engine.
- **Gate.** Do not bypass the activation gate. A never-activated store must get zero outbox rows from every new call site.
- **NoteService.swift** is about 946 lines after P12. Keep it at or under 960 lines. Put any multi-line logic in the new or the outbox file, not inline.
- **System tags stay in `pathTags`.** P15 excludes them where the design says to.
- **Recursive CTE.** Use parameter bindings, and never interpolate ids into SQL.
- **Do not change `refreshFTS` or `ftsContextPayload`.**

## Tests (`SearchEngineOntologyIndexTests`, XCTest)

Use a temporary store and activate it with `activateSearchEngineSync(indexIdentity: "test:v2")`. Before each step, clear the outbox (`DELETE FROM search_index_outbox`) so that only that step's enqueues remain.

- Note N tagged `child` (class `person`, provenance `ai`) under `parent` (class `folder`) under `root`, linking to M, and linked from K -> `searchIndexDocument(N)` gives:
  - `tagApplications == [(child, "ai")]`;
  - `pathTags` with the 3 tags, only `child` direct, and the classes as set;
  - `outgoing == [M]` and `incoming == [K]`.
- `defineTag(child, class: event)` -> the outbox contains N and every note tagged with `child` or its descendants. Redefining with the same class -> no rows.
- `ensureTag` setting a class on a previously classless tag T -> the notes under T are enqueued.
- `linkNotes(A, B)` -> A and B are enqueued.
- Undo restore of a deleted note's links -> both endpoints are enqueued.
- A promote-comment link -> both endpoints are enqueued.
- Deleting note A that links to B and is linked from C -> A, B and C are enqueued.
- Applying or removing a notebook tag on notebook X -> every note of X is enqueued.
- The same writes on a store that was never activated -> `SELECT count(*) FROM search_index_outbox` is 0.

## Verification

```bash
mise run build
bash -c 'mkdir -p tmp/search-engine-adapter/P14 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter SearchEngineOntologyIndex 2>&1 | tee tmp/search-engine-adapter/P14/ontology-index.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P14 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter SearchEngineSyncOutbox 2>&1 | tee tmp/search-engine-adapter/P14/outbox-regression.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P14 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter SearchIndexSynchronizer 2>&1 | tee tmp/search-engine-adapter/P14/drain-regression.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P14 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter Tag 2>&1 | tee tmp/search-engine-adapter/P14/tag-regression.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P14 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter NoteActionHistoryTests 2>&1 | tee tmp/search-engine-adapter/P14/action-history-regression.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P14 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter NoteHierarchyProgressTests 2>&1 | tee tmp/search-engine-adapter/P14/links-regression.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P14 && mise run lint 2>&1 | tee tmp/search-engine-adapter/P14/lint.log; echo exit=${PIPESTATUS[0]}'
grep -n "enqueueSearchEngineSync" Sources/AppCore/NoteService+Catalog.swift Sources/AppCore/NoteTagWrites.swift Sources/AppCore/NoteService+Relations.swift Sources/AppCore/NoteService+ActionHistory.swift Sources/AppCore/NoteService.swift Sources/AppCore/NoteService+NotebookTags.swift
wc -l Sources/AppCore/NoteService.swift Sources/AppCore/NoteService+Relations.swift Sources/AppCore/NoteService+ActionHistory.swift Sources/AppCore/SearchEngineSyncOutbox.swift Sources/AppCore/SearchIndexDocumentOntology.swift
```

Expected evidence:

- Every `swift test` run shows `exit=0` with an XCTest `Executed N tests, 0 failures`, N > 0. If a filter matches no XCTest, replace it with the nearest existing suite name and log that change.
- The grep lists every call site in the table.
- `NoteService.swift` has at most 960 lines, and all files are under 1000.

## Done criteria

- [ ] The document builder fills `tagApplications`, `pathTags` and both link lists.
- [ ] Every write path in the design D1 table enqueues the right notes after activation, and none before.
- [ ] The subtree helper is a single gated statement.
- [ ] All verification shows `exit=0` with positive counts.

## Progress Log

- 2026-10-04: Plan created (session-264).
