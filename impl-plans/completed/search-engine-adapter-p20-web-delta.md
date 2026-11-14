# P20 Web delta: search facets and filters, related-note reasons, Search engine settings section

**Status**: Completed. Accepted in session-264 (test-integrity, adversarial and integration review, comm-003910). The combined-tree wave-8 reconcile passed (`tmp/search-engine-adapter/reconcile/session-264-wave8/reconcile-summary.md`); the web records are wave-6 (bun 187, Vitest 97). Open low UI items: P20-LOW-CLEAR-SECRET-CHECKBOX-UX and P20-LOW-REFINEMENT-PERSISTENCE. Archived to `impl-plans/completed/` at Step 8 on 2026-10-05.
**planId**: P20-web-delta
**Wave**: 2
**dependsOn**: P9-web-client
**Design Reference**: `design-docs/specs/search-engine-adapter.md` D2 "Web search UI (SearchView)"; D3 "Web (RelatedNotesSection)"; D5 "Web settings section" and "Hot-swap" (Disable); the SDL pinned in P18
**Index**: `impl-plans/completed/search-engine-adapter.md`

## Intent and context

The web client (`web/`, SolidJS, shared with the Tauri shell) gains three things:

1. **Refinement in `SearchView`.** On the engine path, the client requests facets. It shows class and tag chips with counts, and active filters as removable chips.
2. **Reasons in `RelatedNotesSection`.** A plain-text reason line appears under each related note.
3. **A Search engine settings section** in `ConfigView`, for administrators. It covers picking the engine, connection fields, a write-only secret, Test connection and Save.

The tests use mocks, so this plan builds against the GraphQL SDL pinned in P18 and runs in wave 2.

Repository facts:

- **Client.** `web/src/notes/client.ts` (1092 lines; the 1000-line rule applies to Swift only):
  - `searchEngineCapability()` (840), `engineSearchNotes(input)` (852) and `relatedNotes(noteId, limit)` (877);
  - errors carry `resultStatus` through `NoteClientError` (line 53);
  - `userAgentCredential` and `setUserAgentCredential` (around 570-600) show the write-only credential call pattern.
- **Types.** `web/src/notes/types.ts`: `EngineNoteHit { note, snippet, score }` (223).
- **App store.** `web/src/state/appStore.tsx`: `searchEngineEnabled` in state, and `loadSearchEngineCapability` (236).
- **Search view.** `web/src/views/SearchView.tsx` (174 lines): a generation counter, `setStatus`, and the engine path with fallback, with the status `Search engine unavailable; showing built-in results`.
- **Related notes.** `web/src/components/RelatedNotesSection.tsx` (68 lines).
- **Settings screen.** `web/src/views/ConfigView.tsx` renders `<ServerConnectionSettings />` and `<UserAgentSettings />`. Imitate `web/src/components/UserAgentSettings.tsx` and its integration test for a write-only credential form.
- **Styles.** Reuse the existing chip classes `.detail-chips` and `.folder-chip` (`web/src/styles.css`). No CSS edits.
- **Server-credential rule tests.** `web/src/notes/serverEndpoint.test.ts`, `web/src/notes/client.test.ts` and `web/src/state/appStore.test.ts` must pass unchanged.

## Non-goals

- No change to `NoteSearchPopup`, the agentic search method, server-credential handling, Tauri Rust code or CSS files.
- No new dependency. Do not touch `web/package.json` or the lockfile.

## writePaths

- `web/src/notes/types.ts`
- `web/src/notes/client.ts`
- `web/src/notes/searchEngineClient.test.ts`
- `web/src/notes/searchEngineSettings.ts` (new)
- `web/src/notes/searchEngineSettings.test.ts` (new)
- `web/src/state/appStore.tsx`
- `web/src/views/SearchView.tsx`
- `web/src/views/SearchView.integration.tsx`
- `web/src/components/RelatedNotesSection.tsx`
- `web/src/components/RelatedNotesSection.integration.tsx`
- `web/src/components/SearchEngineSettings.tsx` (new)
- `web/src/components/SearchEngineSettings.integration.tsx` (new)
- `web/src/views/ConfigView.tsx`
- `impl-plans/completed/search-engine-adapter-p20-web-delta.md`

