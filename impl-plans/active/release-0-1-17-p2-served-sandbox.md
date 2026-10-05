# P2 Served sandbox root-cause fix and live agenticSearch proof

**Status**: Implemented in c35c0a3. Session-281 verifies it and accepts it against the amended gate (operator decision of 2026-10-06).
**planId**: P2-served-sandbox
**Wave**: 1 (session-281). P1 and P3 are accepted dependencies.
**dependsOn**: P1-agentic-search-diagnostics (accepted in session-279). Both plans build in AppCore, and P1's sanitized diagnostics make a failing live run informative.
**Design Reference**: `design-docs/specs/ai-agent-integration.md`: the Runtime and Provider Adapter Boundary paragraph, AI13 ("Executable resolution", "Profile additions", "What does not change", and "Diagnosis gate" as revised on 2026-10-06), and Verification item 13 (bullets 1-3 and the live test). Decision source (read-only): `design-docs/user-qa/ai-agent-runtime-and-ui.md`, "Served sandbox: residual non-fatal denials (decided 2026-10-06)".
**Index**: `impl-plans/active/release-0-1-17.md`

## Amended gate (session-281, read first)

In session-279 this plan was implemented, and its live test passed. It stopped as blocked only because the old gate required a Sandbox log with no gateway denial, and about 51 non-fatal denials remained. The operator then decided:

- **Keep the residual denials denied.** Add no sandbox allowance in this run, including none of the three AI13 bounded escalations. `file-read-metadata` is already adopted and stays as it is.
- **Accept P2** when:
  - the live, env-gated served `agenticSearch` test passes (exit 0, XCTest `Executed N tests, with 0 failures`, N > 0); and
  - no denial is fatal. A denial counts as fatal only if the live test fails because of it.
- **A clean Sandbox log is not required.** Instead, record the residual denial operation classes with counts, plus their path or service classes, for the passing run's time window.

This run therefore has no feature work. It re-runs the gates on the committed code, captures the residual-denial evidence for one bounded window, and records acceptance. A source edit is allowed only to repair a failing gate in P2's own files, and it must never add or widen an `(allow ...)` rule.

## Intent and context

Served `agenticSearch` used to fail under `/usr/bin/sandbox-exec` with backend `agent-gateway-cli`, provider `openrouter` and model `openai/gpt-5-mini`. Commit c35c0a3 contains the fix:

- `AgentGatewayCLIInvoker.executionContext(mode: .served, ...)` (`Sources/AppCore/AgentGatewayExecutionIsolation.swift`) resolves the gateway with `realpath(3)` before it creates the workspace. It uses the physical path both as the profile literal and as the `sandbox-exec` target.
- `servedSandboxProfile(binary:workspace:)` grants:
  - `file-read*` on the physical binary literal;
  - the system read subpaths, including `/private/etc`;
  - global `file-read-metadata`;
  - `/private/var/run/resolv.conf`;
  - five `mach-lookup` global-names (`com.apple.trustd`, `com.apple.SecurityServer`, `com.apple.SystemConfiguration.configd`, `com.apple.networkd`, `com.apple.dnssd.service`);
  - `file-write*` only on the workspace subpath and `/dev/null`;
  - `network-outbound`.
- `Tests/AppCoreTests/AgentGatewayServedSandboxProfileTests.swift` covers the profile, the environment, a missing binary and a symlink.
- `Tests/AppGraphQLTests/LiveServedAgenticSearchTests.swift` is the env-gated live test (`KAIBA_LIVE_AGENT_GATEWAY=1` plus a non-empty `OPENROUTER_API_KEY`).

## Non-goals and invariants (must stay true)

- No new or widened `(allow ...)` rule in `servedSandboxProfile`. The residual denial classes (`file-read-data`, `file-read-xattr`, `file-write-*` outside the workspace, `mach-lookup`, `system-socket`, `user-preference-read`) stay denied.
- Do not add the AI13 bounded escalations (`file-lock`, dylib literals) in this run.
- `(deny default)` stays first after `(version 1)`, and `(import "system.sb")` stays. Writes stay limited to the workspace subpath and `/dev/null`. There is no `subpath` read of the gateway directory, the symlink directory or the keg.
- No new environment keys, and `servedReservedEnvironmentKeys` is unchanged. Tool-capable vendors stay refused in served mode, and Linux stays fail-closed.
- Do not edit `design-docs/`. The 2026-10-06 AI13 revision is committed with this plan before fanout. `design-docs/user-qa/ai-agent-runtime-and-ui.md` is read-only.
- Do not edit the dispatch manifest (`impl-plans/active/release-0-1-17-dispatch.json`) or any other plan file.
- Do not edit P1's files (`AgentGatewayInvocationSanitization.swift`, `AgentGatewayCLIInvoker.swift`, `NoteGraphQLService.swift`, `NoteGraphQLAgenticSearch.swift`, and the two P1 test files), or `AgentGatewaySubscription.swift` and `ClaudeSubscriptionExecution.swift`.
- Never print `OPENROUTER_API_KEY`. Never copy a machine-local absolute path (home directory, Homebrew keg path) into this plan file. Describe paths by class instead.

