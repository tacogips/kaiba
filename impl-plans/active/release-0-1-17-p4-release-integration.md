# P4 Release integration: version 0.1.17, README check, combined-tree gates

**Status**: Planned.
**planId**: P4-release-integration
**Wave**: 3
**dependsOn**: P1-agentic-search-diagnostics, P2-served-sandbox, P3-settings-contrast
**Design Reference**:
- `design-docs/specs/ai-agent-integration.md`: AI13 and Verification items 11-13
- `design-docs/specs/web-chatbook-ui.md`: W16 and Verification
- the Step 2 release decision: the five version files, and README "Optional search engine" confirmed accurate

**Index**: `impl-plans/active/release-0-1-17.md`

## Intent and context

This plan prepares kaiba 0.1.17 for the operator, who runs `.agents/skills/macos-cask-release/SKILL.md` afterwards. It does not run that skill. It has four jobs:

1. Bump the version from `0.1.16` to `0.1.17` in exactly these five places, following commit 2035fda (the 0.1.16 bump touched the same five files):
   - `VERSION:1`
   - `Sources/AppCore/Version.swift:2` (`public static let current = "0.1.17"`)
   - `web/src-tauri/tauri.conf.json:4`
   - `web/src-tauri/Cargo.toml:3`
   - `web/src-tauri/Cargo.lock`, the `version` line of the `name = "kaiba-client"` package entry (line 1790). Edit by hand; do not run `cargo update`.

   `git grep 0.1.16` currently finds no other tracked reference outside `design-docs/` and `impl-plans/`.
2. Confirm that README "Optional search engine" (`README.md:181-266`) matches the shipped behavior:
   - Meilisearch is the only adapter and the default;
   - `elasticsearch` is rejected;
   - the URL is resolved on the backend from `KAIBA_MEILISEARCH_URL` and then the fallback;
   - the engine stays optional and backend-only;
   - `mise run search:test-live` is documented.

   Change README only for a concrete factual mismatch, and record the reason. The expected outcome is no change.
3. Run every gate on the combined tree and fill the index table.
4. Make any cross-plan repair needed. Each repair is recorded with the owning plan, the file, the pre/post hash and the reason. No assertion may be weakened.

## Non-goals

- Do not run signing, notarization, cask or Homebrew release scripts.
- Do not create tags or GitHub releases. Do not touch `../homebrew-tap`.
- No git commits; the workflow commits after review.
- No feature work beyond repairs of P1-P3 defects.
- Do not edit `design-docs/`. A design defect found here is reported, not patched.
- Do not edit `.riela/`, api-key-expiration work, `NoteStoreSchema`, `Sources/AppServer/*`, `mise.toml`, `docker/`, `web/src-tauri/capabilities/` or any `*-dispatch.json`.

## writePaths

- `VERSION`
- `Sources/AppCore/Version.swift`
- `web/src-tauri/tauri.conf.json`
- `web/src-tauri/Cargo.toml`
- `web/src-tauri/Cargo.lock`
- `README.md`
- `impl-plans/active/release-0-1-17.md`
- `impl-plans/active/release-0-1-17-p4-release-integration.md`
- `Sources/AppCore/AgentGatewayInvocationSanitization.swift`
- `Sources/AppCore/AgentGatewayCLIInvoker.swift`
- `Sources/AppCore/AgentGatewayExecutionIsolation.swift`
- `Sources/AppGraphQL/NoteGraphQLService.swift`
- `Sources/AppGraphQL/NoteGraphQLAgenticSearch.swift`
- `Tests/AppCoreTests/AgentGatewayPublicDiagnosticTests.swift`
- `Tests/AppCoreTests/AgentGatewayServedSandboxProfileTests.swift`
- `Tests/AppGraphQLTests/AgenticSearchDiagnosticsGraphQLTests.swift`
- `Tests/AppGraphQLTests/LiveServedAgenticSearchTests.swift`
- `web/src/light-theme.css`
- `web/src/settingsButtonContrast.test.ts`
- `web/dist`
- `web/src-tauri/target`
- `tmp/release-0-1-17/P4`

## sharedPaths (read-only)

- `design-docs/specs/ai-agent-integration.md`
- `design-docs/specs/web-chatbook-ui.md`
- `design-docs/specs/search-engine-adapter.md`
- `Tests/AppCoreTests/MeilisearchLiveTests.swift`
- `mise.toml`

## sharedPathNotes

