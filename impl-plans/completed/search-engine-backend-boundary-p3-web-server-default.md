# P3 Web: server-default URL hint, no engine coordinates in web/src

**Status**: Completed. Accepted in session-272 (test-integrity comm-004170, adversarial review comm-004171, combined-tree integration review comm-004176). The P5 combined-tree gates passed (`impl-plans/completed/search-engine-backend-boundary.md`, "Final integration evidence"). Archived to `impl-plans/completed/` at Step 8 on 2026-10-05.
**planId**: P3-web-server-default
**Wave**: 1
**dependsOn**: none (tests use mocked GraphQL data; the server contract is pinned in the design)
**Design Reference**: `design-docs/specs/search-engine-adapter.md` B6 (web client), B4 (read `url` is explicit or null), B1 row A4, B7 (web tests), B verification guards
**Index**: `impl-plans/completed/search-engine-backend-boundary.md`

## Intent and context

The web settings form currently prefills the engine URL from the
server-sent `defaultURL` (`web/src/notes/searchEngineSettings.ts:25`
`defaultEngineURL`, used at `web/src/components/SearchEngineSettings.tsx:133`).
Clients must never need engine coordinates. After this plan:

- `defaultURL` is gone from the web types and GraphQL documents.
- The URL field is optional. Empty means "server default". The input shows
  `placeholder="Server default"`, and a note under it reads exactly:
  `Leave empty to use the server default. Only the Kaiba server connects to the search engine.`
- An administrator can still type an explicit URL; it is validated as
  today.
- The read-only config view shows `Server default` when `kind` is not
  `none` and `url` is `null`.
- No file under `web/src` (tests included) contains the engine port,
  `defaultURL` or `KAIBA_MEILISEARCH_URL`. A bun guard test enforces it.

Server contract this plan relies on (implemented by P1/P2, mocked here):
the settings read returns `url: null` for the server default; an input
without `url` means server default; descriptors are
`{kind, displayName, authModes}`.

Repository facts:

- `web/src/notes/types.ts:246-251` `SearchEngineAdapterDescriptor` has `defaultURL?: string | null`.
- `web/src/notes/client.ts:910` and `:925` select `adapters { kind displayName authModes defaultURL }`.
- `web/src/notes/searchEngineSettings.ts`: `defaultEngineURL` (lines 20-28); `validateSearchEngineForm` adds `URL is required.` when `kind !== 'none'` and the URL is blank; `searchEngineSettingsInput` already omits `url` when the field is blank.
- `web/src/components/SearchEngineSettings.tsx`: the engine `select` `onChange` calls `defaultEngineURL`; the URL `<input type="url">` has no placeholder; the config `<dd>` shows `value().url ?? '—'`.
- Tests: `web/src/notes/searchEngineSettings.test.ts` (bun, `describe('defaultEngineURL')` at line 62 uses the engine port); `web/src/components/SearchEngineSettings.integration.tsx` (vitest; the prefill test near line 78 and the Meilisearch test near lines 150-185 use the engine port).
- `bun test src` runs `*.test.ts`; vitest runs `src/**/*.integration.tsx` (`web/vitest.config.ts`).

## Non-goals

- No change to secret re-entry logic (`secretRequired`,
  `storedSecretMatches`, the validation rule comparing
  `normalizedTarget(form.url)` with `normalizedTarget(loaded.url ?? '')`):
  empty and `null` already compare equal.
- No change to `web/src-tauri` (CSP and capabilities stay, design A11).
- No new GraphQL fields (no `usesServerDefault`).
- No styling or layout work beyond the placeholder, the note and the
  read-only text.

## writePaths

- `web/src/notes/types.ts`
- `web/src/notes/client.ts`
- `web/src/notes/searchEngineSettings.ts`
- `web/src/notes/searchEngineSettings.test.ts`
- `web/src/notes/engineBoundary.test.ts`
- `web/src/components/SearchEngineSettings.tsx`
- `web/src/components/SearchEngineSettings.integration.tsx`
- `web/dist`
- `web/src-tauri/target`
- `impl-plans/completed/search-engine-backend-boundary-p3-web-server-default.md`
- `tmp/search-engine-backend-boundary/P3`

## sharedPaths (read-only)

