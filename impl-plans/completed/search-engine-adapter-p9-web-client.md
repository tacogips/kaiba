# P9 Web client: capability, engine-backed search, Related notes section

**Status**: Completed. Accepted in session-264 (test-integrity, adversarial and integration review, comm-003910); code in b466ced, with gate-compatible evidence re-run in session-264. The combined-tree wave-8 reconcile passed (`tmp/search-engine-adapter/reconcile/session-264-wave8/reconcile-summary.md`). Archived to `impl-plans/completed/` at Step 8 on 2026-10-05.
**planId**: P9-web-client
**Wave**: 1
**dependsOn**: none (builds against the GraphQL SDL pinned in the index; all tests use mocks)
**Session-264 scope**: The code is complete in commit b466ced. Only the gate-compatible evidence was missing. Run the amended Verification below and record the two separate behavioral records. Fix code only for a real finding, within this plan's writePaths. P20 builds on this code in wave 2.
**Design Reference**: `design-docs/specs/search-engine-adapter.md` SE7, Invariant 1
**Index**: `impl-plans/completed/search-engine-adapter.md` (pinned SDL, statuses and limits)

## Intent and context

When the server reports `searchEngineCapability.enabled`, the web client
does two things:

- its full-text ("grep") search uses `engineSearchNotes`;
- the Links tab of an open note shows a "Related notes" section.

When the capability is false, or cannot be read, nothing visible changes.

Patterns to imitate:

- **Client methods.** `web/src/notes/client.ts:searchNotes` (about line 806)
  and the private `queryValue`. A non-accepted result throws a
  `NoteTransportError` whose `resultStatus` carries the server status
  (`ensureAccepted`, about line 1002).
- **App state.** `web/src/state/appStore.tsx`: `AppState`, the initial
  `createStore` values (about line 180), and `loadSettings` (about line 225,
  invoked at about line 472).
- **Links tab.** `web/src/components/LinkedDocsTab.tsx`, for the generation
  counter, the loading and error states, and `app.openNote(noteId,
  notebookId)` navigation.
- **Testable component.** `web/src/components/TocTab.tsx` uses the
  `props.app ?? useApp()` pattern, and `TocTab.integration.tsx` builds a
  `testStore()` cast with `as unknown as AppStore`.
- **Client tests.** `web/src/notes/client.test.ts`, for the
  `environment(responses)` helper (bun:test).
- **Mount point.** `web/src/panes/RightPane.tsx`, the `links` `TabPanel`.

## Non-goals

- The agentic search path, `NoteSearchPopup` and the CLI stay untouched.
- No Tauri or Rust changes.
- No change to the server-credential rule code or its tests. Do not edit
  `client.test.ts`.

## writePaths

- `web/src/notes/types.ts`
- `web/src/notes/client.ts`
- `web/src/notes/searchEngineClient.test.ts`
- `web/src/state/appStore.tsx`
- `web/src/views/SearchView.tsx`
- `web/src/views/SearchView.integration.tsx`
- `web/src/components/RelatedNotesSection.tsx`
- `web/src/components/RelatedNotesSection.integration.tsx`
- `web/src/panes/RightPane.tsx`
- `impl-plans/completed/search-engine-adapter-p9-web-client.md`

New files: `web/src/notes/searchEngineClient.test.ts`, `web/src/views/SearchView.integration.tsx`, `web/src/components/RelatedNotesSection.tsx`, `web/src/components/RelatedNotesSection.integration.tsx`.

## sharedPaths (read-only)

- `web/src/components/LinkedDocsTab.tsx`
- `web/src/components/TocTab.tsx`
- `web/src/components/TocTab.integration.tsx`
- `web/src/notes/client.test.ts`
- `web/src/views/ChatbookView.integration.tsx`
- `web/package.json`

## sharedPathNotes

- `web/src/components/LinkedDocsTab.tsx`: read-only: generation counter, states
  and `openNote` navigation pattern.
- `web/src/components/TocTab.tsx`: read-only: `props.app ?? useApp()` pattern.
- `web/src/components/TocTab.integration.tsx`: read-only: `testStore` cast
  pattern.
- `web/src/notes/client.test.ts`: read-only: server-credential rule tests; must
  stay unchanged.
- `web/src/views/ChatbookView.integration.tsx`: read-only: `AppStoreProvider`
  plus mock client pattern.
- `web/package.json`: read-only: scripts only; do not change dependencies.

## File-level changes

### `types.ts`

Add `export interface EngineNoteHit { note: Note; snippet: string; score: number }`.

### `client.ts`

Add three methods next to `searchNotes`:

- `async searchEngineCapability(): Promise<boolean>`
  - Operation name `SearchEngineCapability`.
  - Selection: `searchEngineCapability { result { accepted status diagnostics } enabled }`.
  - Returns `enabled` when the result is accepted, and `false` otherwise.
  - Errors propagate. The store swallows them.
- `async engineSearchNotes(input: { query: string; notebookId?: NotebookId; tagFilter?: string[]; limit?: number; offset?: number }): Promise<EngineNoteHit[]>`
  - Operation name `EngineSearchNotes`.
  - Variables are only the provided fields, with `tagFilter` omitted when
    it is empty.
  - The value selection is
    `snippet score note { noteId notebookId noteNumber title bodyMarkdown readOnly createdAt updatedAt }`.
  - Uses `queryValue`.
- `async relatedNotes(noteId: NoteId, limit = 8): Promise<EngineNoteHit[]>`
  - Operation name `RelatedNotes`.
  - Same value selection, through `queryValue`.

### `appStore.tsx`

- Add `searchEngineEnabled: boolean` to `AppState`, with a doc comment. Its
  initial value is `false`.
- Add `loadSearchEngineCapability`. It sets
  `searchEngineEnabled = await client.searchEngineCapability()`; on any
  error it sets `false`.
- Call it exactly where `loadSettings()` is called (about line 472), so it
  reloads with the catalog after login or reconnect.

### `SearchView.tsx`

- In the `grep` branch:
  - When `app.state.searchEngineEnabled` is true, call
    `app.client.engineSearchNotes({ query, notebookId?, limit: 50 })`.
  - Map each hit to the existing row shape:
    `{ note, snippet, rank: score, matchedTags: [], isLinkedNeighbor: false, termCoverage: 1 }`.
  - If that call throws a `NoteTransportError` whose `resultStatus` is
    `search-engine-unavailable` or `feature-disabled`, run the existing
    `searchNotes` call. Then set a `notice` signal to exactly
    `Search engine unavailable; showing built-in results`. Render it as
    `<p class="chat-banner" role="status">` above the results.
  - Any other error keeps today's error path.
- When `searchEngineEnabled` is false, the code path is byte-for-byte
  today's: the same call and the same arguments.
- Reset `notice` on every new run.

### `RelatedNotesSection.tsx` (new)

- Signature:
  `export function RelatedNotesSection(props: { app?: AppStore } = {}): JSX.Element`.
- Use `const app = props.app ?? useApp()`.
- Render nothing (`<Show when={app.state.searchEngineEnabled && app.state.noteId}>`)
  unless enabled and a note is open.
- Fetch:
  - Load `app.client.relatedNotes(noteId, 8)` in a `createEffect` that is
    keyed on `noteId` and on the notebook revision, as `LinkedDocsTab`
    does.
  - Guard with a generation counter.
- Markup:
  - `<section class="link-group" aria-label="Related notes"><h3>Related notes</h3>`.
  - A loading line.
  - On error, `<p class="pane-empty">Related notes unavailable</p>`.
  - When empty, `<p class="pane-empty">No related notes</p>`.
  - Otherwise, the `link-list` `<ul>` of buttons. Each button shows
    `noteDisplayTitle(hit.note)` and calls
    `app.openNote(hit.note.noteId, hit.note.notebookId)`.
- Reuse the existing CSS classes. Add no new CSS file.

### `RightPane.tsx`

In the `links` `TabPanel`, the note-mode branch becomes
`<><LinkedDocsTab /><RelatedNotesSection /></>`. The fallback
`<NotebookLinksTab />` is unchanged, and nothing else changes.

## Pitfalls

- **Disabled is the default.** It must render exactly as today. Do not
  render an empty "Related notes" heading when disabled.
- **Unknown fields.** Older servers reject the unknown
  `searchEngineCapability` field with a GraphQL error. The store must catch
  it and treat it as disabled, never as a banner error.
- **Fallback scope.** Fall back only on the two pinned statuses, using
  `NoteTransportError.resultStatus`. Do not fall back on network errors:
  keep today's error UI for those.
- **Untouched tests.** Do not edit `client.test.ts`: it guards the
  server-credential rules. Put new client tests in
  `searchEngineClient.test.ts`.
- **Test placement.** Tests under `src/**/*.test.ts` run with bun. The
  `*.integration.tsx` files run with vitest and happy-dom. Follow the
  existing split.

## Tests

`searchEngineClient.test.ts` (bun:test; copy the small `environment()`
helper pattern):

