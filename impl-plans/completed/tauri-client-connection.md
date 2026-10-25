# Tauri client connection settings: plan index

Issue: workflowInput 'Tauri client app with configurable connection target'
(user request 2026-10-25; no GitHub issue). Workflow mode: issue-resolution.

**Status**: Completed. P1-P4 were accepted in session 481 and P5 in session
483. Every progress log under `tmp/tauri-client-connection/P1..P5/` ends with
`status: done`. P5 recorded exit 0 for `cd web && bun test src` (1341 pass,
0 fail), `cd web && bunx vitest run` (56 files, 238 tests), `cd web && bun
run typecheck`, `cd web && bun run lint`, `mise run tauri:check` and `mise
run tauri:build`. The unsigned bundle is
`web/src-tauri/target/release/bundle/macos/Kaiba.app`, and its
`Contents/MacOS/kaiba` is byte-identical to the fresh
`web/src-tauri/local-service/kaiba-aarch64-apple-darwin`. The browser E2E
step was skipped because the repository has no E2E harness, and `Kaiba.app`
was not launched. Moved to `impl-plans/completed/` at Step 8 on 2026-10-25.
The dispatch manifest `impl-plans/active/tauri-client-connection-dispatch.json`
is a workflow runtime artifact and stays in `impl-plans/active/`.

Design (accepted at Step 3, needs_revision=false):

- `design-docs/specs/tauri-client-apps.md`: sections "Connection modes",
  "Connection settings" (with "Switching and per-account state", "Test
  connection", "Recent remote endpoints", "Reachability"), and the
  "Bundled local service" paragraph under "Build surfaces".
- `design-docs/user-qa/tauri-client-connection-20261025.md`: decisions.
- `design-docs/user-qa/tauri-client-apps.md`: the plain-`http` question is
  answered.

## User intent

Build an unsigned macOS `Kaiba.app` from current main with `mise run
tauri:build`. The bundle must contain a freshly built bundled `kaiba`
service and the current web client. Make the connection target
configurable: Local or Remote, a validated remote URL, Test connection,
the five most recent remote servers, and the active connection shown in
Settings. The settings must stay reachable from login, error and unreachable
states. Per-origin bearer scoping must not regress.

## Plans and waves

| Plan | File | Wave | Depends on |
| --- | --- | --- | --- |
| P1 endpoint store helpers | `impl-plans/completed/tauri-client-connection-p1-endpoint-store.md` | 1 | none |
| P2 connection probe | `impl-plans/completed/tauri-client-connection-p2-connection-probe.md` | 1 | none |
| P4 README and spec touch-up | `impl-plans/completed/tauri-client-connection-p4-docs.md` | 1 | none |
| P3 settings UI and reachability tests | `impl-plans/completed/tauri-client-connection-p3-settings-ui.md` | 2 | P1, P2 |
| P5 integration gates and app bundle | `impl-plans/completed/tauri-client-connection-p5-bundle-build.md` | 3 | P1, P2, P3, P4 |

Checkpoint (session opus-luna-design-and-implement-review-loop-session-483,
2026-10-25): P1, P2, P3 and P4 were accepted in session 481 by test-integrity
and adversarial review. Their changes are in the working tree and must be
preserved. They are listed under `acceptedDependencies` in
`impl-plans/active/tauri-client-connection-dispatch.json` and are not
redispatched. Only P5 is dispatched, as the single plan of wave 1. Session 481
blocked P5 only because of an invalid typecheck gate (`bunx tsc --noEmit -p
web` from the repository root, which cannot resolve `bun:test` types). Every
plan now uses `cd web && bun run typecheck` instead.

P1 and P2 pin the TypeScript contracts that P3 consumes. Their exact
signatures are written in each plan, so P3 can be read and prepared in
advance but is only implemented once P1 and P2 have landed.

## Global non-goals (all plans)

- No Swift, Rust (`web/src-tauri/src`), capability, `tauri*.conf.json`,
  `scripts/` or `mise.toml` change. The design (D11) found that none is
  needed.
- No first-run modal, no in-place state reset, no credential pruning, no
  delete button for recent entries, no new toast action, no CSS file edits.
  The existing `.server-connection > p` and `> label` rules in
  `web/src/chatbook.css` already style the new elements.
- No signing, notarization, release, git push, git branch/worktree/commit
  operations, and no edits to `.riela/` or `node_modules/` (except the
  vitest cache artifact root declared in P3/P5).
- Never read, open or launch against `~/Library/Application
  Support/com.tacogips.kaiba/local`. Do not launch `Kaiba.app`, because Local
  mode opens that store.
- Never hand-edit `schema/note-store.sqlite.sql` or
  `Sources/AppCore/NoteStoreSchemaDDL.generated.swift`.

## Invariants every plan must keep

- A bearer stored under `kaiba-note-bearer:<origin>` is only ever sent to that
  origin. Local mode sends no `Authorization`. The probe sends no
  `Authorization` to anyone.
- `serverCredentialKey`, `currentServerCredentialKey`, `saveServerEndpoint`,
  `assertServerOrigin`, `serverRequest`, `normalizeServerEndpoint` and
  `readConnectionMode` keep their current behavior and signatures.
- Every existing test keeps passing unmodified, unless a plan explicitly
  sanctions an edit. No plan sanctions one.
- Files stay under 1000 lines; no emojis; terse Solid/TS style.

## Edit protocol (all plans)

1. Before the first edit, write `tmp/tauri-client-connection/<P#>/intent.md`.
   It records the plan ID, the files you will touch and a one-line intent per
   file, and it is never rewritten afterwards.
2. For every edit, read the target fresh, append `pre <shasum -a 256>
   <path>` to `tmp/tauri-client-connection/<P#>/hashes.txt`, edit, then
   append `post <sha> <path>`.
3. If a file's pre-hash differs from your last recorded post-hash for it,
   another writer touched it (drift). Re-read the file, re-apply only your own
   intent, and note the drift in your progress log.
4. Edit only your own `writePaths`. If a peer plan's file fails to compile or
   lint, that is not your blocker. Re-run after the peer lands, and record
   cross-plan defects for serial reconciliation. Do not fix them yourself.
5. Progress log: `tmp/tauri-client-connection/<P#>/progress.md`, edited only
   by the owning plan. Each entry gives a timestamp, the step, the command,
   the exit code, the full log path and the counts. The final entry is
   `status: done`, or `status: blocked: <reason>`.

## Evidence policy

A behavioral record is a test-runner command (`bun test ...` or `vitest run
...`) with exit code 0 and a test count greater than 0. `bun test src` and
`bunx vitest run` are recorded separately. `mise run web:check` is never the
recorded test command. Tee every command into
`tmp/tauri-client-connection/<P#>/` (P5 uses `.../P5/logs/`) and record the
complete log path and the final exit status. Run every command in the
foreground, with no `&`, `nohup` or detached processes. An incomplete log is
not a pass.

## Completion criteria (whole task)

- P1 to P5 progress logs end in `status: done`.
- P5 records exit 0 and a positive count for `cd web && bun test src` and
  `cd web && bunx vitest run`, and exit 0 for `cd web && bun run typecheck`,
  `cd web && bun run lint`, `mise run tauri:check` and `mise run
  tauri:build`. It also records that
  `web/src-tauri/target/release/bundle/macos/Kaiba.app/Contents/MacOS/kaiba`
  is byte-identical to `web/src-tauri/local-service/kaiba-aarch64-apple-darwin`
  and newer than the build-start marker.
- `git diff --stat f02c4fe -- Sources Package.swift Package.resolved` is
  empty (Swift is unchanged).
