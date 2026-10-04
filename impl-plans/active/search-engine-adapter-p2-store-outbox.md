# P2 Store outbox: schema v23, gated enqueue hooks, activation, claim and settle

**Status**: Ready
**planId**: P2-store-outbox
**Wave**: 1
**dependsOn**: none
**Design Reference**: `design-docs/specs/search-engine-adapter.md` SE3 (Schema, Enqueue, Activation and backfill, Drain steps 1 and 4)
**Index**: `impl-plans/active/search-engine-adapter.md`

## Intent and context

Every change to a note's indexed fields must leave a durable, coalesced row
in a local outbox, inside the same write transaction. A store that has never
been activated must write nothing. This plan owns:

- the store tables and the v23 schema bump;
- the enqueue hooks at the four call sites;
- activation and backfill;
- the claim, settle and status primitives that P4, P7 and P8 use.

It does not call any engine and uses no `SearchEngine` type.

Repository facts:

- `NoteStoreSchema.prepare` (`Sources/AppCore/NoteStoreSchema.swift:52`)
  calls `requireSupportedVersion` before `schemaStatements` run.
  `upgradeToVersion22` calls `refreshFTS`.
- `refreshFTS` (`Sources/AppCore/NoteSearchIndex.swift`) is the single
  choke point for indexed-text writes.
- `deleteNoteRows` (`Sources/AppCore/NoteService.swift:913`) is the single
  choke point for note deletion.
- Two notebook-level library changes bypass `refreshFTS`:
  - `moveNotebook`, in `Sources/AppCore/NoteService+Libraries.swift`;
  - the library rehome branch of `ensureTagMemoNotebook(tagId:)`, the
    `UPDATE notebooks SET library_id = ?` near line 375 of
    `Sources/AppCore/NoteService+TagDetail.swift`.
- Timestamps: use `noteStoreTimestamp(from:)`
  (`Sources/AppCore/NoteStoreSchema.swift:852`). It produces ISO-8601 with
  fractional seconds, and the strings compare lexicographically.

## Non-goals

- No drain loop, no document building, and no engine calls (those are P4).
- No GraphQL, CLI or server changes.
- No `NoteService.searchEngine` property. P5 adds it in wave 2.
- No change to FTS content, `note_fts` or any search query.

## writePaths

- `Sources/AppCore/SearchEngineSyncOutbox.swift`
- `Sources/AppCore/NoteStoreSchema.swift`
- `Sources/AppCore/NoteSearchIndex.swift`
- `Sources/AppCore/NoteService.swift`
- `Sources/AppCore/NoteService+Libraries.swift`
- `Sources/AppCore/NoteService+TagDetail.swift`
- `Tests/AppCoreTests/SearchEngineSyncOutboxTests.swift`
- `Tests/AppCoreTests/NoteStoreSchemaVersion23Tests.swift`
- `Tests/AppCoreTests/NoteStoreSchemaVersion22Tests.swift`
- `Tests/AppCoreTests/NoteStoreSchemaTests.swift`
- `Tests/AppCoreTests/NoteStoreSchemaCanonicalTests.swift`
- `impl-plans/active/search-engine-adapter-p2-store-outbox.md`

New files: `Sources/AppCore/SearchEngineSyncOutbox.swift`, `Tests/AppCoreTests/SearchEngineSyncOutboxTests.swift`, `Tests/AppCoreTests/NoteStoreSchemaVersion23Tests.swift`.

## sharedPaths (read-only)

- `Sources/AppCore/NoteService+LibraryEnforcement.swift`
- `Tests/AppCoreTests/NoteServiceTests.swift`

## sharedPathNotes

- `Sources/AppCore/NoteService+LibraryEnforcement.swift`: read-only: reference
  patterns, namely the `requireStoreAdministrator` pattern.
- `Tests/AppCoreTests/NoteServiceTests.swift`: read-only: the
  `makeService(function:)` and `makeNoteDriver` helpers.

## File-level changes

### `Sources/AppCore/SearchEngineSyncOutbox.swift` (new)

