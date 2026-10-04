# P20 Web delta: search facets and filters, related-note reasons, Search engine settings section

**Status**: Ready
**planId**: P20-web-delta
**Wave**: 2
**dependsOn**: P9-web-client
**Design Reference**: `design-docs/specs/search-engine-adapter.md` D2 "Web search UI (SearchView)"; D3 "Web (RelatedNotesSection)"; D5 "Web settings section" and "Hot-swap" (Disable); the SDL pinned in P18
**Index**: `impl-plans/active/search-engine-adapter.md`

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
- `impl-plans/active/search-engine-adapter-p20-web-delta.md`

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
bash -c 'mkdir -p tmp/search-engine-adapter/P20 && cd web && mise exec -- bun test src 2>&1 | tee ../tmp/search-engine-adapter/P20/bun-test.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P20 && cd web && mise exec -- bunx vitest run 2>&1 | tee ../tmp/search-engine-adapter/P20/vitest-run.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P20 && mise run web:check 2>&1 | tee tmp/search-engine-adapter/P20/web-check.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P20 && mise run tauri:check 2>&1 | tee tmp/search-engine-adapter/P20/tauri-check.log; echo exit=${PIPESTATUS[0]}'
git diff --stat -- web/src/notes/client.test.ts web/src/notes/serverEndpoint.test.ts web/package.json
```

Expected evidence:

- `bun-test.log`: `exit=0` with a bun pass count greater than 0. Record the count.
- `vitest-run.log`: `exit=0` with a vitest passed-test count greater than 0. Record the count.
- `web:check` and `tauri:check`: `exit=0`. `tauri:check` needs macOS; elsewhere record `blocked: requires macOS`.
- `git diff --stat` prints nothing.

## Done criteria

- [ ] Facet chips and filters, the related reason line, and the settings section are implemented as specified.
- [ ] The secret is never persisted or displayed. Re-entry is required after a URL or auth-mode change.
- [ ] The server-credential tests are unchanged.
- [ ] `bun test` and `vitest run` show `exit=0` with positive counts, and `web:check` and `tauri:check` show `exit=0`.

## Progress Log

- 2026-10-04: Plan created (session-264).