- `web/src/notes/searchEngineClient.test.ts`
- `web/vitest.config.ts`
- `web/package.json`

## sharedPathNotes

- `web/src/notes/searchEngineClient.test.ts`: intendedEdit: read-only; must keep passing unchanged.
- `web/dist`: intendedEdit: generated `vite build` output from `mise run web:check` only (gitignored).
- `web/src-tauri/target`: intendedEdit: generated cargo output from `mise run tauri:check` only (gitignored); never edited by hand.
- `tmp/search-engine-backend-boundary/P3`: intendedEdit: evidence logs, hashes.txt and intent.md only.

## artifactRoots

- `web/dist`
- `web/src-tauri/target`
- `tmp/search-engine-backend-boundary/P3`

## File-level changes

1. `types.ts`: remove `defaultURL` and its comment from
   `SearchEngineAdapterDescriptor`. Add a short comment on
   `SearchEngineSettings.url`: `null` with a non-`none` kind means the
   server default.
2. `client.ts`: both settings documents select
   `adapters { kind displayName authModes }`.
3. `searchEngineSettings.ts`:
   - Delete `defaultEngineURL` and its doc comment; drop the
     `SearchEngineAdapterDescriptor` import if it becomes unused.
   - `validateSearchEngineForm`: a blank (trimmed-empty) URL produces no
     `searchEngine.url` error. A non-blank URL keeps every current rule
     (length, `normalizedTarget`, plain http only on loopback). Keep the
     control-character, secret and `verifyTLS` rules unchanged; the
     `verifyTLS: false` rule still errors when the URL is blank.
   - `searchEngineSettingsInput`: unchanged (it already omits a blank
     `url`).
4. `SearchEngineSettings.tsx`:
   - Remove the `defaultEngineURL` import. The engine select `onChange`
     updates only `kind` and `authMode`; it never sets `url`.
   - URL input: add `placeholder="Server default"`. Below the URL label,
     inside the same `Show` for non-`none` kinds, render
     `<p class="pane-note">` with the exact note text above.
   - Config view `<dd>` for URL: the URL when present; `Server default`
     when `url` is `null` and `kind !== 'none'`; `—` otherwise.
5. `engineBoundary.test.ts` (new, bun): recursively read every file under
   `web/src` (resolve the directory from `import.meta.dir`; use
   `node:fs`/`node:path`), and fail listing `path:line` for any file whose
   text contains one of three needles. **The guard's own source must not
   contain any needle literally**, or `grep -rn` guards would match it.
   Build them at run time, e.g. `String(77 * 100)`,
   `['default', 'URL'].join('')`, `['KAIBA', 'MEILISEARCH', 'URL'].join('_')`.
   Do not exclude any file, including the guard itself.

## Pitfalls

- Do not keep any engine-port literal in fixtures: replace explicit URLs
  in tests with `https://search.example` (or the existing
  `https://search.example.com:8080` / `http://localhost:8080`, which
  contain no engine port).
- Do not leave the old prefill test; replace it.
- Changing the engine select must not clear or alter a URL the admin
  already typed.
- Do not log or store the secret (existing storage-scan tests must keep
  passing).

## Tests (input or situation -> expected outcome)

`searchEngineSettings.test.ts` (bun):

- Remove `describe('defaultEngineURL')` and the `defaultEngineURL` import.
- `form({ kind: 'meilisearch', url: '', authMode: 'none' })` -> no `searchEngine.url` error.
- `form({ url: '   ', authMode: 'none' })` -> no `searchEngine.url` error.
- `form({ url: 'http://example.com:8080' })` -> still contains `searchEngine.url`.
- `form({ url: '', verifyTLS: false })` -> contains `searchEngine.verifyTLS`.
- loaded `{ url: null, hasSecret: true, authMode: 'apiKey' }`, form `{ url: '', authMode: 'apiKey', secret: '' }` -> no `searchEngine.secret` error.
- `searchEngineSettingsInput(form({ url: '' }))` and `form({ url: '  ' })` -> no `url` property.

`SearchEngineSettings.integration.tsx` (vitest):

