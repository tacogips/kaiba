# Release 0.1.17 Preparation (index)

**Status**: Active (resume, session-281). Plans P1-P4 were created in session-278 (design accepted in comm-004276) and revised in session-279. In session-281, P1 and P3 are accepted dependencies. P2 is verified and accepted under the amended AI13 "Diagnosis gate" (Step 3 accepted it in comm-004324), and P4 runs afterwards.
**Design Reference**: `design-docs/specs/ai-agent-integration.md` (the Runtime and Provider Adapter Boundary paragraph, AI13 including the "Diagnosis gate" revised on 2026-10-06, the GraphQL Surface Additions `agenticSearch` bullet, and Verification item 13), `design-docs/specs/web-chatbook-ui.md` (W16) and `design-docs/user-qa/ai-agent-runtime-and-ui.md` ("Served sandbox: residual non-fatal denials (decided 2026-10-06)", read-only)
**Evidence root**: `tmp/release-0-1-17/<planId-prefix>/`. It is gitignored by `tmp/`, and each plan writes only its own directory.

## Purpose

This release ships kaiba 0.1.17 after fixing two defects found in end-to-end verification:

1. Served GraphQL `agenticSearch` fails under the macOS agent-gateway sandbox with the opaque diagnostic `note operation failed`.
   - P1 makes the failure diagnosable: a sanitized public reason plus one sanitized server log line.
   - P2 fixes the sandbox root cause:
     - realpath-resolved executable;
     - `/private/etc` and `resolv.conf` read access;
     - TLS/DNS mach services.
   - P2 also proves the fix with an env-gated live test.
2. In Settings, the selected font-size preset and the primary buttons are unreadable in the light theme. P3 fixes this.
3. P4 bumps the version to 0.1.17, confirms the README search-engine section, and runs every gate on the combined tree.

## Resume state (session-281)

Checkpoint c35c0a3 holds the session-279 work.

| planId | state at resume | work in this run |
| --- | --- | --- |
| P1-agentic-search-diagnostics | accepted in session-279 | none; in the manifest's `acceptedDependencies`. P4's full `swift test` is its regression check. |
| P3-settings-contrast | accepted in session-279 | none; in `acceptedDependencies`. P4's `bun test src`, `vitest run`, `web:check` and `tauri:check` are its regression check. |
| P2-served-sandbox | implemented; the live test passed; blocked only by the old clean-log gate | Verify and accept against the amended gate: live pass plus no fatal denial, and record the residual denial classes and counts for one bounded window. No sandbox allowance change and no design or manifest edit. |
| P4-release-integration | not started | Full plan: version bump, README check, all gates, and release-wide guards including the no-new-allowance guard. |

Design delta for this run: AI13's "Diagnosis gate" and the Verification 13 live-test bullet in `design-docs/specs/ai-agent-integration.md` now follow the operator decision of 2026-10-06. That decision is to keep the residual non-fatal denials denied, add no allowances, and accept on a live pass with no fatal denial. Residual classes and counts are evidence. The design edit, these plans and the manifest are committed together in the plan checkpoint commit before fanout.

Pre-commit hook: the repository hook rejects staged text containing absolute path literals rooted in the macOS users directory, the Linux home directory or the Nix store. No plan writes such a literal into a committed file, including plan files and this index. Guard regexes use character classes (`/U[s]ers/`) so their own text stays clean.

## Plans and waves

| wave (session-281) | planId | plan | dependsOn |
| --- | --- | --- | --- |
| accepted | P1-agentic-search-diagnostics | `impl-plans/active/release-0-1-17-p1-agentic-search-diagnostics.md` | none |
| accepted | P3-settings-contrast | `impl-plans/active/release-0-1-17-p3-settings-contrast.md` | none |
| 1 | P2-served-sandbox | `impl-plans/active/release-0-1-17-p2-served-sandbox.md` | P1 (accepted) |
| 2 | P4-release-integration | `impl-plans/active/release-0-1-17-p4-release-integration.md` | P1 (accepted), P2, P3 (accepted) |

