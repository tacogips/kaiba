# P4 Sync drain: document builder and SearchIndexSynchronizer

**Status**: Completed. Accepted in session-263 (test-integrity and adversarial review); code in b466ced. The session-264 integration review accepted it on the combined tree (comm-003910; `tmp/search-engine-adapter/reconcile/session-264-wave8/reconcile-summary.md`). Archived to `impl-plans/completed/` at Step 8 on 2026-10-05.
**planId**: P4-sync-drain
**Wave**: 2
**dependsOn**: P1-core-contract, P2-store-outbox
**Design Reference**: `design-docs/specs/search-engine-adapter.md` SE3 "Drain", Invariants 2 and 4
**Index**: `impl-plans/completed/search-engine-adapter.md`

## Intent and context

This plan pushes outbox rows to an engine. It combines the store primitives
from P2 (claim, settle, status) with the P1 protocol:

- A note that exists becomes an upsert of a `SearchIndexDocument`, built the
  same way `note_fts` is built.
- A note that no longer exists becomes a delete.
- No engine call runs inside a store transaction.
- The server loop (P8) and the CLI (P7) both call this code.

Text derivation must match `currentFTSPayload` and `ftsContextPayload` in
`Sources/AppCore/NoteSearchIndex.swift`:

- `title`: `note.title ?? ""`.
- `body`: `noteRetrievalText(bodyMarkdown: note.bodyMarkdown, searchText: try noteSearchText(noteId, in:))`,
  from `Sources/AppCore/NoteRetrievalText.swift`.
- `tagNames`: the note's direct tag names, sorted by name. The FTS payload
  orders them by name.
- `context`: `try ftsContextPayload(noteId:in:)`.

## Non-goals

- No loop, no timers, and no change-event wiring. That is P8.
- No CLI work. That is P7.
- No changes to the P2 outbox SQL or the P1 types (read-only).
- No access-control scoping. The drainer is an operator-level, store-wide
  process and reads unscoped.

## writePaths

- `Sources/AppCore/SearchIndexSynchronizer.swift`
- `Tests/AppCoreTests/SearchIndexSynchronizerTests.swift`
- `impl-plans/completed/search-engine-adapter-p4-sync-drain.md`

New files: `Sources/AppCore/SearchIndexSynchronizer.swift`, `Tests/AppCoreTests/SearchIndexSynchronizerTests.swift`.

## sharedPaths (read-only)

- `Sources/AppCore/SearchEngine.swift`
- `Sources/AppCore/SearchEngineSyncOutbox.swift`
- `Sources/AppCore/NoteSearchIndex.swift`
- `Sources/AppCore/NoteRetrievalText.swift`
- `Sources/AppCore/NoteService+LibraryEnforcement.swift`
- `Sources/AppCore/NoteService+Hydration.swift`
- `Tests/AppCoreTests/FakeSearchEngine.swift`
- `Tests/AppCoreTests/NoteServiceTests.swift`

## sharedPathNotes

- `Sources/AppCore/SearchEngine.swift`: read-only: P1 contract.
- `Sources/AppCore/SearchEngineSyncOutbox.swift`: read-only: P2 claim, settle
  and status.
- `Sources/AppCore/NoteSearchIndex.swift`: read-only: `ftsContextPayload` and
  the FTS text derivation.
- `Sources/AppCore/NoteRetrievalText.swift`: read-only: `noteRetrievalText` and
  `noteSearchText`.
- `Sources/AppCore/NoteService+LibraryEnforcement.swift`: read-only:
  `isLongTermMemoryNotebook(_:in:)`.
- `Sources/AppCore/NoteService+Hydration.swift`: read-only: `loadNote`.
- `Tests/AppCoreTests/FakeSearchEngine.swift`: read-only: P1 fake.
- `Tests/AppCoreTests/NoteServiceTests.swift`: read-only: `makeService(function:)`
  helper.

## File-level changes

### `Sources/AppCore/SearchIndexSynchronizer.swift` (new)

- Declare the pinned public types `SearchIndexDrainReport` and
  `SearchIndexSynchronizer`, with the signatures given in the index.
- **Document builder.**
  `func searchIndexDocument(noteId: NoteID, in database: SQLiteDatabase) throws -> SearchIndexDocument?`
  is internal.
  - First check for the row with `SELECT 1 FROM notes WHERE note_id = ?`,
    and return nil when it is absent.
  - Then load the note with the unscoped
    `loadNote(_:in:)` (`Sources/AppCore/NoteService+Hydration.swift:29`). Do not use `requireNote`: it applies
    caller scope.
  - Read the notebook's `library_id` and `owner_user_id` from `notebooks`.
  - `tagIds` are the direct tag ids, sorted.
  - Compute `isLongTermMemory` with the notebook kind tag check that
    `isLongTermMemoryNotebook` uses.
  - Copy `createdAt` and `updatedAt` from the note.
- **`drainOnce(engine:batchSize:)`.** One pass:
  1. Generate a fresh claim token (UUID string) and set `now = self.now()`.
  2. Claim the batch with
     `service.claimSearchIndexOutbox(limit: batchSize, claimToken:, now:)`.
     With no rows, return the status-based report without calling the
     engine.
  3. In one `service.driver.withDatabase { }` read (no transaction needed),
     build the operations. A missing note becomes `.delete(noteId)`, and
     anything else becomes `.upsert(document)`. If building one document
     throws, that note is a failure with message
     "document build failed: <error>" and is not sent to the engine.
  4. Call `try await engine.apply(operations)`. If it throws, every claimed
     row fails with `String(describing: error)`. If it returns, match
     results to rows by `noteId`; a row with no matching result fails with
     "missing result".
  5. Call `service.settleSearchIndexOutbox(succeeded:failed:claimToken:now:)`
     with a fresh `now`.
  6. Return a report built from `service.searchIndexOutboxStatus(now:)`:
     `pushed` = succeeded count, `failed` = failed count,
     `remaining` = `pending`, `remainingDue` = `due`.