- `VERSION`, `Sources/AppCore/Version.swift`, `web/src-tauri/tauri.conf.json`, `web/src-tauri/Cargo.toml`, `web/src-tauri/Cargo.lock`: change only the one version token in each; nothing else.
- `README.md`: fact corrections only, and only if a mismatch is found. Expected: unchanged.
- `Sources/AppCore/AgentGatewayExecutionIsolation.swift` and every other P1-P3 source or test path: integration repairs only. Record each in this plan's Progress Log.
- `web/dist` and `web/src-tauri/target`: generated output from `web:check` and `tauri:check` only.
- `Tests/AppCoreTests/MeilisearchLiveTests.swift`: read-only. The live search suite must pass unmodified.
- `design-docs/specs/search-engine-adapter.md`: read-only, the source for the README fact check.
- `tmp/release-0-1-17/P4`: evidence logs, `hashes.txt` and `intent.md` only.

## artifactRoots

- `tmp/release-0-1-17/P4`
- `web/dist`
- `web/src-tauri/target`

## Pitfalls

- Cargo: `tauri:check` runs `cargo check` without `--locked`, so a mismatched lock would be rewritten silently. Edit `Cargo.toml` and `Cargo.lock` together, then confirm with `git diff --stat -- web/src-tauri/Cargo.lock` that exactly one line changed after `tauri:check`.
- Run the live agent-gateway test with the gate on. A skipped run (`Executed 0 tests` or a skip message) is not evidence. If `OPENROUTER_API_KEY` is absent, record `blocked`.
- `search:test-live` needs Docker through colima. Start it with `mise run search:docker`, then `search:up`, and always run `search:down` afterwards. If Docker or colima is unavailable, record `blocked: <exact error>`, never passed.
- The full `swift test` output contains both XCTest and swift-testing summaries; record both counts.
- Never print key values. Use only the presence check.
- `tauri:check` needs the gitignored local-service sidecar that the operator built in this worktree. If it is missing again (exit 101), record `blocked: <exact error line>`. Do not build it, and do not edit anything under `web/src-tauri/local-service/`.
- The final commit must pass the repository pre-commit hook without `--no-verify`. The local-path guard is the in-plan proxy for that hook; it must be empty over the whole release diff, not just the working tree.

## Resume notes (session-279)

- Not started in session-278. Start only after P1, P2 and P3 report Completed or explicitly blocked in this run.
- P1 and P3 are partly committed in 0172b87; the guards above diff against `d55f835` for that reason.
- Fill the index table from this run's logs only. Do not reuse session-278 logs as gate evidence.

## Tests

No new tests. P4 runs the full suites, and any repair keeps every P1-P3 test intact.

## Verification

```bash
mkdir -p tmp/release-0-1-17/P4
bash -c 'cat VERSION; grep -n "current" Sources/AppCore/Version.swift; grep -n "\"version\"" web/src-tauri/tauri.conf.json; grep -n "^version" web/src-tauri/Cargo.toml; grep -n -A1 "name = \"kaiba-client\"" web/src-tauri/Cargo.lock' | tee tmp/release-0-1-17/P4/version.log
bash -c 'git grep -n "0\.1\.16" -- ":!design-docs" ":!impl-plans" | tee tmp/release-0-1-17/P4/guard-old-version.log; test ! -s tmp/release-0-1-17/P4/guard-old-version.log'
bash -c 'mise run build 2>&1 | tee tmp/release-0-1-17/P4/build.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test 2>&1 | tee tmp/release-0-1-17/P4/swift-test.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'test -n "$OPENROUTER_API_KEY" && echo present || echo absent' | tee tmp/release-0-1-17/P4/key-presence.log
bash -c 'KAIBA_LIVE_AGENT_GATEWAY=1 PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter LiveServedAgenticSearchTests 2>&1 | tee tmp/release-0-1-17/P4/live-agent-gateway.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run lint 2>&1 | tee tmp/release-0-1-17/P4/lint.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'cd web && mise exec -- bun test src 2>&1 | tee ../tmp/release-0-1-17/P4/bun-test.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'cd web && mise exec -- bunx vitest run 2>&1 | tee ../tmp/release-0-1-17/P4/vitest.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run web:check 2>&1 | tee tmp/release-0-1-17/P4/web-check.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run tauri:check 2>&1 | tee tmp/release-0-1-17/P4/tauri-check.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'git diff --stat -- web/src-tauri/Cargo.lock | tee tmp/release-0-1-17/P4/cargo-lock-diff.log'
bash -c 'mise run search:docker 2>&1 | tee tmp/release-0-1-17/P4/search-docker.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run search:up 2>&1 | tee tmp/release-0-1-17/P4/search-up.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run search:test-live 2>&1 | tee tmp/release-0-1-17/P4/search-live.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run search:down 2>&1 | tee tmp/release-0-1-17/P4/search-down.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'git status --porcelain | tee tmp/release-0-1-17/P4/changed-files.log'
bash -c 'git diff --name-only -- mise.toml docker Sources/AppServer web/src-tauri/capabilities web/src/styles.css web/src/workspace.css web/src/index.tsx web/src/App.tsx Sources/AppCore/AgentGatewaySubscription.swift Sources/AppCore/ClaudeSubscriptionExecution.swift | tee tmp/release-0-1-17/P4/guard-protected.log; test ! -s tmp/release-0-1-17/P4/guard-protected.log'
bash -c 'git diff --name-only -- design-docs | tee tmp/release-0-1-17/P4/guard-design-docs.log'
bash -c '{ git diff --name-only --diff-filter=d d55f835; git ls-files --others --exclude-standard; } | grep -v "^\.riela/" | sort -u | tee tmp/release-0-1-17/P4/release-files.log'
bash -c 'tr "\n" "\0" < tmp/release-0-1-17/P4/release-files.log | xargs -0 grep -nE "/U[s]ers/|/h[o]me/|/n[i]x/store/|/opt/homebrew/C[e]llar" | tee tmp/release-0-1-17/P4/guard-local-paths.log; test ! -s tmp/release-0-1-17/P4/guard-local-paths.log'
bash -c 'tr "\n" "\0" < tmp/release-0-1-17/P4/release-files.log | xargs -0 grep -nE "sk-or-v1-[A-Za-z0-9]{16,}" | tee tmp/release-0-1-17/P4/guard-secrets.log; test ! -s tmp/release-0-1-17/P4/guard-secrets.log'
bash -c 'grep "\.swift$" tmp/release-0-1-17/P4/release-files.log | tr "\n" "\0" | xargs -0 wc -l | tee tmp/release-0-1-17/P4/wc.log'
```