- `engineSearchNotes({query:"q"})` sends a body whose query contains
  `engineSearchNotes(` with variables `{query:"q"}`, and no `tagFilter` or
  `notebookId`.
- A response with `accepted: false, status: "search-engine-unavailable"`
  rejects with a `NoteTransportError` whose `resultStatus` is
  `"search-engine-unavailable"`.
- `relatedNotes(id)` sends `limit: 8`.
- `searchEngineCapability()` returns true for an accepted response with
  `enabled: true`, and false for an accepted response with `enabled: false`.

`RelatedNotesSection.integration.tsx` (vitest; a test store as in
`TocTab.integration.tsx`):

- `searchEngineEnabled: false`: no element with
  `aria-label="Related notes"`, and `relatedNotes` is never called.
- Enabled with 2 hits: 2 buttons with the note titles. Clicking the first
  calls `openNote` with its noteId and notebookId.
- Enabled with `relatedNotes` rejecting: the text
  "Related notes unavailable".
- Enabled with `[]`: the text "No related notes".

`SearchView.integration.tsx` (vitest; mount `SearchView` inside an
`AppStoreProvider` with a mock client, following
`ChatbookView.integration.tsx`, and a router whose hash is a grep search
route; read `web/src/router.ts` for the hash format):

- Capability false: `searchNotes` is called and `engineSearchNotes` is not.
- Capability true: `engineSearchNotes` is called with `limit 50`, and the
  rows show its snippets.
- Capability true with `engineSearchNotes` rejecting a
  `NoteTransportError` whose `resultStatus` is `search-engine-unavailable`:
  `searchNotes` is called, and the status banner text equals
  `Search engine unavailable; showing built-in results`.

## Verification

```bash
bash -c 'mkdir -p tmp/search-engine-adapter/P9/session-264 && cd web && mise exec -- bun test src 2>&1 | tee ../tmp/search-engine-adapter/P9/session-264/bun-test.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P9/session-264 && cd web && mise exec -- bunx vitest run 2>&1 | tee ../tmp/search-engine-adapter/P9/session-264/vitest-run.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P9/session-264 && mise run web:check 2>&1 | tee tmp/search-engine-adapter/P9/session-264/web-check.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P9/session-264 && mise run tauri:check 2>&1 | tee tmp/search-engine-adapter/P9/session-264/tauri-check.log; echo exit=${PIPESTATUS[0]}'
grep -n "searchEngineEnabled" web/src/state/appStore.tsx web/src/views/SearchView.tsx web/src/components/RelatedNotesSection.tsx
grep -n "RelatedNotesSection" web/src/panes/RightPane.tsx
git diff --stat -- web/src/notes/client.test.ts
```

Expected evidence (gate-compatible form, amended in session-264):

- **Behavioral record 1.** `cd web && mise exec -- bun test src` exits 0. Record its pass count from the bun summary line, for example `177 pass`. It must be greater than 0.
- **Behavioral record 2.** `cd web && mise exec -- bunx vitest run` exits 0. Record its passed-test count, for example `87 passed`. It must be greater than 0.
- **Non-count records.** `mise run web:check` and `mise run tauri:check` exit 0. They are supporting evidence, because neither command name matches a test-runner pattern. Never use them as the only web evidence.
- The `client.test.ts` diff is empty.

## Done criteria

- [x] Client methods, state flag, SearchView engine path with fallback, and
      the Related notes section exist as specified.
- [x] The disabled path is unchanged. The new tests cover hidden and visible
      states and the fallback.
- [x] Separate current-source behavioral records pass: `mise exec -- bun test src`
      (177 passed) and `mise exec -- bunx vitest run` (87 passed); supporting
      `mise run web:check` and `mise run tauri:check` both exit 0.
- [x] `web/src/notes/client.test.ts` has no diff.

## Progress Log

- 2026-10-04: Plan created.
- 2026-10-04: Implemented engine capability/search client operations, capability
  state loading, capability-gated grep search with status-only fallback, and
  the Links-tab Related notes section. Added dedicated client and UI tests;
  `web/src/notes/client.test.ts` remains unchanged.
- 2026-10-04: Read-only P9 audit found capability stayed disabled after an
  initial unauthenticated read; capability now reloads after successful
  sign-in and reconnect, with an integration test for sign-in recovery.
- 2026-10-04: Final `mise run web:check` passed (177 bun tests and 87 vitest
  tests; typecheck, lint and production build passed); full log:
  `tmp/search-engine-adapter/P9/web-check-final3.log`. A generation guard
  prevents a stale fallback from updating the notice after a route change.
  Final `mise run tauri:check` passed; log:
  `tmp/search-engine-adapter/P9/tauri-check-final3.log`. Required symbol greps
  passed, the credential test diff is empty, and `git diff --check` passed.
  Earlier failed attempts and logs are retained as `web-check-attempt1.log`
  and `web-check-attempt2.log`.