DAG: P1 -> P2 -> P4, and P3 -> P4. P3 never touches Swift. In session-281, only P2 and P4 are dispatched.

Why the waves are ordered this way:

- P1 and P2 both edit the AppCore module, and AppGraphQL depends on AppCore. Running them in parallel could leave one waiting on the other's in-progress compile errors, so P2 runs after P1.
- The version bump includes `Sources/AppCore/Version.swift`, which is also AppCore, so it goes to P4 after all Swift work.
- P1 lands first because its sanitized diagnostics make P2's baseline live run show the real failure class.

## Shared-file ownership

Every file has exactly one writer per wave.

| file | wave 1 | wave 2 | wave 3 |
| --- | --- | --- | --- |
| `Sources/AppCore/AgentGatewayInvocationSanitization.swift` | - (done in 0172b87; read-only in this run) | - | P4 (repair only) |
| `Sources/AppCore/AgentGatewayCLIInvoker.swift` | - (done in 0172b87; read-only in this run) | - | P4 (repair only) |
| `Sources/AppGraphQL/NoteGraphQLService.swift` | - (done in 0172b87; read-only in this run) | - | P4 (repair only) |
| `Sources/AppGraphQL/NoteGraphQLAgenticSearch.swift` | - (done in 0172b87; read-only in this run) | - | P4 (repair only) |
| `Tests/AppCoreTests/AgentGatewayPublicDiagnosticTests.swift` (new) | P1 | - | P4 (repair only) |
| `Tests/AppGraphQLTests/AgenticSearchDiagnosticsGraphQLTests.swift` (new) | P1 | - | P4 (repair only) |
| `Sources/AppCore/AgentGatewayExecutionIsolation.swift` | - | P2 | P4 (repair only) |
| `Tests/AppCoreTests/AgentGatewayServedSandboxProfileTests.swift` (new) | - | P2 | P4 (repair only) |
| `Tests/AppGraphQLTests/LiveServedAgenticSearchTests.swift` (new) | - | P2 | P4 (repair only) |
| `design-docs/specs/ai-agent-integration.md` | - (session-281: read-only for every plan; edited only in the plan checkpoint commit) | - | - |
| `web/src/light-theme.css` | P3 | - | P4 (repair only) |
| `web/src/settingsButtonContrast.test.ts` (new) | P3 | - | P4 (repair only) |
| `VERSION`, `Sources/AppCore/Version.swift`, `web/src-tauri/tauri.conf.json`, `web/src-tauri/Cargo.toml`, `web/src-tauri/Cargo.lock` | - | - | P4 |
| `README.md` | - | - | P4 (fact corrections only, if any) |
| this index | - | - | P4 |

No plan may edit the following files:

- `.riela/` (absent in this worktree; never create it)
- any api-key-expiration work
- `NoteStoreSchema` or any store schema
- `web/src/styles.css`, `web/src/workspace.css`, `web/src/index.tsx`, `web/src/App.tsx`
- `Sources/AppCore/AgentGatewaySubscription.swift`, `Sources/AppCore/ClaudeSubscriptionExecution.swift`
- `Sources/AppServer/*`
- `mise.toml`, `docker/`
- `web/src-tauri/capabilities/`
- every `impl-plans/active/*-dispatch.json`
- `design-docs/` files (session-281: no exception)
- any `(allow ...)` rule in a sandbox profile (no addition, removal or widening; operator decision of 2026-10-06)
- signing, notarization or cask scripts
- `../homebrew-tap`

No plan creates a tag or a GitHub release.

## Edit protocol (every plan)

1. Read each file fresh before editing it. Record `shasum -a 256 <file>` as the pre-hash in `tmp/release-0-1-17/<P#>/hashes.txt`.
2. Before the first edit, write an immutable intent snapshot to `tmp/release-0-1-17/<P#>/intent.md`: the plan's file-level changes in your own words. Never rewrite it.
3. After each edit, record the post-hash. Before editing the same file again, compare its current hash with your recorded post-hash.
   - If they differ (drift), re-read the file and re-apply only your intent.
   - Note the drift in your plan's Progress Log.
