# P8 Web settings test for the Meilisearch descriptor

**Status**: Completed. Accepted in session-268 (test-integrity, adversarial and combined-tree integration review, comm-004081). The P10 combined-tree gates passed (`impl-plans/completed/search-engine-fusion.md`, "Final integration evidence"). Archived to `impl-plans/completed/` at Step 8 on 2026-10-05.
**planId**: P8-web-settings-test
**Wave**: 1
**dependsOn**: none (the test uses mocked GraphQL data)
**Design Reference**: `design-docs/specs/design-search-engine-fusion.md` F4 (web settings need no code change; one integration test case)
**Index**: `impl-plans/completed/search-engine-fusion.md`

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
- `impl-plans/completed/search-engine-fusion-p8-web-settings-test.md`
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

- [x] The Meilisearch descriptor case is added and passes.
- [x] bun and vitest counts are recorded separately. `web:check` passes.

## Progress Log

- 2026-10-05: Plan created.
- 2026-10-05: Added the Meilisearch descriptor integration case. It confirms the auth options are exactly `none` and `apiKey`, selecting `apiKey` shows a password secret field without a username field, and the save input uses `kind: meilisearch` / `authMode: apiKey` with no `username` property. No UI defect was found; no P10 issue was needed.
- 2026-10-05: Final-source verification after adding the exact loopback URL assertion passed: `mise exec -- bun test src` (187 pass; `tmp/search-engine-fusion/P8/attempt-4/bun-test.log`), `mise exec -- bunx vitest run` (98 passed; `tmp/search-engine-fusion/P8/attempt-4/vitest.log`), and `mise run web:check` (typecheck, tests, lint, and build; exit 0; `tmp/search-engine-fusion/P8/attempt-4/web-check.log`). `git diff --stat -- web/src` listed only `SearchEngineSettings.integration.tsx`.
- 2026-10-05: The previous source version also passed all three checks in attempt 3; it did not yet assert the required loopback URL. Failed earlier `web:check` logs are preserved at `web-check.log` and `attempt-2/web-check.log`; the two test-only TypeScript assertion issues were fixed before final verification. Vitest logs emit existing ECONNREFUSED localhost:3000 messages while all tests pass.