- **`drainUntilIdle(engine:batchSize:)`.**
  - Repeat `drainOnce` until `remainingDue == 0`, or until a pass pushes 0
    rows. A pass that pushes nothing makes no progress, for example when
    everything failed and is backing off.
  - Accumulate `pushed` and `failed` across passes. Take `remaining` and
    `remainingDue` from the last pass.
- Doc comments cite design SE3 and the invariant that engine calls never run
  inside a transaction.

## Pitfalls

- Never call `engine.apply` inside `driver.withDatabase` or a transaction.
  The engine call goes between the read closure and the settle call.
- Error messages stored in `last_error` come from
  `SearchEngineError.description`, which is already sanitized. Never
  interpolate URLs or configuration values.
- `drainUntilIdle` must terminate even when the engine keeps failing. The
  zero-progress rule is required.
- Do not re-read `generation` at settle. Pass the rows returned by claim.
- `loadNote` is a free function used across AppCore. Use the same one
  `currentFTSPayload` uses, and do not reimplement note loading.

## Tests

`SearchIndexSynchronizerTests` (XCTest; use `makeService(function:)`,
`FakeSearchEngine`, and an injected `now` clock):

- An activated store with 2 notes, drained once: the fake has 2 documents.
  A document's `body` equals `noteRetrievalText` of the note, its `context`
  equals `ftsContextPayload`, and its `tagIds` and `tagNames` are sorted.
  The report shows `pushed 2`, `remaining 0`, `remainingDue 0`.
- Delete a note after activation, then drain: the fake receives
  `.delete(noteId)`, and the document is gone.
- Set the fake's `failure = .unavailable("down")`: the note write still
  commits and is readable through `service.getNote(_:)`. The drain reports
  `failed == 2`, `remaining == 2`, `remainingDue == 0` (backing off), and
  the rows' `last_error` contains "search engine unavailable". Clear the
  failure, advance the clock 6 seconds, and drain: the rows succeed.
- With the fake's `failingNoteIds` containing one note, only that row fails
  and stays, and the other is removed.
- Generation race: claim, then update the note (which bumps the
  generation), then settle through a drain. Simulate this with the fake's
  `onApply` hook (P1), which performs the note update before `apply`
  returns. The row remains, and the next drain pushes the new body.
- `drainUntilIdle` with 250 activated notes and batch size 100 makes 3
  apply calls and pushes 250. With an always-failing fake it returns after
  one pass.
- Long-term memory: a note in the long-term memory notebook builds a
  document with `isLongTermMemory == true`.
- Not activated: drain returns all zeros and makes 0 engine calls.

## Verification

```bash
mise run build
bash -c 'mkdir -p tmp/search-engine-adapter/P4 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter SearchIndexSynchronizer 2>&1 | tee tmp/search-engine-adapter/P4/drain.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P4 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter SearchEngineSyncOutbox 2>&1 | tee tmp/search-engine-adapter/P4/outbox.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P4 && mise run lint 2>&1 | tee tmp/search-engine-adapter/P4/lint.log; echo exit=${PIPESTATUS[0]}'
wc -l Sources/AppCore/SearchIndexSynchronizer.swift
```

Expected evidence:

- `exit=0` for every run.
- The test count is greater than 0.
- The file is under 1000 lines.

## Done criteria

- [x] `SearchIndexSynchronizer` and `SearchIndexDrainReport` exist with the
      pinned API.
- [x] Documents mirror the FTS text derivation. Deletes are pushed for
      missing notes.
- [x] Failures never affect the note write and back off through P2 settle.
      Generation races keep the row.
- [x] All verification commands show `exit=0`.

## Progress Log

- 2026-10-04: Plan created.
- 2026-10-04: Implemented the pinned synchronizer API and FTS-matched document builder. The drain claims with a fresh UUID, builds operation/row pairs in one database read, applies after leaving that closure, maps missing/per-note/throwing failures, settles with a fresh clock value, and reports backlog counts. `drainUntilIdle` accumulates results and stops on no due rows or zero progress.
- 2026-10-04: Added 7 `SearchIndexSynchronizerTests` covering two-document upsert and derivation, delete, failure isolation and retry, per-note failure, generation race and re-push, 250-note batching and zero-progress termination, long-term-memory metadata, and inactive-store behavior.
- 2026-10-04: Final verification passed: `mise run build` (exit 0; `tmp/search-engine-adapter/P4/build-final.log`); `PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter SearchIndexSynchronizer` (7 tests, 0 failures; `tmp/search-engine-adapter/P4/drain-final.log`); `PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter SearchEngineSyncOutbox` (8 tests, 0 failures; `tmp/search-engine-adapter/P4/outbox-attempt1.log`); `mise run lint` (exit 0; 3 shared-tree warnings, none in P4; `tmp/search-engine-adapter/P4/lint-final.log`); strict changed-file SwiftLint (exit 0; `tmp/search-engine-adapter/P4/swiftlint-changed-final2.log`); `wc -l Sources/AppCore/SearchIndexSynchronizer.swift Tests/AppCoreTests/SearchIndexSynchronizerTests.swift` (172 and 191 lines).
- 2026-10-04: The preserved `drain-attempt1.log` and `drain-attempt2.log` record transient P5 and P3 compile blockers in the moving shared tree. P4's initial XCTest clock-capture diagnostics were corrected; the earlier failed `drain-final.log` was overwritten by its successful current-source rerun, so that first attempt is not preserved as a complete log. Final build and behavioral reruns pass. Independent review and the combined-tree serial integration review remain downstream.