## writePaths

- `Sources/AppCore/AgentGatewayExecutionIsolation.swift` (repair only, with no allowance change)
- `Tests/AppCoreTests/AgentGatewayServedSandboxProfileTests.swift` (repair only)
- `Tests/AppGraphQLTests/LiveServedAgenticSearchTests.swift` (repair only)
- `impl-plans/active/release-0-1-17-p2-served-sandbox.md` (Status, Done criteria and Progress Log only)
- `tmp/release-0-1-17/P2`

## sharedPaths (read-only)

- `Sources/AppCore/AgentGatewayCLIInvoker.swift`
- `Sources/AppCore/AgentGatewayInvocationSanitization.swift`
- `Sources/AppCore/AgentGatewaySubscription.swift`
- `Sources/AppCore/ClaudeSubscriptionExecution.swift`
- `Sources/AppGraphQL/NoteGraphQLAgenticSearch.swift`
- `Tests/AppCoreTests/AgentGatewayCLIInvokerTests.swift`
- `Tests/AppCoreTests/AgentGatewayPublicDiagnosticTests.swift`
- `design-docs/specs/ai-agent-integration.md`
- `design-docs/user-qa/ai-agent-runtime-and-ui.md`

## sharedPathNotes

- `Sources/AppCore/AgentGatewayExecutionIsolation.swift`: expected unchanged. Edit it only if build, lint or the focused suite fails because of this file. Any edit must leave the set of `(allow` lines identical to c35c0a3, which `guard-allowances.log` checks.
- `Tests/AppCoreTests/AgentGatewayServedSandboxProfileTests.swift` and `Tests/AppGraphQLTests/LiveServedAgenticSearchTests.swift`: expected unchanged. Repair only for a failing gate. Never weaken an assertion, never add a skip, and never turn the live test's nil-invoker `XCTFail` into a skip.
- `design-docs/specs/ai-agent-integration.md`: read-only in this run. `design-diff.log` must be empty.
- `tmp/release-0-1-17/P2`: this run writes only under `tmp/release-0-1-17/P2/accept/`. The session-279 logs at the top level are history, not this run's evidence.

## artifactRoots

- `tmp/release-0-1-17/P2`

## Task order

1. Write `tmp/release-0-1-17/P2/accept/intent.md`, an immutable snapshot of this run's intent: verify and accept with no allowance change. Follow the index Edit protocol for any repair (record pre/post hashes in `tmp/release-0-1-17/P2/accept/hashes.txt`).
2. Run the key presence check, build and the focused unit suite (commands below).
3. Run the bounded live window:
   1. record the window start timestamp;
   2. run the live test;
   3. wait 5 seconds;
   4. capture the Sandbox log from the recorded start.

   Use one window per live attempt. Number retried attempts (`live-2.log`, `sandbox-window-2.log` and so on), and base the evidence on the passing attempt.
4. Derive the denial class counts from that window's log (command C1), and record them in the Progress Log.
5. Run lint, the line counts and the guards.
6. Update Status, Done criteria and the Progress Log.

Failure handling:

- **Live test fails with a provider or network diagnostic** (for example `agent-gateway request failed`, `agent-gateway exited with status N`, or a timeout) **and the window shows no new denial class compared with the residual set above.** Retry at most twice more, each in a new window. If all three attempts fail, set Status to `blocked: live provider failure` with the sanitized diagnostics. Never report it as passed.
- **Live test fails and the window shows a denial class outside the residual set, or the diagnostic is `agent-gateway could not start inside the server sandbox (exit N)`.** Set Status to `blocked: fatal sandbox denial <operation class> <path or service class>`, and stop. Do not add an allowance. Under AI13, this reopens the gate for an operator decision.
- **`OPENROUTER_API_KEY` is absent.** Set Status to `blocked: OPENROUTER_API_KEY absent`.
- **`log show` itself fails** (permission or tool error). Record `blocked: <exact error>` for the denial evidence. P2 is then not accepted, because the residual-denial record is a required signal.
- **Build or lint fails because of a peer's in-progress file.** This is not a blocker. Rerun after the peer lands, and leave cross-plan fixes to P4.

## Tests (input or situation -> expected outcome)

No new tests. The existing tests must pass unchanged:

