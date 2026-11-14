# P4 README: server-default URL in Settings

**Status**: Completed. Accepted in session-272 (test-integrity comm-004170, adversarial review comm-004171, combined-tree integration review comm-004176). Step 8 re-checked the README "Optional search engine" section against the shipped behavior; no further edit was needed. Archived to `impl-plans/completed/` at Step 8 on 2026-10-05.
**planId**: P4-readme
**Wave**: 1
**dependsOn**: none
**Design Reference**: `design-docs/specs/search-engine-adapter.md` B8 ("For the implementation"), B2 (network position), B3 (env change, secret re-entry), B1 row A13
**Index**: `impl-plans/completed/search-engine-backend-boundary.md`

## Intent and context

The README "Optional search engine" section already says that only the
Kaiba backend reaches the engine and that Elasticsearch was removed
(`README.md` lines ~188-196). It explains that an omitted config `url`
resolves from `KAIBA_MEILISEARCH_URL` and then `http://127.0.0.1:7700`
(lines ~210-211). It does not say that the **Settings** URL can be left
empty, that empty also counts as omitted, where "loopback" is evaluated,
or what an environment change does. Add only those facts.

## Non-goals

- No other README edits. Do not rewrite the engine, compose, CLI or
  ontology paragraphs, and do not touch the existing `127.0.0.1:7700`
  operator lines (server-host configuration, compliant per A13).
- No design-doc edits (already done in the design step).
- No mention of `defaultURL` (removed field) in the README.

## writePaths

- `README.md`
- `impl-plans/completed/search-engine-backend-boundary-p4-readme.md`
- `tmp/search-engine-backend-boundary/P4`

## sharedPaths (read-only)

- `design-docs/specs/search-engine-adapter.md`

## sharedPathNotes

- `README.md`: intendedEdit: two small additions in "Optional search engine": the config-url sentence and the Settings paragraph.
- `tmp/search-engine-backend-boundary/P4`: intendedEdit: evidence logs, hashes.txt and intent.md only.

## artifactRoots

- `tmp/search-engine-backend-boundary/P4`

## File-level changes

1. After "When `url` is omitted, the server uses the `KAIBA_MEILISEARCH_URL`
   environment variable, and falls back to `http://127.0.0.1:7700` when it
   is unset.", state that an empty or whitespace-only `url` counts as
   omitted, and that both are resolved on the server host.