- 2026-10-04: Step 6 resume reran the required checks against the current shared
  tree. `mise run web:check` passed (177 bun tests + 87 Vitest tests, 264 total;
  typecheck, lint and production build passed), log:
  `tmp/search-engine-adapter/P9/web-check-step6-resume2.log`.
  `mise run tauri:check` exited 0, log:
  `tmp/search-engine-adapter/P9/tauri-check-step6-resume.log`.
- 2026-10-04: Step 6 current-source rerun passed `mise run web:check` with
  177 bun tests and 87 Vitest tests (264 total), plus typecheck, lint and
  production build; complete log: `tmp/search-engine-adapter/P9/attempt-3/web-check.log`.
  `mise run tauri:check` passed; complete log:
  `tmp/search-engine-adapter/P9/attempt-3/tauri-check.log`. Required symbol
  checks and `git diff --check` passed; `web/src/notes/client.test.ts` has no
  diff.
- 2026-10-04: Step 6 attempt-4 current-source verification passed
  `mise run web:check` (177 bun tests + 87 Vitest tests, 264 total; typecheck,
  lint and production build passed), complete log:
  `tmp/search-engine-adapter/P9/attempt-4/web-check.log`. `mise run
  tauri:check` exited 0; complete log:
  `tmp/search-engine-adapter/P9/attempt-4/tauri-check.log`. Required symbol
  checks passed, `web/src/notes/client.test.ts` has no diff, and `git diff
  --check` passed.
- 2026-10-04: Step 6 final current-tree verification passed `mise run
  web:check` (177 bun tests + 87 Vitest tests, 264 total; typecheck, lint and
  production build passed), complete log:
  `tmp/search-engine-adapter/P9/step6-final/web-check.log`. `mise run
  tauri:check` exited 0; complete log:
  `tmp/search-engine-adapter/P9/step6-final/tauri-check.log`. Required symbol
  checks passed, `web/src/notes/client.test.ts` has no diff, and `git diff
  --check` passed. Formal review and serial integration remain downstream.
- 2026-10-04: Session-264 evidence-only rerun passed `cd web && mise exec --
  bun test src` (177 pass, 0 fail; exit 0) and `cd web && mise exec -- bunx
  vitest run` (87 passed across 20 files; exit 0), with separate complete logs
  under `tmp/search-engine-adapter/P9/session-264-rerun/`. `mise run web:check`
  (177 Bun + 87 Vitest tests, typecheck, lint, build) and `mise run
  tauri:check` also exited 0. The Vitest logs contain connection-refused
  diagnostics for optional local port 3000, while all assertions passed.
  Required capability/RelatedNotes symbol greps passed and the credential
  test diff is empty. The first Bun wrapper attempt is retained separately;
  the Bash rerun log records the explicit `exit=0` marker.
- 2026-10-04: Write-path reconciliation: the required `mise run web:check`
  production build wrote `web/dist/` outside this plan's empty `artifactRoots`;
  `.gitignore:33` ignores that output. Checks passed, but this output path
  requires checkpoint amendment before treating all assigned writes as
  authorized. The generated directory was left in place.
- 2026-10-04: Session-264 rerun-2: the separate Bun and Vitest behavioral
  commands passed (177 and 87; exit 0), and `mise run tauri:check` exited 0.
  A fresh `mise run web:check` was not run because its production build writes
  `web/dist/`, outside this plan's empty `artifactRoots`; checkpoint
  authorization for that generated output path is required. Logs are under
  `tmp/search-engine-adapter/P9/session-264-rerun-2/`.
- 2026-10-05: Review repair IR-W2-P9-ARTIFACT-POLICY-CONFIRMED completed as an
  evidence-only rerun. The committed dispatch manifest's `notes.artifactPolicy`
  explicitly authorizes build output under `web/dist/`; no checkpoint amendment
  is required. Fresh `cd web && mise exec -- bun test src` passed 177 tests,
  `cd web && mise exec -- bunx vitest run` passed 87 tests across 20 files,
  `mise run web:check` passed, and `mise run tauri:check` passed. All four
  complete logs end with `exit=0` under
  `tmp/search-engine-adapter/P9/session-264-rerun-3/`. Vitest emitted optional
  localhost:3000 connection-refused diagnostics; all assertions passed.
  `web/src/notes/client.test.ts` and all `web/` source files remain unchanged.