- **Schema statements.** `let searchEngineSyncSchemaStatements: [String]`
  (internal) holds exactly the two `CREATE TABLE IF NOT EXISTS` statements
  from design SE3, with columns, types and defaults verbatim. There are no
  foreign keys.
- **Enqueue by note ids.** `enqueueSearchEngineSync(noteIds:in:)` runs, per
  id, the gated upsert:
  `INSERT INTO search_index_outbox (note_id) SELECT ? WHERE EXISTS (SELECT 1 FROM search_engine_sync_state) ON CONFLICT(note_id) DO UPDATE SET generation = generation + 1, attempts = 0, next_attempt_at = NULL, last_error = NULL`.
  It must NOT touch `claim_token` or `claimed_until`.
- **Enqueue by notebook.** `enqueueSearchEngineSync(notebookId:in:)` is the
  same upsert in its `INSERT ... SELECT note_id FROM notes WHERE notebook_id = ? AND EXISTS (SELECT 1 FROM search_engine_sync_state) ON CONFLICT ...`
  form.
- **Activation.** `activateSearchEngineSync(indexIdentity:)` runs in one
  `driver.withDatabase { try $0.transaction { ... } }`:
  - It reads the state row.
  - If the row is absent, it inserts `(1, identity, now)` and enqueues every
    note.
  - If the identity differs, it updates the identity and enqueues every
    note.
  - If the identity is unchanged, it does nothing.
  - It returns whether it enqueued.
- **Enqueue every note.** The all-notes statement is
  `INSERT INTO search_index_outbox (note_id) SELECT note_id FROM notes WHERE true ON CONFLICT(note_id) DO UPDATE SET ...`.
  The `WHERE true` is required: without a WHERE clause, SQLite cannot parse
  an upsert on `INSERT ... SELECT`.
- **Reindex enqueue.** `enqueueAllNotesForSearchEngineSync()` runs the same
  all-notes upsert, gated by `AND EXISTS (SELECT 1 FROM search_engine_sync_state)`.
  It returns the number of notes when activated and 0 otherwise.
- **Claim.** `claimSearchIndexOutbox(limit:claimToken:now:leaseSeconds:)`
  runs in one transaction:
  1. A single `UPDATE search_index_outbox SET claim_token = ?, claimed_until = ? WHERE note_id IN (SELECT note_id FROM search_index_outbox WHERE (next_attempt_at IS NULL OR next_attempt_at <= ?) AND (claim_token IS NULL OR claimed_until <= ?) ORDER BY attempts, note_id LIMIT ?)`.
  2. Then `SELECT note_id, generation, attempts ... WHERE claim_token = ?`.

  `limit <= 0` returns `[]` without writing.
- **Settle.** `settleSearchIndexOutbox(succeeded:failed:claimToken:now:)`
  runs in one transaction:
  - **Success:** `DELETE ... WHERE note_id = ? AND claim_token = ? AND generation = ?`.
    If that deleted no row, release the claim with
    `UPDATE ... SET claim_token = NULL, claimed_until = NULL WHERE note_id = ? AND claim_token = ?`.
  - **Failure:**
    `UPDATE ... SET claim_token = NULL, claimed_until = NULL, attempts = attempts + 1, next_attempt_at = ?, last_error = ? WHERE note_id = ? AND claim_token = ?`.
    - `next_attempt_at = now + min(5 * 2^(row.attempts), 3600)` seconds,
      where `row.attempts` is the value read at claim. So the first failure
      waits 5 seconds and the second waits 10.
    - `last_error` is the message truncated to 500 characters.
- **Status.** `searchIndexOutboxStatus(now:)` reports:
  - `isActivated` and `indexIdentity`, from the state row;
  - `pending = COUNT(*)`;
  - `failing = COUNT(*) WHERE attempts > 0`;
  - `due` = the count of rows that are due and unclaimed or expired, using
    the same predicate as claim;
  - `nextDueAt = MIN(next_attempt_at)`.
- **Types and docs.** Declare the pinned public types. Each function has
  a one-line doc comment that cites design SE3.

### `Sources/AppCore/NoteStoreSchema.swift`

