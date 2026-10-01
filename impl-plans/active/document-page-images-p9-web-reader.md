# P9: Web Image-Only Reader and Page-Subject Edit-Mode Disable

**planId**: P9-web-reader
**Wave**: 1 (has no server dependency; it relies only on the existing `documentPage` metadata shape)
**dependsOn**: none
**Status**: Not started
**Design Reference**: `design-docs/specs/design-document-page-images.md` DP1, DP8 item 1 (web composer), DP10 (web)
**Index**: `impl-plans/active/document-page-images.md`

## Intent and context

When a notebook contains document page notes, `web/src/panes/ReaderPane.tsx`
renders `web/src/components/DocumentNotebookReader.tsx`. That reader currently
has a Text/Original toggle: the `mode` signal and the `role="group"
aria-label="Page display mode"` group. In Text mode it renders `bodyMarkdown`
with `MarkdownBody` and an inline `NoteEditor`.

The user finds the toggle confusing and wants to see only the deterministic page
image. OCR text becomes hidden on the server. Agent note-edit mode must not be
offered for a page subject, because page bodies are not writable on the server
(DP3 and DP8).

## Non-goals

- Do not change `ReaderPane.tsx`. Its selection logic stays as it is.
- Do not change `web/src/notes/documentPages.ts` types or parsing.
- Do not change `web/src/notes/client.ts` or any GraphQL query.
- Do not change server-credential code or its tests.
- Do not touch `web/src-tauri/`.
- Do not remove CSS in `web/src/workspace.css`. Unused selectors are harmless,
  and broad cleanup is out of scope.
- Do not change `web/src/components/Markdown.tsx` (`storedImageFileId` remains
  for any Markdown with `/files/` links).

## writePaths

- `web/src/components/DocumentNotebookReader.tsx`
- `web/src/components/DocumentNotebookReader.integration.tsx`
- `web/src/notes/memoComposer.ts`
- `web/src/notes/memoComposer.test.ts`
- `impl-plans/active/document-page-images-p9-web-reader.md` (Progress Log only)

## sharedPaths (read-only)

- `web/src/components/MemoTab.tsx`. It calls
  `canEnableNoteEdit(subject(), app.state.note, app.notebook())` at about line
  158. No edit is needed if the full `Note` (which has `metaJSON`) is passed.
  Verify this, and record the evidence.
- `web/src/notes/documentPages.ts`. Use `documentPageMetadata(note)`.

## File-level changes

1. **`DocumentNotebookReader.tsx`**:
   - Remove the `mode` signal, the `Page display mode` group and both buttons,
     and the `<Show when={mode() === 'origin'} fallback=...>` branch.
   - Always render the `document-origin-stage` block for the current note. Keep
     the pointer-swipe handlers and the "This note has no original page image."
     fallback.
   - Remove the `MarkdownBody`, `NoteEditor`, `noteHeadingPrefix`,
     `tagTermsFromAssignments` and `writingMode` usages and imports that become
     unused.
   - The `notebookTags` and `onTagClick` props may become unused. Keep them in the
     props type so `ReaderPane.tsx` still compiles, and prefix them or leave them
     unused, as the lint rules allow.
   - Keep `binding()`, `pageStepForArrow`, the keyboard, swipe and button
     navigation, the page jump, batch loading and the stale-response handling.
   - OCR button label: change "OCR this page" to "Make page searchable". The busy
     label becomes "Making page searchable...", using three ASCII dots and no
     ellipsis character.
   - Show the pending notice "Text on this page is not searchable yet." when
     `ocrState === 'pending'`, near the OCR button, not inside a text body.
2. **`memoComposer.ts` `canEnableNoteEdit`**:
   - Widen the `note` parameter type to
     `{ noteId: NoteId; readOnly: boolean; metaJSON?: string | null } | undefined`.
   - Return false when `documentPageMetadata(note as Note)` is defined. Import
     from `./documentPages`, and avoid a cast if the typing allows it.

## Pitfalls

- Do not keep a hidden Text mode. The DOM must not contain `bodyMarkdown` text
  for page notes, even when the body is non-empty, because legacy data or older
  servers may still return text.
- Right-binding navigation semantics must not change. The existing test for
  original-mode navigation is the regression guard. Rename it, but keep its
  navigation assertions.
- Use ASCII text only in labels.
- `bun test` (unit) and `vitest` (DOM, `*.integration.tsx`) are separate runners.
  Run both.

## Tests to add or update

`DocumentNotebookReader.integration.tsx`:

- **Update** "original mode flips physical pages..." to "flips physical pages
  showing only original images". The image renders without clicking any mode
  button. Keep the next/previous, right-binding and stale-image-response
  assertions.
- **Replace** "figure Markdown fetches local images through the client..." with
  this case: a page note with
  `bodyMarkdown: 'Hidden OCR words ![Figure 1](/files/f1)'` -> the text
  "Hidden OCR words" is not in the document; no request for `f1` is made; the
  origin image request is made.
- **Update** "manual page OCR reports failure, allows retry, and displays the
  completed text":
  - the button "Make page searchable" fails, then retries successfully;
  - after completion the pending notice disappears and the image is still shown;
  - the test asserts no recognized text is displayed.
- **Add**: `screen.queryByRole('group', { name: 'Page display mode' })` is null,
  and there is no button named "Text" or "Original".

`memoComposer.test.ts`:

- **Add**: a note subject whose `metaJSON` is
  `{"documentPage":{"pageNumber":1,"ocrState":"complete","originFileId":"file-1","analysis":{}}}`
  -> `canEnableNoteEdit` is false. Use whatever minimal shape
  `documentPageMetadata` accepts; read `documentPages.ts` to confirm it.
- The same note without `metaJSON` -> true.
- The existing cases must stay unchanged.

## Verification commands and required evidence

- `cd web && mise exec -- bun test src/notes/memoComposer.test.ts 2>&1 | tee ../tmp/document-page-images/P9/unit.log; echo "exit=${PIPESTATUS[0]}"`.
  Must exit 0.
- `cd web && mise exec -- bun x vitest run src/components/DocumentNotebookReader.integration.tsx src/components/MemoTab.integration.tsx 2>&1 | tee ../tmp/document-page-images/P9/dom.log; echo "exit=${PIPESTATUS[0]}"`.
  Must exit 0.
- `grep -rn "Page display mode" web/src`. Must print nothing. Record the empty
  output.
- `mise run web:check 2>&1 | tee tmp/document-page-images/P9/web-check.log; echo "exit=${PIPESTATUS[0]}"`.
  Must exit 0. It covers typecheck, all unit and DOM tests (including the
  server-credential rule tests), lint and build.
- `mise run tauri:check 2>&1 | tee tmp/document-page-images/P9/tauri-check.log; echo "exit=${PIPESTATUS[0]}"`.
  Must exit 0 on macOS.

## Done criteria

- [x] `grep -rn "Page display mode\|setMode('text')" web/src` prints nothing.
- [x] `grep -n "documentPageMetadata" web/src/notes/memoComposer.ts` matches.
- [x] Every command above exits 0, and logs are saved under `tmp/document-page-images/P9/`.

## Progress Log

- 2026-10-01: Plan created.
- 2026-10-02: Removed the page display mode and Markdown/editor rendering from `DocumentNotebookReader`; the origin image stage now always renders while binding-aware navigation, page jump, batch loading, swipe handling, and stale image protection remain. Updated OCR action/busy labels and the pending-search notice. `canEnableNoteEdit` refuses subjects with parsed document-page metadata. Updated reader and composer tests for hidden legacy OCR, origin-image requests, OCR retry, mode removal, and edit eligibility. `MemoTab.tsx` already passes `app.state.note` to `canEnableNoteEdit` (line 158), so the shared path required no edit. Focused unit suite: 12 passed; focused DOM suites: 21 passed; `mise run web:check`: exit 0 with 173 unit and 75 DOM tests passed, typecheck/lint/build passed; `mise run tauri:check`: exit 0. Evidence logs: `tmp/document-page-images/P9/unit.log`, `dom.log`, `web-check.log`, and `tauri-check.log`.
- 2026-10-02 (step7 repair, recorded during serial reconciliation): the step7 adversarial review found that rendering only the origin stage for every note hid the Markdown body and `NoteEditor` of user-authored non-page notes in writable page notebooks. Now only notes whose `documentPageMetadata` parses render the origin-image stage. Other notes keep `MarkdownBody`, plus `NoteEditor` when they are selected. Because of this, the "This note has no original page image." fallback from File-level change 1 can no longer be reached, so it was removed. The shared `MarkdownBody` image-safety and authenticated-fetch test was restored during the test-integrity repair. Logs: `tmp/document-page-images/P9/step7-dom-rereview.log`, `step7-unit-rereview.log`, `step7-web-check.log`. The combined-tree `tauri:check` was rerun in reconciliation; its log is under `tmp/document-page-images/reconcile/`.