- `AgentGatewayServedSandboxProfileTests`:
  - symlinked gateway -> the context launches `realpath` of the script;
  - the profile has the physical literal, no symlink path and no parent `subpath`;
  - it contains `/private/etc`, `resolv.conf`, the five global-names and `(allow file-read-metadata)`;
  - it has exactly one `(allow file-write*` rule, and that rule names the workspace;
  - the environment keys are exactly HOME, TMPDIR, XDG_CONFIG_HOME, XDG_CACHE_HOME, the credential, PATH and LANG;
  - a missing binary -> `unavailable`;
  - a served invoke of a symlinked script returns its reply.
- `AgentGatewayCLIInvokerTests`, `AgentGatewayServedSafetyTests`, `AgentGatewaySubscriptionTests`, `ClaudeSubscriptionExecutionTests`, `DocumentGatewayIsolationTests` and `AgentGatewayPublicDiagnosticTests` (including `testServedInvokerClassifiesSandboxExecStderrPrefix`) -> pass.
- `LiveServedAgenticSearchTests` with the gate on -> top-level `status` is `ok` and `answerMarkdown`, trimmed, is non-empty.

## Commands

Run from the repository root, in the foreground. Each command tees a complete log and prints its exit status.

```bash
mkdir -p tmp/release-0-1-17/P2/accept
bash -c 'test -n "$OPENROUTER_API_KEY" && echo present || echo absent' | tee tmp/release-0-1-17/P2/accept/key-presence.log
bash -c 'mise run build 2>&1 | tee tmp/release-0-1-17/P2/accept/build.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter "AgentGatewayServedSandboxProfileTests|AgentGatewayCLIInvokerTests|AgentGatewayServedSafetyTests|AgentGatewaySubscriptionTests|ClaudeSubscriptionExecutionTests|DocumentGatewayIsolationTests|AgentGatewayPublicDiagnosticTests" 2>&1 | tee tmp/release-0-1-17/P2/accept/swift-test.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
# W0 window start, L1 live test, D1 bounded Sandbox capture (same window)
bash -c 'date "+%Y-%m-%d %H:%M:%S" | tee tmp/release-0-1-17/P2/accept/live-window-start.txt'
bash -c 'KAIBA_LIVE_AGENT_GATEWAY=1 PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter LiveServedAgenticSearchTests 2>&1 | tee tmp/release-0-1-17/P2/accept/live.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'sleep 5; log show --start "$(cat tmp/release-0-1-17/P2/accept/live-window-start.txt)" --style compact --predicate "sender == \"Sandbox\" AND eventMessage CONTAINS \"agent-gateway\"" 2>&1 | tee tmp/release-0-1-17/P2/accept/sandbox-window.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
# C1 residual denial classes: distinct reports by operation class, then duplicate-report line count
bash -c 'grep -v "duplicate report" tmp/release-0-1-17/P2/accept/sandbox-window.log | grep -oE "agent-gateway\([0-9]+\) deny\([0-9]+\) [a-z*-]+" | sed -E "s/^agent-gateway\([0-9]+\) deny\([0-9]+\) //" | sort | uniq -c | tee tmp/release-0-1-17/P2/accept/sandbox-denial-classes.log; echo duplicate-report-lines=$(grep -c "duplicate report" tmp/release-0-1-17/P2/accept/sandbox-window.log) | tee -a tmp/release-0-1-17/P2/accept/sandbox-denial-classes.log'
bash -c 'mise run lint 2>&1 | tee tmp/release-0-1-17/P2/accept/lint.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'wc -l Sources/AppCore/AgentGatewayExecutionIsolation.swift Tests/AppCoreTests/AgentGatewayServedSandboxProfileTests.swift Tests/AppGraphQLTests/LiveServedAgenticSearchTests.swift | tee tmp/release-0-1-17/P2/accept/wc.log'
bash -c 'git diff -- design-docs impl-plans/active/release-0-1-17-dispatch.json | tee tmp/release-0-1-17/P2/accept/design-diff.log; test ! -s tmp/release-0-1-17/P2/accept/design-diff.log'
bash -c 'git diff c35c0a3 -- Sources/AppCore/AgentGatewayExecutionIsolation.swift | grep -E "^[-+].*\(allow" | tee tmp/release-0-1-17/P2/accept/guard-allowances.log; test ! -s tmp/release-0-1-17/P2/accept/guard-allowances.log'
bash -c 'grep -nE "/U[s]ers/|/h[o]me/|/n[i]x/store/|/opt/homebrew/C[e]llar" Sources/AppCore/AgentGatewayExecutionIsolation.swift Tests/AppCoreTests/AgentGatewayServedSandboxProfileTests.swift Tests/AppGraphQLTests/LiveServedAgenticSearchTests.swift impl-plans/active/release-0-1-17-p2-served-sandbox.md | tee tmp/release-0-1-17/P2/accept/guard-literals.log; test ! -s tmp/release-0-1-17/P2/accept/guard-literals.log'
```

Expected evidence:

- `key-presence.log` reads `present`.
- `build.log`: exit 0.
- `swift-test.log`: exit 0, with XCTest `Executed N tests, with 0 failures` where N > 0. Record N and the number of credential-gated skips. Skips are listed, not counted.
- `live.log` (or the numbered passing attempt): exit 0 and XCTest `Executed N tests, with 0 failures` where N > 0 for `LiveServedAgenticSearchTests`. The swift-testing `0 tests` line is not counted. A skip message or `Executed 0 tests` is a failed gate.
- `sandbox-window.log`: exit 0, covering the same window as the passing live run.
- `sandbox-denial-classes.log`: one `count class` line per operation class, plus `duplicate-report-lines=K`.
  - Record the classes and counts in the Progress Log, with path or service classes described generically (for example "user preference domain", "gateway keg directory", "HTTP storage", "distributed notification service").
  - An empty class list is also valid; record it as `0 residual denials`.
  - `file-read-metadata` is allowed globally, so its expected count is 0. Report a non-zero count as a finding in the Progress Log.
  - A class outside the residual set is reported explicitly. It is not fatal if the live run passed.
- `lint.log`: exit 0. `wc.log`: each file is under 1000 lines.
- `design-diff.log`, `guard-allowances.log` and `guard-literals.log` are empty, and each guard exits 0.

## Done criteria

- [ ] `live.log` (or the numbered passing attempt) exits 0 with XCTest Executed N > 0 and 0 failures, with status `ok` and a non-empty answer.
- [ ] `sandbox-window.log` covers that passing window. `sandbox-denial-classes.log` records the residual classes and counts, and the Progress Log copies them with generic path or service classes. No denial was fatal.
- [ ] The focused unit suite, build and lint exit 0, with XCTest N > 0 for the unit suite.
- [ ] `guard-allowances.log`, `design-diff.log` and `guard-literals.log` are empty. No sandbox allowance was added or widened.
- [ ] Status reads `Completed (accepted under the 2026-10-06 operator decision)`, or `blocked: <sanitized reason>`.

## Progress Log

- 2026-10-05: Plan created.
- 2026-10-06: Resume notes added at Step 4 (session-279): P1 fixture compatibility, stderr-agnostic behavioral assertions, and the literal guard. Not started.
- 2026-10-06: Implemented P2 (session-279):
  - The served context now resolves the gateway with `realpath(3)` before it creates the workspace. It uses only the physical executable as the literal and the target, and grants `/private/etc`, the resolver literal and the five approved TLS/DNS mach lookups.
  - The existing environment and write boundary are preserved.
  - Added three sandbox profile tests and the env-gated GraphQL live test.
- Baseline (session-279):
  - The `OPENROUTER_API_KEY` presence check printed `present`.
  - The live test exited 1 (`live-baseline.log`): XCTest Executed 1, with 2 assertion failures. The sanitized result was `agent-gateway produced no reply (exit 1)`.
  - `sandbox-baseline.log` captured denials for these path classes:
    - the gateway executable, keg and symlink;
    - user-home preferences and cache;
    - an OS network preference;
    - an unapproved mach service;
    - an OS temporary cache path.
- Bounded escalation (session-279):
  - After the planned realpath and profile rules, the live test still failed, and D1 confirmed a `file-read-metadata` denial.
  - Only the global `file-read-metadata` allowance was adopted. It is asserted in `AgentGatewayServedSandboxProfileTests` and documented in AI13.
  - The live test then returned status `ok` with a non-empty answer (`live-final-post-lintfix.log`: exit 0, XCTest Executed 1, 0 failures).
- Final D1 (session-279):
  - `sandbox-final-post-lintfix.log` still contained 51 denial events for the gateway process: `file-read-data` 18, `file-read-xattr` 4, `file-write-create` 3, `file-write-mode` 1, `file-write-unlink` 1, `mach-lookup` 5, `system-socket` 2 and `user-preference-read` 17.
  - No further allowance was added, and the plan was blocked for a user decision.
  - That capture used `--last 10m`, so it overlapped earlier attempts. Session-281 re-captures one bounded window.
- Final verification (session-279):
  - `mise run build`: exit 0.
  - Focused Swift filter: exit 0, XCTest Executed 45, 0 failures, 2 credential-gated skips.
  - Live filter: exit 0, XCTest Executed 1, 0 failures.
  - `mise run lint`: exit 0.
  - Touched Swift files have 230, 137 and 68 lines.
  - `guard-literals.log` is empty.
- 2026-10-06: Session-281 plan checkpoint:
  - The operator decision of 2026-10-06 replaces the clean-log gate (AI13 "Diagnosis gate" revised).
  - P2 is now verify-and-accept only, with no allowance change, and its evidence goes to `tmp/release-0-1-17/P2/accept/`.
  - Not yet run.