- `currentVersion = 23`.
- In `prepare(in:)`, after `try database.execute(noteSchemaVersionTableStatement)`
  and BEFORE `try requireSupportedVersion(in: database)`, execute every
  statement in `searchEngineSyncSchemaStatements`.
- Version handling in `requireSupportedVersion`:
  - newest 19 or 20: `upgradeToVersion21`, then 22, then 23;
  - newest 21: 22, then 23;
  - newest 22: 23.
- `upgradeToVersion23` is a new private static function. In one
  transaction it only calls `recordSchemaVersion(23, in:)`.
- Update the doc comment on `requireSupportedVersion`.
- A fresh store records `currentVersion` (23) through the existing
  `isFirstSchemaCreation` path.
- Keep the file under 1000 lines (it is 873 now). Put no DDL text in this
  file.

### `Sources/AppCore/NoteSearchIndex.swift`

- At the end of `refreshFTS(noteId:previous:in:)`, add
  `try enqueueSearchEngineSync(noteIds: [noteId], in: database)`, with a
  one-line comment citing SE3.
- No other change.

### `Sources/AppCore/NoteService.swift`

- In `deleteNoteRows(noteId:in:)`, add one line before
  `DELETE FROM notes`: `try enqueueSearchEngineSync(noteIds: [noteId], in: database)`.
- No other edit. The file must stay at or under 941 lines.

### `Sources/AppCore/NoteService+Libraries.swift`

- In `moveNotebook`, directly after the
  `UPDATE notebooks SET library_id = ?` statement and inside the same
  transaction, add
  `try enqueueSearchEngineSync(notebookId: notebookId, in: db)`.

### `Sources/AppCore/NoteService+TagDetail.swift`

- In the rehome branch (`if let sourceLibraryId, existing.libraryId != sourceLibraryId`),
  directly after the library `UPDATE`, add
  `try enqueueSearchEngineSync(notebookId: existingId, in: db)`.
- Do not enqueue on the create branch, because a new notebook has no notes.

### Existing schema tests (keep their intent, bump expectations)

- `NoteStoreSchemaCanonicalTests`:
  - `currentVersion == 23`;
  - the version-18 refusal expects `required: 23`;
  - rename the test to `testCurrentVersionIsTwentyThreeAndAVersionEighteenStoreIsRefused`.
- `NoteStoreSchemaTests`: the `[19, 21, 22]` expectation becomes
  `[19, 21, 22, 23]`. Leave the other symbolic `currentVersion` uses as they
  are.
- `NoteStoreSchemaVersion22Tests`:
  - every `versions == [.., 22]` gains a trailing 23;
  - the future-version test inserts 24 and expects
    `.unsupportedFutureVersion(found: 24, supported: 23)`.

## Pitfalls

- **Table ordering.** The tables MUST exist before `requireSupportedVersion`
  runs. `upgradeToVersion22` calls `refreshFTS`, which now runs the
  enqueue SQL, and on an old store it would fail with "no such table".
- **No foreign keys.** Never add a foreign key on `note_id`: the row must
  outlive the deleted note.
- **Gating.** The enqueue must be gated by `EXISTS(search_engine_sync_state)`.
  Never enqueue unconditionally. With no state row, existing write tests
  must see zero outbox rows.
- **Claims.** A re-enqueue must not clear the claim. Settle must compare
  `generation` from the claimed row, never re-read it.
- **Atomic claim.** Do not claim with a SELECT and then an UPDATE outside
  one statement. The claim must be a single atomic UPDATE.
- **Turso.** The same SQL runs through `TursoNoteDatabaseDriver`. Use only
  plain SQLite features that are already used elsewhere in the schema file
  (upsert, subquery, LIMIT inside IN).
- **Hook placement.** Do not put the hook in `deleteFTSEntry`: it has no
  note id, and `refreshFTS` already calls it.
- **No transactions in hooks.** Do not add transactions inside the hook
  functions. They always run inside the caller's transaction.

## Tests

`SearchEngineSyncOutboxTests` (XCTest; use `makeService(function:)`):

- Not activated: create, update, tag apply and delete a note, then the
  outbox count is 0, and `status.isActivated == false`.