## sharedPaths (read-only)

- `web/src/components/UserAgentSettings.tsx`: read-only. The write-only credential form pattern.
- `web/src/components/UserAgentSettings.integration.tsx`: read-only. The integration-test pattern.
- `web/src/notes/client.test.ts`: read-only. The server-credential rule tests; they must stay unchanged.
- `web/src/notes/serverEndpoint.test.ts`: read-only. Server-credential rule tests; they must stay unchanged.
- `web/src/styles.css`: read-only. The existing `.detail-chips` and `.folder-chip` classes.
- `web/package.json`: read-only. Scripts; no dependency changes.

## File-level changes

### `types.ts`

- `EngineNoteHit` gains `reasons: EngineHitReason[]`.
- `EngineHitReason { kind: string; tags: string[] }`
- `EngineSearchFacets { tagClasses: { value: string; count: number }[]; tags: { tagId: string; name: string; tagClass: string | null; count: number }[] }`
- `EngineSearchPage { hits: EngineNoteHit[]; facets: EngineSearchFacets | null }`
- `SearchEngineSettings`, `SearchEngineAdapterDescriptor`, `SearchEngineSettingsInput` and `SearchEngineConnectionTestResult` mirror the P18 SDL. `SearchEngineSettings` has no secret field.

### `client.ts`

- **`engineSearchNotes(input)`.** The input gains optional `tagClassFilter`, `expandOntology` and `facets`. The query selects `reasons { kind tags }` and `facets { tagClasses { value count } tags { tagId name tagClass count } }`. It returns `EngineSearchPage`.
  - Update the existing callers.
  - Read `facets` from the payload alongside `value`. Imitate `queryValue` but keep facets. Add a small private helper if needed.
- **`relatedNotes`.** It selects `reasons`.
- **`searchEngineSettings()`.** It returns `SearchEngineSettings | null`, which is null when the result is not accepted, for example for non-admins and older servers.
- **`updateSearchEngineSettings(input)`.** It returns `SearchEngineSettings`, and throws `NoteClientError` with `resultStatus` when not accepted.
- **`testSearchEngineConnection(input)`.** It returns `SearchEngineConnectionTestResult`.
- **Secret handling.** The input `secret` is sent only in the mutation variables. It is never cached, stored or logged.

### `appStore.tsx`

Expose `reloadSearchEngineCapability()`. It reuses `loadSearchEngineCapability`, and the settings section calls it after a successful Save.

### `searchEngineSettings.ts` (new; pure)

`validateSearchEngineForm(form, loaded)` returns `{ field: string; message: string }[]`.

- **Kind.** When the kind is not `none`, the URL is required.
- **URL.**
  - The scheme is `http` or `https`.
  - Plain `http` is allowed only for the hosts `localhost`, `127.0.0.1` and `::1`.
  - No userinfo.
- **Prefix.** It matches `^[a-z0-9][a-z0-9_-]{0,63}$`.
- **Timeout.** An integer in 1-120.
- **Username.** Required for basic.
- **Secret.** Required when the auth mode is not `none` and any of these holds:
  - `!loaded.hasSecret`;
  - the normalized URL differs from `loaded.url`;
  - the auth mode differs from `loaded.authMode`.

  This mirrors the server's target binding. Normalization is the same as the server's `normalizedTarget`: lowercase scheme and host, keep the port, and strip the trailing `/`.
- **`verifyTLS: false`** only with `https`.

`normalizedTarget(url)` is exported for tests.

### `SearchEngineSettings.tsx` (new)

