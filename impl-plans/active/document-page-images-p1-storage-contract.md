# P1: Storage Contract (search_text column, v22 migration, FTS retrieval text, body guard)

**planId**: P1-storage-contract
**Wave**: 1
**dependsOn**: none
**Status**: Not started
**Design Reference**: `design-docs/specs/design-document-page-images.md` DP2, DP3 (import draft field and body guard), DP4 (FTS row only), DP5, I1-I3
**Index**: `impl-plans/active/document-page-images.md` ("Pinned cross-plan contracts" is binding)

## Intent and context

Document page notes are notes whose `meta_json` has a `documentPage` object that
decodes as `ImportedPageMetadata`. Their OCR text moves out of `body_markdown`
into a new hidden column, `notes.search_text`. Search must keep finding that text
with the same ranking. Today the contentless FTS table `note_fts(title, body, tags, context)`
indexes `body_markdown` in `body`. After this plan it indexes the retrieval text,
which is the body joined with `search_text`.

This plan builds the storage foundation that every other server plan uses:

- the column;
- the schema-version-22 migration;
- the retrieval-text helpers;
- the FTS payload change;
- `NotePageDraft.searchText`;
- the body-write guard in `updateNoteBodyInDatabase`.

## Non-goals (do not do these here)

- Do not change import, OCR, figure or processor code. That is P3.
- Do not change snippets, LIKE search, tagging or agent tools. That is P4.
- Do not change undo snapshots or `applyNoteBodyDelta`. That is P5.
- Do not change chat code. That is P6.
- Do not change the FTS virtual-table definition and do not rebuild FTS globally.
- Do not add `searchText` to `Note`, GraphQL, KaibaClient or the CLI.
- Do not remove the `completingPendingDocumentOCR` parameter. P3 removes it.

## writePaths

- `Sources/AppCore/NoteRetrievalText.swift` (new)
- `Sources/AppCore/NoteStoreSchema.swift`
- `Sources/AppCore/NoteSearchIndex.swift`
- `Sources/AppCore/NoteModels.swift`
- `Sources/AppCore/NoteService.swift`
- `Tests/AppCoreTests/NoteRetrievalTextTests.swift` (new)
- `Tests/AppCoreTests/NoteStoreSchemaVersion22Tests.swift` (new)
- `Tests/AppCoreTests/NoteStoreSchemaTests.swift`
- `Tests/AppCoreTests/NoteStoreSchemaCanonicalTests.swift`
- `impl-plans/active/document-page-images-p1-storage-contract.md` (Progress Log only)

## sharedPaths (read-only)

- `Sources/AppCore/NoteService+DocumentPageOCR.swift`. Read
  `NoteService.importedPageMetadata(_:)`, which is the definition of a page note.
- `Sources/AppCore/NoteService+Maintenance.swift`. Read `checkStore`, which tests
  use as an FTS health check.

## File-level changes

1. **`NoteRetrievalText.swift`** (new): implement exactly the P1 signatures pinned
   in the index.
   - `noteSearchText(_:in:)` runs `SELECT search_text FROM notes WHERE note_id = ?`.
     It returns nil for NULL and for a missing row.
   - `noteSearchTexts` batches with `placeholders(count:)`. Imitate
     `Sources/AppCore/NoteSearch.swift:placeholders` and the
     `requireNotes`-style batch queries.
   - `isDocumentPageMetaJSON` must reuse `ImportedPageMetadata` decoding. Imitate
     `NoteService.importedPageMetadata`, but return a Bool and never throw.
   - `NoteService.retrievalText(for:)` and `retrievalTexts(for:)` open
     `driver.withDatabase` once and call the batch reader.
2. **`NoteModels.swift` `NotePageDraft`**:
   - Add `public var searchText: String?`.
   - Add `searchText: String? = nil` as the last init parameter. Existing call
     sites must compile unchanged.
3. **`NoteService.swift`**:
   - `insertNotebookWithNotes` (around line 565): add `search_text` as the last
     column of the `INSERT INTO notes`, bound with `.optionalText(page.searchText)`.
   - Derive the title as `noteTitle(from: page.bodyMarkdown) ?? page.searchText.flatMap { noteTitle(from: $0) }`.
   - `refreshFTS` already follows the insert. Keep that order.
   - `updateNoteBodyInDatabase`: after the existing `existing` lookup, add the
     guard `if !completingPendingDocumentOCR, Self.isDocumentPageNote(existing)`.
     It throws
     `NoteServiceError.invalidInput("document page text is managed by OCR; use a comment to annotate the page")`.
   - Keep the additions to this file at 20 lines or fewer. It is 938 lines and must
     stay below 1000.
4. **`NoteSearchIndex.swift`**:
   - `ftsPayload` adds `n.search_text` to its SELECT and sets
     `body: noteRetrievalText(bodyMarkdown: body_markdown, searchText: search_text)`.
   - `currentFTSPayload` reads `noteSearchText(noteId, in:)` and uses the same
     function.
   - Both functions must produce byte-identical strings for the same row. This is
     required for the contentless delete replay.
