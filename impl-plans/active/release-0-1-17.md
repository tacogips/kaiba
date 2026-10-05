# Release 0.1.17 Preparation (index)

**Status**: Active. Plans P1-P4 were created at Step 4 from the accepted design (Step 3 accept, comm-004276).
**Design Reference**: `design-docs/specs/ai-agent-integration.md` (Runtime and Provider Adapter Boundary paragraph, AI13, the GraphQL Surface Additions `agenticSearch` bullet, Verification item 13) and `design-docs/specs/web-chatbook-ui.md` (W16)
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

## Plans and waves

| wave | planId | plan | dependsOn |
| --- | --- | --- | --- |
| 1 | P1-agentic-search-diagnostics | `impl-plans/active/release-0-1-17-p1-agentic-search-diagnostics.md` | none |
| 1 | P3-settings-contrast | `impl-plans/active/release-0-1-17-p3-settings-contrast.md` | none |
| 2 | P2-served-sandbox | `impl-plans/active/release-0-1-17-p2-served-sandbox.md` | P1 |
| 3 | P4-release-integration | `impl-plans/active/release-0-1-17-p4-release-integration.md` | P1, P2, P3 |

DAG: P1 -> P2 -> P4, and P3 -> P4. P3 never touches Swift.

Why the waves are ordered this way:

- P1 and P2 both edit the AppCore module, and AppGraphQL depends on AppCore. Running them in parallel could leave one waiting on the other's in-progress compile errors, so P2 runs after P1.
- The version bump includes `Sources/AppCore/Version.swift`, which is also AppCore, so it goes to P4 after all Swift work.
- P1 lands first because its sanitized diagnostics make P2's baseline live run show the real failure class.

## Shared-file ownership

Every file has exactly one writer per wave.

| file | wave 1 | wave 2 | wave 3 |
| --- | --- | --- | --- |
| `Sources/AppCore/AgentGatewayInvocationSanitization.swift` | P1 | - | P4 (repair only) |
| `Sources/AppCore/AgentGatewayCLIInvoker.swift` | P1 (no-reply branch only) | - | P4 (repair only) |
| `Sources/AppGraphQL/NoteGraphQLService.swift` | P1 | - | P4 (repair only) |
| `Sources/AppGraphQL/NoteGraphQLAgenticSearch.swift` (new) | P1 | - | P4 (repair only) |
| `Tests/AppCoreTests/AgentGatewayPublicDiagnosticTests.swift` (new) | P1 | - | P4 (repair only) |
| `Tests/AppGraphQLTests/AgenticSearchDiagnosticsGraphQLTests.swift` (new) | P1 | - | P4 (repair only) |
| `Sources/AppCore/AgentGatewayExecutionIsolation.swift` | - | P2 | P4 (repair only) |
| `Tests/AppCoreTests/AgentGatewayServedSandboxProfileTests.swift` (new) | - | P2 | P4 (repair only) |
| `Tests/AppGraphQLTests/LiveServedAgenticSearchTests.swift` (new) | - | P2 | P4 (repair only) |
| `design-docs/specs/ai-agent-integration.md` | - | P2 (conditional; AI13 adopted-allowance list only) | - |
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
- `design-docs/` files, except P2's conditional AI13 list edit
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
| `mise run lint` | pending | `tmp/release-0-1-17/P4/lint.log` |
| `bun test src` | pending | `tmp/release-0-1-17/P4/bun-test.log` |
| `vitest run` | pending | `tmp/release-0-1-17/P4/vitest.log` |
| `mise run web:check` | pending | `tmp/release-0-1-17/P4/web-check.log` |
| `mise run tauri:check` | pending | `tmp/release-0-1-17/P4/tauri-check.log` |
| `mise run search:test-live` | pending | `tmp/release-0-1-17/P4/search-live.log` |
| Version guard | pending | `tmp/release-0-1-17/P4/version.log` |
| Protected-path and local-path guards | pending | `tmp/release-0-1-17/P4/guard-*.log` |

## Progress Log

- 2026-10-05: Plans P1-P4 were created from the accepted AI13 and W16 design (Step 3 accept, comm-004276).