- **Load.** On mount, call `client.searchEngineSettings()`. When the result is null, render nothing.
- **Config-managed.** When `managedBy === 'config'`, render the values read-only, with the text `Managed by the server configuration file`, and no buttons.
- **Fields.**
  - Engine select: `None` plus `adapters[].displayName`.
  - URL, Index prefix.
  - Auth mode select, limited to the selected adapter's `authModes`.
  - Username, shown only for basic.
  - Secret: `type="password"`, `autocomplete="new-password"`. Its placeholder is `Stored` only while `hasSecret` is set and neither the URL nor the auth mode changed. Otherwise there is no placeholder, and the field is required.
  - `Clear stored secret` checkbox.
  - `Verify TLS certificates` checkbox, disabled for http. When unchecked, show the warning text `Certificate verification is off; use only on a trusted network`.
  - Request timeout (seconds).
- **Buttons.** `Test connection` and `Save` are disabled while there are validation errors.
  - Test shows `status` and `detail` as plain text.
  - Save calls update. On success it clears the secret input, applies the returned settings, and calls `app.reloadSearchEngineCapability()`.
  - On `invalid-settings`, show the field from the diagnostics.

### `ConfigView.tsx`

Render `<SearchEngineSettings />` after `<UserAgentSettings />`.

### `SearchView.tsx`

- **Engine path.** Request `facets: true` on the first page, plus the active `tagFilter` and `tagClassFilter`.
- **Chips.** Under the status line, render the class chips (`<value> <count>`) and tag chips (`<name> <count>`) using `.detail-chips` and `.folder-chip`.
  - Clicking a class adds `value` to `tagClassFilter`. Clicking a tag adds its `name` to `tagFilter`.
  - Active filters render as removable chips, with a `x` button whose `aria-label` is `Remove filter <label>`.
  - Each change re-runs the search with a new generation.
- **Fallback.** The existing fallback passes `tagFilter` to `searchNotes` and clears `tagClassFilter`.
- **`feature-disabled`** additionally sets `app.state.searchEngineEnabled` to false, through a store setter. Add `setSearchEngineEnabled` to the store API if needed.

### `RelatedNotesSection.tsx`

Under each title, render one plain-text line from the reasons, in this order and joined with ` · `:

- `Linked` (`linked`)
- `Shared tags: a, b` (`shared-tag` tags)
- `Same person/event: x` (`shared-entity` tags)
- `Related tags` (`related-tag`)
- `Similar text` (`text-similarity`)

Omit the line when there are no reasons. On a `feature-disabled` error, set `searchEngineEnabled` to false, which hides the section, instead of showing `Related notes unavailable`.

## Pitfalls

- **No secret persistence.** Never put the secret into the `web` settings document, `localStorage`, `sessionStorage`, signals that outlive the form, or `console.*`.
- **Plain text only.** Reasons and test details render as text, never as HTML.
- **Server-credential tests are unchanged.** Run `git diff --stat` on them; it must be empty.
- **Stale responses.** Keep the generation-counter discipline on every new request path.
- **Compatibility.** An older server rejects the new fields. Treat a GraphQL validation error on `engineSearchNotes` the same as `search-engine-unavailable`, so the existing fallback applies.

## Tests

**`searchEngineSettings.test.ts` (bun):**

- An http non-loopback URL -> error.
- A bad prefix -> error.
- A timeout of 0 -> error.
- Basic auth without a username -> error.
- `hasSecret`, the URL unchanged, and no secret -> no secret error. URL changed -> secret required. Auth mode changed -> secret required.
- `verifyTLS: false` with http -> error.
- `normalizedTarget('HTTP://LocalHost:9200/') === 'http://localhost:9200'`.

**`SearchEngineSettings.integration.tsx` (vitest):**

- Settings query returns null -> nothing rendered.
- `managedBy: config` -> read-only text, and no Save button.
- Invalid URL -> Save disabled.
- Test connection -> the status and detail text are shown.
- Save -> the mutation is called with the secret, the secret input is cleared afterwards, and `reloadSearchEngineCapability` is called. `localStorage` and `sessionStorage` do not contain the secret string.
- With `hasSecret` loaded, changing the URL without entering a secret -> Save and Test are disabled, and the secret field is marked required.