5. **`NoteStoreSchema.swift`**:
   - `currentVersion = 22`.
   - Append `search_text TEXT` as the last column of the `notes` DDL, after
     `meta_json`, before `UNIQUE`. A migrated store gets the column at the end
     through `ALTER TABLE`, so fresh and migrated column order must match.
   - `upgradeToVersion21` must record the literal `21`:
     `recordSchemaVersion(21, in: db)`, not `currentVersion`.
   - Rewrite `requireSupportedVersion`:
     - newest 19 or 20: run `upgradeToVersion21`, then `upgradeToVersion22`.
     - newest 21: run `upgradeToVersion22`.
     - newest 22: return.
     - newest > 22: future error.
     - newest < 19: legacy error (`required: currentVersion`).
   - Add `private static func upgradeToVersion22(in:)`. It runs these steps in one
     `database.transaction`, in this order:
     1. If `PRAGMA table_info(notes)` lacks `search_text`, run
        `ALTER TABLE notes ADD COLUMN search_text TEXT`.
     2. Select `note_id`, `body_markdown` and `meta_json` (as `json(meta_json)`)
        for notes with `json_extract(meta_json, '$.documentPage') IS NOT NULL AND search_text IS NULL`,
        `ORDER BY note_id`.
     3. For each selected note, apply
        `isDocumentPageMetaJSON(meta)`. Skip rows whose `documentPage` does not
        decode; they are not page notes.
     4. For each remaining note: read `ftsPayload` first; then run
        `UPDATE notes SET search_text = body_markdown, body_markdown = '' WHERE note_id = ?`;
        then call `refreshFTS(noteId:previous:)`.
     5. Record version 22 last, inside the same transaction.
   - Imitate `upgradeToVersion21` for transaction and column-check style.

## Pitfalls a careless implementation gets wrong

- Step 1 (ADD COLUMN) must run before any `ftsPayload` call. After this plan,
  `ftsPayload` selects `search_text`, and on a version-21 store without the
  column it would throw.
- Do not touch `title`, `title_source`, `updated_at`, `updated_by` or `meta_json`
  during migration. Do not enqueue auto-actions, record action history, or
  publish change events from migration.
- Do not use `currentVersion` inside `upgradeToVersion21`. If you do, a crash
  between the 21 and 22 transactions leaves a store marked 22 that was never
  migrated.
- `requireSupportedVersion` runs before the `CREATE TABLE IF NOT EXISTS`
  statements. `CREATE ... IF NOT EXISTS` never adds the column to an existing
  table. Only the ALTER does that.
- The guard must use `Self.isDocumentPageNote(existing)`. Do not use a string
  search on `metaJSON`.
- Do not change `rebuildNoteFTS`. It already calls `refreshFTS`, which now uses
  retrieval text.

## Tests to add

`NoteRetrievalTextTests.swift`:

- `("body", nil)` -> `"body"`.
- `("body", "")` -> `"body"`.
- `("", "ocr")` -> `"ocr"`.
- `("b", "o")` -> `"b\n\no"`.
- `documentPageTextMigration`:
  - page meta and nil searchText -> `("", body)`;
  - page meta and existing searchText -> unchanged;
  - non-page meta -> unchanged;
  - malformed meta JSON -> unchanged.
- `isDocumentPageMetaJSON`:
  - valid `documentPage` -> true;
  - nil, `"{}"`, `"{"`, or `documentPage` missing `originFileId` -> false.

`NoteStoreSchemaVersion22Tests.swift`. Build a version-21 fixture in code and
imitate `NoteStoreSchemaTests.testVersion19UpgradePreservesCredentialsAndAcceptsCodex`:

1. Prepare a store.
2. Create notes through `createNotebookWithNotes` with drafts:
   - a complete page draft, metaJSON `documentPage` with `ocrState` complete,
     `searchText` "Alpha quantum ledger";
   - a pending page draft, `searchText` "";
   - a page draft whose text includes `"![Figure 1](/files/f1)"`;
   - a non-page note.
3. Convert the store back to the old representation for each page note: read
   `ftsPayload`, run
   `UPDATE notes SET body_markdown = search_text, search_text = NULL`, then call
   `refreshFTS`.
4. Run `ALTER TABLE notes DROP COLUMN search_text`. Replace the
   `note_schema_version` rows with `21`.
   - `DROP COLUMN` needs SQLite 3.35 or later. If it throws on the linked SQLite,
     `XCTSkip` only this drop variant.
   - The "column already exists" variant must still run unconditionally.

Cases:

- prepare on the version-21 fixture:
  - every page note has body `''` and `search_text` equal to its former body
    (including the figure link text);
  - the non-page note has `search_text IS NULL` and an unchanged body;
  - titles and `updated_at` are unchanged;
  - versions are `[21, 22]`.
- After migration, `searchNotes(query: "quantum")` returns the complete page
  note, and `checkStore()` reports no missing or stale search rows (use the
  existing report fields).
- prepare twice -> second run is a no-op: same rows, and `note_schema_version`
  still `[21, 22]`.
- version-19 fixture (reuse the credential-table steps from the version-19 test)
  -> versions become `[19, 21, 22]`.
