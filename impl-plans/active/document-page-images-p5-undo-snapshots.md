# P5: Undo Snapshots Carry Search Text; Undo/Redo Body Guard

**planId**: P5-undo-snapshots
**Wave**: 2
**dependsOn**: P1-storage-contract
**Status**: Not started
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
   `"searchText": .optionalString(noteRow["search_text"])`. Check whether
   `captureNotebookSnapshot` embeds per-note snapshots through
   `captureNoteSnapshot`.
   - If it does, no extra change is needed.
   - If it captures notes with its own query, add `search_text` there in the same
     way.
   Record what you found in the Progress Log.
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
- Delete a whole notebook containing a page note, then undo -> the page note's
  `search_text` is preserved.
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

- [ ] `grep -n "searchText" Sources/AppCore/NoteService+ActionHistory.swift` matches the capture and restore code.
- [ ] `grep -n "isDocumentPageNote" Sources/AppCore/NoteService+UndoRedo.swift` matches.
- [ ] All commands above exit 0, and logs are saved.

## Progress Log

- 2026-10-01: Plan created.