- Activate with "x:v1" on a store with 3 notes: returns true and gives 3
  rows. Activating again with "x:v1" returns false and leaves the
  generations unchanged. Activating with "x:v2" returns true and bumps
  every generation.
- After activation, each of these leaves a row for the expected ids:
  - note create and update;
  - note tag apply and remove;
  - tag reparent through `defineNoteTag` with a parent, which runs
    `refreshFTSForNotesUnderTag`;
  - undo of a body edit;
  - note delete, where the row stays and the note no longer exists;
  - notebook delete, which leaves rows for every note;
  - `moveNotebook`, which leaves rows for every note of the notebook;
  - a tag-memo rehome through `ensureTagMemoNotebook`, after its source
    notes move library, which leaves rows for the memo notebook's notes.
- Claim with limit 2 claims 2 rows. A second claim with another token
  before expiry claims only the remaining rows. After the lease expires
  (pass `now + 61s`) the rows can be claimed again.
- Settle success deletes the row. If a re-enqueue happens between claim and
  settle (generation bumped), settle success keeps the row and releases the
  claim.
- Settle failure gives `attempts == 1`, `next_attempt_at` 5 seconds after
  `now`, and the stored `last_error`. A message of 600 characters is
  truncated to 500. The row is not due at `now + 4s` and is due at
  `now + 6s`. A second failure gives a 10-second backoff. The cap is 3600
  seconds: at attempts 20 the backoff is still 3600.
- `enqueueAllNotesForSearchEngineSync()` returns 0 before activation and
  the note count after it.

`NoteStoreSchemaVersion23Tests` (XCTest):

- A fresh store records `[23]`, and both tables exist.
- A v22 store (built like the existing v22 fixtures) upgrades to
  `[.., 22, 23]` with the tables present.
- A v21 store with a document page note, the v22 migration fixture, runs
  through the v22 upgrade (which calls `refreshFTS`) without error, and its
  outbox stays empty because the store is not activated.

## Verification

```bash
mise run build
bash -c 'mkdir -p tmp/search-engine-adapter/P2 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter SearchEngineSyncOutbox 2>&1 | tee tmp/search-engine-adapter/P2/outbox.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P2 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter NoteStoreSchema 2>&1 | tee tmp/search-engine-adapter/P2/schema.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P2 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter NoteSearch 2>&1 | tee tmp/search-engine-adapter/P2/note-search.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P2 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter NoteStoreMaintenance 2>&1 | tee tmp/search-engine-adapter/P2/maintenance.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P2 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter Library 2>&1 | tee tmp/search-engine-adapter/P2/library.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P2 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter TagDetail 2>&1 | tee tmp/search-engine-adapter/P2/tag-detail.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P2 && mise run lint 2>&1 | tee tmp/search-engine-adapter/P2/lint.log; echo exit=${PIPESTATUS[0]}'
grep -n "currentVersion = 23" Sources/AppCore/NoteStoreSchema.swift
grep -n "enqueueSearchEngineSync" Sources/AppCore/NoteSearchIndex.swift Sources/AppCore/NoteService.swift Sources/AppCore/NoteService+Libraries.swift Sources/AppCore/NoteService+TagDetail.swift
wc -l Sources/AppCore/NoteStoreSchema.swift Sources/AppCore/NoteService.swift Sources/AppCore/NoteService+TagDetail.swift Sources/AppCore/SearchEngineSyncOutbox.swift
```

Expected evidence:

- Every `swift test` run ends with `exit=0`.
- The grep shows exactly one hook per file in the four hook files.
- `NoteService.swift` is at or under 941 lines, and every file is under
  1000 lines.

## Done criteria

- [ ] Schema v23 is in place. The tables are created before the upgrade
      chain. The existing schema tests are updated with their intent kept.
- [ ] There are four gated enqueue call sites and no others.
- [ ] Activation, enqueue-all, claim, settle and status match the pinned
      signatures and semantics.
- [ ] A never-activated store gets zero outbox rows on every write path.
- [ ] All verification commands show `exit=0`, and the evidence is logged.

## Progress Log

- 2026-10-04: Plan created.