**`SearchView.integration.tsx` (extend):**

- Engine enabled with facets returned -> chips shown. Clicking a tag chip re-requests with `tagFilter: [name]`. Removing it re-requests without it.
- `feature-disabled` -> falls back and sets `searchEngineEnabled` to false.

**`RelatedNotesSection.integration.tsx` (extend):**

- Reasons `[linked, shared-tag(tags: ['A', 'B']), text-similarity]` -> the line reads `Linked · Shared tags: A, B · Similar text`.
- No reasons -> no line.
- `feature-disabled` -> the section hidden.

**`searchEngineClient.test.ts` (extend):** the operation documents and variables for the new client calls, including that `secret` is omitted when undefined.

## Verification

```bash
bash -c 'cd web && mise exec -- bun test src > ../tmp/search-engine-adapter/P20/attempt-10/bun-test.log 2>&1; echo exit=$? >> ../tmp/search-engine-adapter/P20/attempt-10/bun-test.log'
bash -c 'cd web && mise exec -- bunx vitest run > ../tmp/search-engine-adapter/P20/attempt-10/vitest-run.log 2>&1; echo exit=$? >> ../tmp/search-engine-adapter/P20/attempt-10/vitest-run.log'
```

Behavioral verification (attempt 10):

- `tmp/search-engine-adapter/P20/attempt-10/bun-test.log`: 187 passed, `exit=0`.
- `tmp/search-engine-adapter/P20/attempt-10/vitest-run.log`: 97 passed, `exit=0`.

Supporting checks (not additional behavioral records): `mise run web:check` and `mise run tauri:check` both exit 0; complete logs are `tmp/search-engine-adapter/P20/attempt-10/web-check.log` and `tmp/search-engine-adapter/P20/attempt-10/tauri-check.log`. `shasum -a 256 -c tmp/search-engine-adapter/P20/source-final.sha256` reports 13/13 OK, and `git diff --stat -- web/src/notes/client.test.ts web/src/notes/serverEndpoint.test.ts web/src/lib/serverEndpoint.test.ts web/package.json` is empty.

### Negative control (non-behavioral)

`tmp/search-engine-adapter/P20/attempt-9/mutation-check.log` is an expected-failure mutation check, not product behavioral verification. It exits 1 because the strengthened storage assertion detects a simulated secret persisted under an ordinary draft key. The temporary mutation was removed before final-source verification.

## Done criteria

- [x] Facet chips and filters, the related reason line, and the settings section are implemented as specified.
- [x] The secret is never persisted or displayed. Re-entry is required after a URL or auth-mode change.
- [x] The server-credential tests are unchanged.
- [x] `bun test` and `vitest run` show `exit=0` with positive counts, and `web:check` and `tauri:check` show `exit=0`.

## Progress Log