Why the guards use the release base:

- P1 and P3 were committed in checkpoint 0172b87, and the design and plans are committed before fanout. A working-tree-only `git diff` would therefore miss them.
- `d55f835` is the merge base with `origin/main`. Diffing against it scans every file the release changes.
- The regex uses character classes (`/U[s]ers/` and similar) so this command text does not itself contain the literals the pre-commit hook rejects.
- `impl-plans/` and `design-docs/` are scanned too, because the final commit stages them.

Expected evidence:

- `version.log` shows `0.1.17` in all five places, and `guard-old-version.log` is empty.
- build exit 0.
- Full `swift test` exit 0: XCTest `Executed N tests` with N > 0 and 0 failures, plus the swift-testing `N tests passed` count. Record both. Skipped env-gated tests are listed, not counted.
- Live agent-gateway: exit 0, with XCTest `Executed N tests, with 0 failures` where N > 0 for `LiveServedAgenticSearchTests`. Otherwise record `blocked: <reason>`.
- lint exit 0.
- `bun test src` and `vitest run` exit 0 with counts > 0, recorded separately.
- `web:check` and `tauri:check` exit 0.
- `cargo-lock-diff.log` shows exactly 1 insertion and 1 deletion.
- `search:test-live` exit 0, with the XCTest count of the positive run only. The Docker lifecycle commands exit 0, or are recorded as blocked.
- `release-files.log` lists the release's changed and untracked files and never `.riela/`. The protected, local-path and secret guard logs are empty. If a local-path match is found in a P1-P3 file, repair it with a `/opt/example/...` placeholder or a runtime-built path, and record the repair. If the match is in a plan file, fix that plan file's text without changing its meaning.
- `guard-design-docs.log` is empty, or lists only `design-docs/specs/ai-agent-integration.md` with P2's single bounded-allowance line, which must be cross-checked against P2's Progress Log.
- Every changed Swift file is under 1000 lines.

## Done criteria

- [ ] Version 0.1.17 is in all five files, and no stray `0.1.16` remains outside docs and plans.
- [ ] The README search section is confirmed accurate (or corrected, with the reason recorded).
- [ ] The index "Final integration evidence" table is filled with exit codes, counts and log paths, and the index Status is updated.
- [ ] Every integration repair is recorded, and no assertion is weakened.
- [ ] No high or mid finding is unresolved. Any blocker (missing key, Docker/colima, `log show`) is reported explicitly, never as passed.

## Progress Log

- 2026-10-05: Plan created.
- 2026-10-06: Step 4 (session-279) revised the guards to scan the whole release diff against `d55f835`, including the pre-commit hook's literal classes, and added the tauri sidecar and resume notes. Not started.