- version-20 fixture -> versions `[20, 21, 22]`.
- version 23 recorded -> `unsupportedFutureVersion(found: 23, supported: 22)`.
- version-21 fixture where the column already exists (no DROP) -> still migrates.
  This covers the column-check path.
- fresh store -> `PRAGMA table_info(notes)` last column is `search_text`;
  versions `[22]`.
- `createNotebookWithNotes` with a page draft (body `""`, searchText
  "Heading line\nrest") -> title is "Heading line", FTS finds "rest".
- `updateNoteBody` on a page note -> throws `invalidInput` containing
  "document page text is managed by OCR". `updateNoteBody` on a normal note
  still succeeds.
  - Fixture pitfall: `NotePageDraft.readOnly` defaults to `true`, and
    `requireWritableNote` runs before the guard. Create the page draft with
    `readOnly: false` in a writable notebook. Otherwise the test only sees the
    existing read-only error.

Existing tests to update:

- `NoteStoreSchemaTests.testVersion19UpgradePreservesCredentialsAndAcceptsCodex`:
  expect versions `[19, 21, 22]`.
- `NoteStoreSchemaCanonicalTests.testCurrentVersionIsTwentyOneAndAVersionEighteenStoreIsRefused`:
  rename the test to say twenty-two and assert 22.

## Verification commands and required evidence

- `mise run build`. Must exit 0.
- `PKG_CONFIG_PATH="$PWD/.build/anydoc-native/host/pkgconfig" mise exec -- swift test --filter NoteStoreSchema 2>&1 | tee tmp/document-page-images/P1/schema.log; echo "exit=${PIPESTATUS[0]}"`.
  Must exit 0, with the new version-22 tests listed as passed.
- The same command with `--filter NoteRetrievalText`, log `retrieval.log`. Must
  exit 0.
- The same command with `--filter NoteSearch`, log `search.log`. Must exit 0.
  This shows that non-page search behaviour did not regress.
- The same command with `--filter NoteStoreMaintenance`, log `maintenance.log`.
  Must exit 0.
- `mise run lint`. Must exit 0, with no new warnings in the edited files.
- `wc -l Sources/AppCore/NoteService.swift Sources/AppCore/NoteStoreSchema.swift`.
  Both must be under 1000.

Expected transitional state: until P3 lands, imports still put OCR text into
the body. That is not a P1 failure. Do not run or fix `DocumentPage*` tests
here.

## Done criteria (mechanically checkable)

- [x] `grep -n "currentVersion = 22" Sources/AppCore/NoteStoreSchema.swift` matches.
- [x] `grep -n "recordSchemaVersion(21" Sources/AppCore/NoteStoreSchema.swift` matches.
- [x] `grep -n "search_text" Sources/AppCore/NoteSearchIndex.swift` matches.
- [x] All listed test commands exit 0, and logs are saved under `tmp/document-page-images/P1/`.
- [x] The Progress Log records pre/post SHA-256 for every edited file.

## Progress Log

- 2026-10-01: Plan created.
- 2026-10-02: Implemented the P1 storage contract. Added the shared retrieval-text
  helper and accessors; appended nullable `notes.search_text`; moved schema version
  21 to a literal version record and added the transactional/idempotent v22 body
  migration with FTS refresh; updated both FTS payload paths, page draft inserts,
  derived-title fallback and page body-write guard. Added helper, migration,
  version-selection, insertion and write-guard tests. Pre/post SHA-256 values are
  recorded in `tmp/document-page-images/P1/file-sha256-ledger.txt`; the final
  plan-file SHA-256 is in `tmp/document-page-images/P1/plan-post-sha256.txt`.
  Verification logs: `build-final.log` passed; `schema-final-current.log` passed
  23 tests; `retrieval-final.log` passed 4 tests, including duplicate inputs;
  `search-final-current.log` passed 1 test; `maintenance-final-current.log`
  passed 5 tests; `lint-final.log` exited 0 with three existing warnings. The
  selected-file strict SwiftLint command exited 1 on the unchanged
  `NoteService.swift:720` large-tuple warning; `git show HEAD` confirms the tuple
  predates P1. No P1 edits were made to that unrelated method. `NoteService.swift`
  is 942 lines and `NoteStoreSchema.swift` is 873 lines. No review, commit or push
  is claimed here; those are downstream workflow steps.
- 2026-10-02 (Step 6 test repair, recorded during serial reconciliation): two
  weak assertions in `testVersion21MigrationMovesPageBodyAndPreservesFTSSearchability`
  were tightened by reviewer-directed repair. The title/updated_at preservation
  check now runs after migration, and the FTS health check asserts
  `searchIndexHealthy`, no missing notes and no orphaned rows. The post-repair
  SHA-256 of `Tests/AppCoreTests/NoteStoreSchemaVersion22Tests.swift` is
  `a8c5c613a7c7967ee991129b130800dda382ced41a0d7a99bb04a1ba352b5f2d`; this
  supersedes the entry for that file in `file-sha256-ledger.txt`. Logs:
  `tmp/document-page-images/P1/schema-step6-repair.log` and
  `schema-step6-review.log`.