- 2026-10-04: Plan created (session-264).
- 2026-10-05: Implemented P20 in `web/src/notes/`: engine search returns hit reasons and optional facets, sends tag/class filters plus ontology/facet options, and provides typed settings read/update/test operations. Added pure settings validation with server-equivalent target normalization and write-only secret re-entry rules. `SearchView` renders counted class/tag chips and removable filters, requests facets, preserves tag filters and clears class filters on FTS fallback, and disables engine capability on `feature-disabled`. `RelatedNotesSection` renders ordered plain-text reasons and hides itself after `feature-disabled`. Added the settings form after UserAgentSettings in ConfigView; it is hidden for unaccepted settings, read-only for config-managed settings, tests connections as text, clears the secret after Save and reloads capability.
- 2026-10-05: Validation mirrors the D5 bounds for URL, username and secret lengths and rejects control characters without suppressing ESLint rules.
- 2026-10-05: Verification on the final source: separate `bun test src` 187/187 (attempt-7/bun-test.log), separate Vitest 95/95 (attempt-7/vitest-run.log), `mise run web:check` exit=0 including typecheck, Bun, Vitest, lint and Vite build (attempt-7/web-check.log), and `mise run tauri:check` exit=0 on macOS (attempt-7/tauri-check.log). `git diff --stat` is empty for `web/src/notes/client.test.ts`, `web/src/notes/serverEndpoint.test.ts` and `web/package.json`; `git diff --check -- web/src` is clean.
- 2026-10-05: Historical attempts are retained but superseded: attempt-1 was interrupted while diagnosing repeated fallback updates (exit=130); attempt-2 exposed a Vitest localStorage mock issue and attempt-3 uncovered settings-page test doubles without the P18 method. Attempt-5 found a strict TypeScript tuple-inference error in parity validation (exit=2); attempt-6 then found the repository's no-control-regex ESLint rule (exit=1). The fallback loop, isolated storage tests, missing-method compatibility and validation typing/lint were corrected. Final attempt-8 is green.
- 2026-10-05: The per-file post-edit SHA-256 inventory for all 13 P20 web source/test files is recorded at `tmp/search-engine-adapter/P20/source-final.sha256`; the pre-attempt-10 plan SHA-256 is recorded at `tmp/search-engine-adapter/P20/plan-after.sha256`, and the post-attempt-10 plan SHA-256 is recorded at `tmp/search-engine-adapter/P20/attempt-10/plan.sha256`.
- 2026-10-05: The final GraphQL server fields/types and combined-tree integration checks are assigned to P18/P21; P20 uses the P18 pinned SDL and mocked client contract as scoped.
- 2026-10-05: Removed redundant direct searches from facet/filter click handlers; tracked filters now trigger one existing generation-guarded request. Final attempt-8 verification on this source is Bun 187/187, Vitest 95/95, web:check exit=0, tauri:check exit=0; complete logs are under `tmp/search-engine-adapter/P20/attempt-8/`.
- 2026-10-05: Resolved test-integrity findings P20-TI-SEARCHVIEW-FALLBACK-DISABLE-UNASSERTED and P20-TI-STORAGE-ASSERTION-VACUOUS. SearchView integration now captures the store and asserts feature-disabled turns capability off and hides refinement chips; active Ada/person fallback retains Ada, omits class filters, removes only the class chip, shows the fallback notice, and remains stable across another settle. Settings integration scans all local/session storage keys and values plus rendered DOM for the secret. A test-only ordinary-key draft mutation failed the strengthened assertion as expected (attempt-9/mutation-check.log, exit=1); the temporary line was removed and the test source hash restored.
- 2026-10-05: The first attempt-9 and attempt-9-rerun web:check logs exposed test-only TypeScript mock-signature errors (exit=2); both were fixed in SearchView.integration.tsx. Those logs are retained as failed history. Final stable-source verification is in `tmp/search-engine-adapter/P20/attempt-9-final/`: Bun 187/187, Vitest 97/97, web:check (typecheck, tests, lint, Vite build) and tauri:check all exit=0. The credential-test/server-endpoint/package guard diff is empty.
- 2026-10-05: Regenerated `tmp/search-engine-adapter/P20/source-final.sha256` for the same 13 web source/test files. The final plan hash is recorded at `tmp/search-engine-adapter/P20/plan-after.sha256`. Independent test-integrity and adversarial re-review remain downstream workflow steps.
- 2026-10-05: Re-recorded final evidence in `tmp/search-engine-adapter/P20/attempt-10/` on the unchanged 13-file source identity: separate Bun 187/187 and Vitest 97/97 behavioral runs exit 0; web:check and tauri:check are supporting checks and exit 0. The guard-file diff is empty. The attempt-9 persistence mutation remains only a non-behavioral negative control (expected exit 1), not a behavioral record. Independent step6 test-integrity and step7 adversarial re-review of P20-TI-SEARCHVIEW-FALLBACK-DISABLE-UNASSERTED and P20-TI-STORAGE-ASSERTION-VACUOUS remain pending.
