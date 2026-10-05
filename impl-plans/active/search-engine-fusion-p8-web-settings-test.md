# P8 Web settings test for the Meilisearch descriptor

**Status**: Not Started
**planId**: P8-web-settings-test
**Wave**: 1
**dependsOn**: none (the test uses mocked GraphQL data)
**Design Reference**: `design-docs/specs/design-search-engine-fusion.md` F4 (web settings need no code change; one integration test case)
**Index**: `impl-plans/active/search-engine-fusion.md`

## Intent and context

The web settings form already builds its engine select from the server's
`adapters` list. It limits the auth-mode select to the chosen adapter's
`authModes` and shows the username only for `basic`. Add one integration
test that proves a Meilisearch descriptor (`none` and `apiKey` only)
renders correctly, then run the full web checks.

Repository facts:

- `web/src/components/SearchEngineSettings.tsx`:
  - line 132 sets the auth mode on a kind change;
  - line 144 builds the auth-mode options from the adapter's `authModes`;
  - line 149 shows the username only when `authMode === 'basic'`.
- `web/src/components/SearchEngineSettings.integration.tsx` has a settings
  fixture with `adapters: [{ kind: 'elasticsearch', ... }]` near lines
  9-11. Imitate its existing test structure and mocking.
- `web/src/notes/searchEngineSettings.ts:86` validates the auth mode
  against the adapter.
- `mise run web:check` runs `vite build`, which writes `web/dist`
  (gitignored), so `web/dist` is declared as an artifact root.

## Non-goals

- No change to `SearchEngineSettings.tsx`, `searchEngineSettings.ts`,
  `client.ts` or any other web source.
- If the test reveals a real UI defect, stop and record it in the progress
  log for P10. Do not widen the scope silently.

## writePaths

- `web/src/components/SearchEngineSettings.integration.tsx`
- `web/dist`
- `impl-plans/active/search-engine-fusion-p8-web-settings-test.md`
- `tmp/search-engine-fusion/P8`

## sharedPaths (read-only)

- `web/src/components/SearchEngineSettings.tsx`
- `web/src/notes/searchEngineSettings.ts`

## sharedPathNotes

- `web/src/components/SearchEngineSettings.integration.tsx`: intendedEdit: add one Meilisearch-descriptor test case; existing cases unchanged.
- `web/dist`: intendedEdit: generated `vite build` output from `mise run web:check` only.
- `web/src/components/SearchEngineSettings.tsx`: intendedEdit: read-only; no source change.
- `tmp/search-engine-fusion/P8`: intendedEdit: generated evidence logs only.

## artifactRoots

- `web/dist`
- `tmp/search-engine-fusion/P8`

## Test to add (one new test case, existing cases unchanged)

- Fixture: `adapters` contains Elasticsearch `[none, basic, apiKey]` and
  `{ kind: 'meilisearch', displayName: 'Meilisearch', authModes: ['none', 'apiKey'] }`.
  The user selects Meilisearch.
  - Expected: the auth-mode options are exactly `none` and `apiKey`, and
    there is no `basic` option.
  - Selecting `apiKey` shows a secret field and no username field.
  - Saving with URL `http://127.0.0.1:7700` and a secret sends
    `updateSearchEngineSettings` with `kind: 'meilisearch'` and
    `authMode: 'apiKey'`, and the input has no `username`.

## Verification

```bash
mkdir -p tmp/search-engine-fusion/P8
bash -c 'cd web && mise exec -- bun test src 2>&1 | tee ../tmp/search-engine-fusion/P8/bun-test.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'cd web && mise exec -- bunx vitest run 2>&1 | tee ../tmp/search-engine-fusion/P8/vitest.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run web:check 2>&1 | tee tmp/search-engine-fusion/P8/web-check.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
git diff --stat -- web/src
```

Expected evidence:

- `bun test src` shows `exit=0` with a pass count > 0 (record the
  `N pass` line).
- `vitest run` shows `exit=0` with `Tests N passed`, N > 0, and includes
  the new case. Record the two runs separately.
- `web:check` `exit=0`. This is not a behavioral count record.
- The diff stat lists only the integration test file.

## Done criteria

- [ ] The Meilisearch descriptor case is added and passes.
- [ ] bun and vitest counts are recorded separately. `web:check` passes.

## Progress Log

- 2026-10-05: Plan created.