4. Edit only your own `writePaths`. Never edit a peer's file to make your build pass.
   - A compile or lint failure caused by a peer's in-progress file is not a blocker.
   - Record it, rerun after the peer lands, and leave cross-plan fixes to P4.
5. No git write operations: no add, commit, stash, checkout, branch or worktree.
6. Each plan updates only the Progress Log in its own plan file.
7. Secrets:
   - Never print, echo, log or commit `OPENROUTER_API_KEY` or any other credential value.
   - To check presence, use `test -n "$OPENROUTER_API_KEY" && echo present || echo absent`.
   - Never copy machine-local absolute paths (home directories, Homebrew keg paths) into committed files, including plan Progress Logs. Describe them by class instead, for example "the Homebrew keg executable". Raw logs under `tmp/` are gitignored and may contain such paths.

## Evidence policy

- A behavioral record needs all of the following:
  - a test-runner command (`swift test ...`, `bun test ...`, `vitest run ...`, or `mise run <task containing test>`);
  - exit code 0;
  - every count greater than 0.
- For XCTest, record the `Executed N tests, with 0 failures` line with N > 0. For swift-testing, record the `Test run with N tests passed` line with N > 0, but only when the filter selects swift-testing tests.
- `mise run web:check` is not a behavioral record. Record `bun test src` and `vitest run` separately.
- An env-gated skip is never evidence. For the live agent-gateway test, record only the XCTest `Executed N tests` count (N > 0) of the positive run; its swift-testing line prints 0 and is not counted.
- Tee every command into the plan's evidence directory. Each record gives the complete log path and the final exit status.

## Completion

The release is complete when:

- P1-P4 all report Completed in their Progress Logs;
- P4 has filled the gate table below with positive counts;
- the version reads 0.1.17 in all five files;
- no high or mid finding remains open.

## Final integration evidence

P4 fills this table.

| Gate | Result | Evidence |
| --- | --- | --- |
| `mise run build` | pending | `tmp/release-0-1-17/P4/build.log` |
| Full Swift tests | pending | `tmp/release-0-1-17/P4/swift-test.log` |
| Live served agenticSearch | pending | `tmp/release-0-1-17/P4/live-agent-gateway.log` |
| P2 residual Sandbox denials (evidence only, not a gate) | pending | `tmp/release-0-1-17/P2/accept/sandbox-denial-classes.log` |
| `mise run lint` | pending | `tmp/release-0-1-17/P4/lint.log` |
| `bun test src` | pending | `tmp/release-0-1-17/P4/bun-test.log` |
| `vitest run` | pending | `tmp/release-0-1-17/P4/vitest.log` |
| `mise run web:check` | pending | `tmp/release-0-1-17/P4/web-check.log` |
| `mise run tauri:check` | pending | `tmp/release-0-1-17/P4/tauri-check.log` |
| `mise run search:test-live` | pending | `tmp/release-0-1-17/P4/search-live.log` |
| Version guard | pending | `tmp/release-0-1-17/P4/version.log` |
| Protected-path, local-path, design-docs and allowance guards | pending | `tmp/release-0-1-17/P4/guard-*.log` |

## Progress Log

- 2026-10-05: Plans P1-P4 were created from the accepted AI13 and W16 design (Step 3 accept, comm-004276).
- 2026-10-06: Session-279 Step 4 revised the plans for resume. P1 is fixture-and-literals only. P3 is re-verification only. P2 gains its P1-compatibility and literal guard. P4's guards now scan the whole release diff against `d55f835`. The dispatch manifest is updated to match.
- 2026-10-06: The session-279 run accepted P1 and P3. P2 was implemented and its live test passed, but it was blocked by the clean-log gate (about 51 non-fatal denials). Checkpoint c35c0a3.
- 2026-10-06: Session-281 Step 4:
  - The manifest moves P1 and P3 into `acceptedDependencies` and drops them from the dispatched plans.
  - P2 is now a wave-1 verify-and-accept plan under the amended gate, with evidence in `tmp/release-0-1-17/P2/accept/`.
  - P4 is now wave 2 and has the no-new-allowance and empty-design-docs guards.