2. In the Settings paragraph (the one starting "A `searchEngine` section in
   `config.json` takes precedence..."), add three to five sentences:
   - The URL field in **Settings** may be left empty to use the server
     default (the same `KAIBA_MEILISEARCH_URL`, then fallback resolution,
     done on the server). Clients never receive that value.
   - The plain-`http` rule (loopback only) applies to the host that runs
     the Kaiba server, not to the device running the client.
   - With the server default, a changed `KAIBA_MEILISEARCH_URL` takes
     effect at the next server start and triggers a backfill. If an API
     key is stored, it is not sent to the new host; enter the key again
     in **Settings**.

Keep the README's existing tone: short declarative sentences, no
emojis, no machine-local paths.

## Verification

```bash
mkdir -p tmp/search-engine-backend-boundary/P4
bash -c 'git diff --stat -- README.md | tee tmp/search-engine-backend-boundary/P4/diff-stat.log'
bash -c 'grep -n "Server default\|server default" README.md | tee tmp/search-engine-backend-boundary/P4/grep-default.log; test -s tmp/search-engine-backend-boundary/P4/grep-default.log'
bash -c 'grep -n "defaultURL\|/Users/" README.md | tee tmp/search-engine-backend-boundary/P4/guard.log; test ! -s tmp/search-engine-backend-boundary/P4/guard.log'
```

Expected evidence: the diff touches only `README.md` within the
"Optional search engine" section; the server-default grep is non-empty;
the guard grep is empty. This is a docs-only plan with no behavioral
test record; P5 runs the full gate set.

## Done criteria

- [x] Both additions present; no other README text changed.
- [x] No `defaultURL`, no machine-local path, no emoji.
- [x] Progress Log updated with commands, exit codes and log paths.
- [x] Branch evidence gate has a successful combined-tree test-runner record with positive counts. This record does not test README behavior; P5 owns full behavioral and integration gates.

## Progress Log

- 2026-10-05: Plan created.
- 2026-10-05: Added the config empty/whitespace URL note and Settings guidance
  for server-default resolution, server-host loopback validation, environment
  retarget backfill, and API-key re-entry. Diff is confined to those two
  locations in the README “Optional search engine” section.
- Verification (docs-only; P5 owns full behavioral and integration gates):
  - `bash -c 'git diff --stat -- README.md | tee tmp/search-engine-backend-boundary/P4/diff-stat.log'`
    — exit 0; log `tmp/search-engine-backend-boundary/P4/diff-stat.log`.
  - `bash -c 'grep -n "Server default\|server default" README.md | tee tmp/search-engine-backend-boundary/P4/grep-default.log; test -s tmp/search-engine-backend-boundary/P4/grep-default.log'`
    — exit 0; log `tmp/search-engine-backend-boundary/P4/grep-default.log`.
  - `bash -c 'grep -n "defaultURL\|/Users/" README.md | tee tmp/search-engine-backend-boundary/P4/guard.log; test ! -s tmp/search-engine-backend-boundary/P4/guard.log'`
    — exit 0; empty log `tmp/search-engine-backend-boundary/P4/guard.log`.
  - `rg --pcre2 -n '\p{Extended_Pictographic}' README.md`
    — no matches (rg exit 1, expected); empty log
    `tmp/search-engine-backend-boundary/P4/emoji-guard.log`.
  - `git diff --check -- README.md impl-plans/active/search-engine-backend-boundary-p4-readme.md`
    — exit 0; empty log `tmp/search-engine-backend-boundary/P4/diff-check.log`,
    exit recorded in `tmp/search-engine-backend-boundary/P4/diff-check.exit`.
  - `shasum -a 256 README.md impl-plans/active/search-engine-backend-boundary-p4-readme.md`
    — exit 0; hashes in `tmp/search-engine-backend-boundary/P4/hashes.txt`.
- 2026-10-05 verification rerun on the current README:
  - `git diff --stat -- README.md` — exit 0; one README file, 9 insertions
    and 1 deletion; log `tmp/search-engine-backend-boundary/P4/diff-stat-rerun-1.log`.
  - `grep -n "Server default\|server default" README.md` — exit 0; matches
    found; log `tmp/search-engine-backend-boundary/P4/grep-default-rerun-1.log`.
  - `grep -n "defaultURL\|/Users/" README.md` — no matches; expected grep
    exit 1 and verification exit 0; empty log
    `tmp/search-engine-backend-boundary/P4/guard-rerun-1.log`.
  - `rg --pcre2 -n '\p{Extended_Pictographic}' README.md` — no matches;
    expected rg exit 1 and verification exit 0; empty log
    `tmp/search-engine-backend-boundary/P4/emoji-guard-rerun-1.log`.
  - `git diff --check -- README.md impl-plans/active/search-engine-backend-boundary-p4-readme.md`
    — exit 0; no whitespace errors; log
    `tmp/search-engine-backend-boundary/P4/diff-check-rerun-1.log`.
- 2026-10-05 branch evidence gate repair:
  - `cd web && mise exec -- bun test src` — exit 0; 190 pass, 0 fail;
    190 tests reported; complete combined-tree regression log
    `tmp/search-engine-backend-boundary/P4/bun-test.log`. This test run is
    recorded to satisfy the branch evidence gate and does not test README
    behavior; P5 owns the full behavioral and integration gates.
  - `grep -n "server default" README.md` — exit 0; matches found; log
    `tmp/search-engine-backend-boundary/P4/grep-default-rerun-2.log`.
  - `grep -n "defaultURL\\|/Users/" README.md` — no matches; expected grep
    exit 1 and verification exit 0; empty log
    `tmp/search-engine-backend-boundary/P4/guard-rerun-2.log`.
  - `shasum -a 256 README.md` — exit 0; README hash remains
    `002b3385088bef9ce77563ad520a0f2d05fdf1745ee17b68dedd08a58808a816`.
