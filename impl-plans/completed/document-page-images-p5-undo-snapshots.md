# P5: Undo Snapshots Carry Search Text; Undo/Redo Body Guard

**planId**: P5-undo-snapshots
**Wave**: 2
**dependsOn**: P1-storage-contract
**Status**: Completed. Accepted in session-246 (test-integrity, adversarial and serial integration review). The combined-tree `mise run check` exited 0 (`tmp/document-page-images/reconcile-session-246/wave5/full-check.log`). Archived at Step 8 on 2026-10-02.
**Design Reference**: `design-docs/specs/design-document-page-images.md` DP3 item 3 (the `applyNoteBodyDelta` guard), DP6, I1
**Index**: `impl-plans/active/document-page-images.md`

## Intent and context

Deleting a note or notebook records a restorable snapshot through
`captureNoteSnapshot` in `Sources/AppCore/NoteService+ActionHistory.swift`, and
undo re-inserts it through `restoreNoteSnapshot`. Page notes now keep their OCR
in `notes.search_text`. Without this plan, undoing a page deletion would lose the
OCR text.

Snapshots recorded before version 22 hold OCR in `bodyMarkdown`. Restoring one
must apply the same transform as the migration.

Separately, undo and redo of body edits go through `applyNoteBodyDelta` in
`Sources/AppCore/NoteService+UndoRedo.swift`. That function writes
`body_markdown` directly, so it must refuse document page notes. Otherwise,
redoing an old OCR completion could put OCR text back into the body.

## Non-goals

- Do not change the action-history schema or record kinds.
- Do not rewrite stored historical snapshots.
- Do not change undo for non-page notes.

## writePaths

- `Sources/AppCore/NoteService+ActionHistory.swift`
- `Sources/AppCore/NoteService+UndoRedo.swift`
- `Tests/AppCoreTests/DocumentPageUndoTests.swift` (new)
- `impl-plans/active/document-page-images-p5-undo-snapshots.md` (Progress Log only)

## sharedPaths (read-only)

- `Sources/AppCore/NoteRetrievalText.swift`
  (`documentPageTextMigration`, `NoteService.isDocumentPageNote`).

## File-level changes

1. **`captureNoteSnapshot`**: add `search_text` to the SELECT, and add the key
   `"searchText": .optionalString(noteRow["search_text"])`. `captureNotebookSnapshot`
   stores notebook fields and notebook tags only; it does not embed note
   snapshots and is used to undo creation of an empty notebook. Notebook
   deletion stays recorded but non-undoable under U10.
2. **`restoreNoteSnapshot`**:
   - Read `note["searchText"]?.asString`. A missing key and JSON null both mean
     nil.
   - Compute
     `let restored = documentPageTextMigration(bodyMarkdown: bodyMarkdown, searchText: searchText, metaJSON: note["metaJSON"]?.asString)`.
   - Insert `restored.bodyMarkdown` and add `search_text` as the last column with
     `.optionalText(restored.searchText)`.
   - Callers already refresh FTS after restore. Keep that unchanged.
3. **`applyNoteBodyDelta`** (`NoteService+UndoRedo.swift`): right after
   `requireWritableNote`, add
   `if Self.isDocumentPageNote(note) { throw NoteServiceError.conflict("document page text is managed by OCR; this body edit can no longer be undone or redone: \(noteId)") }`.
   The guard must run before any write.

## Pitfalls

- An old snapshot of a non-page note has no `searchText` key. It must restore
  with `search_text NULL`, not `''`. `documentPageTextMigration` returns the
  inputs unchanged for non-page metadata.
- A new snapshot of a pending page has `searchText: ""`. Restore it as `''`, not
  NULL.
- A refused undo or redo must leave the action-log cursor unchanged. Follow
  existing conflict behaviour, and verify in the test that a second undo attempt
  still reports the same conflict and does not skip an entry.

## Tests to add (`DocumentPageUndoTests.swift`)

Imitate the fixtures in `Tests/AppCoreTests/NoteActionHistoryTests.swift`.
Create page drafts with `readOnly: false` in a writable notebook.
`NotePageDraft.readOnly` defaults to true, and delete and undo require
writability.

- Delete a page note whose search text is "Orbital chart text", then undo ->
  the note is restored with body `""` and `search_text` "Orbital chart text";
  `searchNotes("Orbital")` finds it.
- Delete a normal note, then undo -> `search_text IS NULL`, and the body is
  restored as before.
- Legacy snapshot: build a snapshot JSON without a `searchText` key, with
  `bodyMarkdown` "Legacy OCR words" and `documentPage` metadata. Restore it
  through `restoreNoteSnapshot` inside a transaction -> body `""`, and
  `search_text` "Legacy OCR words".
- Delete a whole notebook containing a page note -> the action is recorded as
  non-undoable (U10 unchanged). Page `search_text` preservation is covered by
  deleting and undoing the page note in
  `testUndoDeleteRestoresPageSearchTextAndSearchability`.
- Body-edit undo on a page note:
  1. Create a page note, then make it a normal note by clearing `documentPage`
     from `meta_json` with SQL.
  2. Edit the body through `updateNoteBody`.
  3. Restore the `documentPage` metadata with SQL.
  4. Call undo.
  Expected: `conflict` containing "document page text is managed by OCR". The
  body and `search_text` are unchanged.
- The same undo on a normal note still works. This is the regression check.

## Verification commands and required evidence