- Replace the prefill test: settings `{ kind: 'none', url: null, adapters: [{ kind: 'meilisearch', displayName: 'Meilisearch', authModes: ['none', 'apiKey'] }] }`; select `meilisearch` -> the URL input value is `''`, its `placeholder` is `Server default`, and the host text contains the exact note; Save -> `updateSearchEngineSettings` is called with an input that has no `url` property and `kind: 'meilisearch'`, `authMode: 'none'`.
- Existing Meilisearch auth-mode test: type `https://search.example` instead of the engine-port URL -> the saved input has `url: 'https://search.example'`.
- Config-managed `{ managedBy: 'config', kind: 'meilisearch', url: null }` -> text contains `Server default` and there is no button.
- All other existing cases pass unchanged.

`engineBoundary.test.ts` (bun):

- Scan of `web/src` -> zero offending files.
- Sanity: the scanned file list is non-empty and includes `notes/client.ts` (so a wrong root fails loudly).

## Verification

```bash
mkdir -p tmp/search-engine-backend-boundary/P3
bash -c 'cd web && mise exec -- bun test src 2>&1 | tee ../tmp/search-engine-backend-boundary/P3/bun-test.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'cd web && mise exec -- bunx vitest run 2>&1 | tee ../tmp/search-engine-backend-boundary/P3/vitest.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run web:check 2>&1 | tee tmp/search-engine-backend-boundary/P3/web-check.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run tauri:check 2>&1 | tee tmp/search-engine-backend-boundary/P3/tauri-check.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'grep -rn "7700" web/src | tee tmp/search-engine-backend-boundary/P3/guard-port.log; test ! -s tmp/search-engine-backend-boundary/P3/guard-port.log'
bash -c 'grep -rn "defaultURL" web/src | tee tmp/search-engine-backend-boundary/P3/guard-defaulturl.log; test ! -s tmp/search-engine-backend-boundary/P3/guard-defaulturl.log'
bash -c 'grep -rn "KAIBA_MEILISEARCH_URL" web/src | tee tmp/search-engine-backend-boundary/P3/guard-env.log; test ! -s tmp/search-engine-backend-boundary/P3/guard-env.log'
```

Expected evidence:

- `bun test src` exit 0 with `N pass` and `0 fail`, N > 0 (record N; it
  includes the new guard and validation cases).
- `vitest run` exit 0 with `Tests M passed`, M > 0 (record M).
- `web:check` exit 0 (not a behavioral record; it writes `web/dist`).
- `tauri:check` exit 0 on macOS; if it is unavailable, record
  `blocked: <exact error>`, never passed. P5 reruns it.
- The three grep guards exit 0 with empty logs.

## Done criteria

- [x] `grep -rn '7700' web/src`, `grep -rn 'defaultURL' web/src` and `grep -rn 'KAIBA_MEILISEARCH_URL' web/src` are all empty.
- [x] `defaultEngineURL` no longer exists; the select no longer sets the URL.
- [x] The placeholder, the note and the config-view `Server default` text exist and are tested.
- [x] bun and vitest counts recorded separately with exit 0.
- [x] Progress Log updated with commands, exit codes, counts and log paths.

## Progress Log

- 2026-10-05: Plan created.
- 2026-10-05: Implemented the B6 web contract. Removed adapter URL data and
  prefill, made blank URL validation server-default aware, added the input
  hint/config display, and replaced engine-coordinate fixtures. The Bun
  boundary test scans every file under `web/src` using runtime-built needles.
- 2026-10-05 verification (all logs under
  `tmp/search-engine-backend-boundary/P3/`):
  - `cd web && mise exec -- bun test src`: exit 0, 190 pass, 0 fail;
    `bun-test.log`.
  - `cd web && mise exec -- bunx vitest run`: exit 0, 100 passed, 0 failed;
    `vitest.log`.
  - `mise run web:check`: exit 0 (typecheck, test, lint, build);
    `web-check.log`.
  - `mise run tauri:check`: exit 0; `tauri-check.log`.
  - `grep -rn "7700" web/src`, `grep -rn "defaultURL" web/src`, and
    `grep -rn "KAIBA_MEILISEARCH_URL" web/src`: each exit 0 with empty
    output; `guard-port.log`, `guard-defaulturl.log`, `guard-env.log`.
- 2026-10-05: P3 implementation complete. Formal review and P5 integration
  remain downstream workflow steps.
