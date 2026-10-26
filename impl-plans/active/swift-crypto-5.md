# swift-crypto 5.x, AutoAction clamps and 0.1.19 (index)

**Status**: In Progress
**Design Reference**: `design-docs/specs/kaiba-note.md` (K3 updated 2026-10-27, K15, Verification)
**Workflow**: opus-luna-design-and-implement-review-loop-session-510, mode `issue-resolution`
**Issue**: workflowInput "kaiba: move to swift-crypto 5.x and clamp AutoAction limit/sleep" (no GitHub issue URL or number)

## Purpose

The owner wants every package in the Riela dependency graph on swift-crypto 5.x,
so kaiba requires `from: "5.0.3"`. This work also ports two AutoAction safety
clamps from Riela (f5a26c83, cf34383d) and bumps the patch version to 0.1.19.
Hashing and HMAC outputs and all other behavior must stay unchanged.

## Plans (all wave 1, disjoint write paths)

| planId | plan | owns |
| --- | --- | --- |
| swift-crypto-5-p1-dependency | `swift-crypto-5-p1-dependency.md` | `Package.swift`, `Package.resolved`, the 7 crypto-importing sources (edit only if the Linux compile needs it) |
| swift-crypto-5-p2-autoaction-clamps | `swift-crypto-5-p2-autoaction-clamps.md` | `Sources/AppCore/AutoActionDispatching.swift`, `Tests/AppCoreTests/AutoActionRecoveryTests.swift` |
| swift-crypto-5-p3-version-bump | `swift-crypto-5-p3-version-bump.md` | `VERSION`, `Sources/AppCore/Version.swift`, `web/src-tauri/Cargo.toml`, `web/src-tauri/Cargo.lock`, `web/src-tauri/tauri.conf.json` |

No plan depends on another. The DAG has a single wave.

## Edit protocol (every plan)

- Before each edit, read the target file fresh and record `shasum -a 256 <file>` in the
  plan's `logs/` as the pre-hash. Record the post-hash after the edit. If the pre-hash
  differs from the last hash you recorded, another writer touched the file. Stop and
  record `status: blocked (drift)` instead of overwriting.
- Edit only your own `writePaths`. Never edit `.riela/`, `node_modules/`,
  `tmp/ui-preview-compat/` (gitignored scratch with its own Package.swift),
  `schema/note-store.sqlite.sql`, `Sources/AppCore/NoteStoreSchemaDDL.generated.swift`,
  `design-docs/`, other plans' files, or any `impl-plans/active/*-dispatch.json`.
- No git write operations (no add, commit, stash, checkout, branch, worktree or push).
  Committing and pushing happen in serial finalization.
- Run every command in the foreground. Tee it into `tmp/swift-crypto-5/<P#>/logs/NN-name.log`
  and end the log with `exit=<code>`. An incomplete log is not a pass.
- Plain `swift build` and `swift test` work on macOS without `mise run anydoc:native` because the
  Apple XCFramework artifact is resolved by SwiftPM. Do not run `mise run anydoc:native`,
  `mise run build`, `mise run test` or `mise run check` inside a plan. P1 and P2 share
  `.build`, and SwiftPM's lock serializes them. Full gates run during integration.
- Each worker appends only to its own `tmp/swift-crypto-5/<P#>/progress.md`, ending with
  `status: done` or `status: blocked (<reason>)`.

## Integration and finalization (serial, after all plans are accepted)

1. `swift build`, then `swift test` (full suite), then `mise run lint`, then `mise run check`. Each must exit 0.
2. `git diff --stat` shows only the files owned by P1-P3 plus this plan set and the design doc.
   `.riela/` and `node_modules/` are not staged.
3. Commit: one commit with no AI attribution and no emojis. Push to `origin main` (gitPush=true).
   Do not create releases, formulas or casks.
4. After the push, run `gh run list --workflow linux-amd64-build.yml --branch main --limit 1`
   and `gh run watch <id> --exit-status` in the foreground. Record the conclusion. A failure
   is reported as a follow-up fix, not a pass.

## Completion criteria

- [ ] P1, P2 and P3 have `status: done` with complete logs.
- [ ] Integration gates pass, the commit is pushed, and the Linux CI conclusion is recorded.

## Progress Log

- 2026-10-27: Plan set created from the accepted design (Step 3 accepted, needs_revision=false).