Use the prefix `PKG_CONFIG_PATH="$PWD/.build/anydoc-native/host/pkgconfig" mise exec --`
and save logs to `tmp/document-page-images/P5/`.

- `swift test --filter DocumentPageUndo`. Must exit 0.
- `swift test --filter NoteActionHistory`. Must exit 0.
- `swift test --filter UndoRedo`, or the existing undo test class (find it with
  `grep -rln "func undo" Tests/AppCoreTests`). Must exit 0.
- `mise run lint`. Must exit 0.

## Done criteria

- [x] `grep -n "searchText" Sources/AppCore/NoteService+ActionHistory.swift` matches the capture and restore code.
- [x] `grep -n "isDocumentPageNote" Sources/AppCore/NoteService+UndoRedo.swift` matches.
- [x] All commands above exit 0, and logs are saved.

## Progress Log

- 2026-10-01: Plan created.
- 2026-10-02: Implemented `searchText` capture and migration-aware restore in
  `NoteService+ActionHistory.swift`, plus the page-note body-delta conflict
  guard in `NoteService+UndoRedo.swift`. Added six tests in
  `DocumentPageUndoTests.swift` for page and normal note snapshots, legacy
  snapshots, pending pages, action-cursor stability, and normal-note undo.
- 2026-10-02: Selected-file strict SwiftLint passed (log:
  `tmp/document-page-images/P5/changed-swiftlint.log`, exit 0); `mise run lint`
  passed (log: `tmp/document-page-images/P5/repository-lint.log`, exit 0; five
  warnings include two in downstream `DocumentPageChatContextTests.swift`).
  The grep criteria passed (log: `tmp/document-page-images/P5/capture-restore-grep.log`,
  exit 0).
- 2026-10-02: Required test commands did not reach XCTest. All three failed at
  shared-tree AppCore compilation (`AgentGatewayImageTransport.swift` cannot
  find `ImageOCRDocumentConverter`; `DocumentPageChatContext.swift` has an
  invalid `Data().utf8`; `NoteService+AgentChat.swift` has an argument order
  error). Logs: `document-page-undo.log`, `note-action-history.log`, and
  `undo-redo.log` under `tmp/document-page-images/P5/`; each records exit 1.
  These files are outside P5 writePaths, so the behavioral gate awaits the
  owning plans/serial integration repair.
- 2026-10-02: The requested whole-notebook-delete-then-undo test conflicts
  with existing U10 behavior: `deleteNotebook` is recorded as non-undoable and
  deletes note rows without snapshots (`Sources/AppCore/NoteService+ReadOnly.swift`).
  The implemented tests cover page-note undo from an imported notebook without
  changing that policy. Resolve this test-contract mismatch before marking P5
  complete; no action-history schema or notebook deletion behavior was changed.
- 2026-10-02: Final verification on the current shared tree passed:
  `DocumentPageUndo` (6 tests), `NoteActionHistory` (25 tests), and `UndoRedo`
  (1 test); complete logs with exit codes are
  `tmp/document-page-images/P5/current-document-page-undo-rerun.log`,
  `current-note-action-history.log`, and `current-undo-redo-rerun.log`.
  The first current-tree `UndoRedo` attempt stopped because
  `AITagExtraction.swift` changed during compilation; the immediate rerun
  rebuilt and passed (the first-attempt log is
  `tmp/document-page-images/P5/current-undo-redo.log`). The earlier compile
  errors are therefore superseded by current-source passing runs.
- 2026-10-02: Exact changed-file strict SwiftLint passed for the two P5
  production files and `DocumentPageUndoTests.swift` (manifest:
  `tmp/document-page-images/P5/changed-swift-files.nul`; log:
  `current-changed-file-swiftlint.log`, exit 0). `mise run lint` exited 0
  (`current-repository-lint.log`) with three diagnostics in files outside P5:
  `NoteService.swift`, `ResendGatewayCLIMailSender.swift`, and
  `AITranslationTests.swift`. Grep and `git diff --check` also passed.
- 2026-10-02: Notebook snapshot inspection confirmed
  `captureNotebookSnapshot` stores only notebook fields and notebook tags; it
  does not embed notes. It is used only to undo creation of an empty notebook.
  Whole-notebook deletion remains explicitly non-undoable under U10, so the
  original populated-notebook delete-and-undo case contradicted the established
  action-history contract. Corrected the plan to assert non-undoable deletion
  of a notebook containing a page note; page `search_text` restoration remains
  covered by `testUndoDeleteRestoresPageSearchTextAndSearchability`. No notebook
  deletion policy or snapshot semantics changed.
- 2026-10-02: P5 feedback repair completed. Added
  `testDeleteNotebookContainingPageNoteRemainsNonUndoable`; the test confirms
  U10 action history, no undo target, and deletion of the page note. The search
  text restore/searchability test remains separate. Attempt-3 verification:
  `DocumentPageUndo` 7/7, `NoteActionHistory` 25/25, and `UndoRedo` 1/1 all
  passed; strict changed-file SwiftLint and `mise run lint` exited 0. Static
  grep and `git diff --check` exited 0. Logs and NUL manifest are under
  `tmp/document-page-images/P5/attempt-3/`; repository lint reports three
  diagnostics outside P5. Test-integrity and adversarial reviews both accepted
  with no findings. Earlier shared-tree build failures and the prior six-test
  run above are historical; the attempt-3 results reflect the corrected test.
