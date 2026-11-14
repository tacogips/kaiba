# P1 Served agenticSearch diagnostics: sandbox-start classification, public reason, server log

**Status**: Completed. The source work is checkpointed in commit 0172b87. This run fixed the launcher fixture, replaced hook-rejected path literals in the two test files, and passed the focused verification. Accepted in session-279; P4's combined-tree gates and the session-281 adversarial review (comm-004342) accepted the release. Archived to `impl-plans/completed/` at Step 8 on 2026-10-06.
**planId**: P1-agentic-search-diagnostics
**Wave**: 1
**dependsOn**: none
**Design Reference**: `design-docs/specs/ai-agent-integration.md`:
- AI13: "Fixed served diagnostics", including the prefix-rule paragraph added on 2026-10-06; "Public reason mapping (AppCore)"; "agenticSearch surface"; "Placement (1000-line limit)"
- the GraphQL Surface Additions `agenticSearch` bullet
- Verification item 13: the classifier bullet, the macOS invoker-level bullet, the fixture-literal bullet, and the mapping and `agenticSearch` bullets

**Index**: `impl-plans/completed/release-0-1-17.md`

## Resume scope (read first)

Already implemented in 0172b87; do not redo, rewrite or reformat any of it:

- `servedNoReplyDiagnostic(exitCode:stderr:)` and `AgentInvocationError.publicDiagnostic` in `Sources/AppCore/AgentGatewayInvocationSanitization.swift`
- the one-call wiring at `Sources/AppCore/AgentGatewayCLIInvoker.swift:149`
- `Sources/AppGraphQL/NoteGraphQLAgenticSearch.swift` and the `agenticSearchFailureLog` property in `Sources/AppGraphQL/NoteGraphQLService.swift`
- both test classes

Previous result (session-278): the focused suites ran 47 XCTest cases, 46 passed and 1 failed. The failing test is `AgentGatewayPublicDiagnosticTests.testServedInvokerClassifiesSandboxExecStderrPrefix`. It got `agent-gateway produced no reply (exit 3)` and expected the sandbox-start reason.

Root cause (accepted at Step 3): the fixture, not the implementation.

- The invoker does capture stderr. `AgentGatewayCLIInvoker.run` collects it with `stderrCollector`, and line 149 passes `execution.stderr` to the classifier in served mode.
- Exit 3 is the fixture script's own status. So `/bin/sh` actually ran under the served profile, and the child, not the launcher, wrote `sandbox-exec: fake failure`.
- A child shell under the deny-default profile can print its own startup warnings first, for example a `getcwd` denial for the workspace's parent directories. The trimmed stderr then does not start with the prefix.
- AI13 deliberately limits the classifier to a prefix test on the whole trimmed stderr, because `sandbox-exec` writes its message before any child runs. Do not widen it.

Remaining tasks, in this order:

1. Rewrite the fixture and assertions of `testServedInvokerClassifiesSandboxExecStderrPrefix` as described under Tests.
2. Replace every machine-home-style path literal in the two P1 test files (see "Fixture literal rule").
3. Run the Verification commands and record positive counts in the Progress Log.

## Intent and context (unchanged from the original plan)

Before P1, a served `agenticSearch` failure reached the client only as `diagnostics: ["note operation failed"]`, and a `sandbox-exec` launch failure looked the same as any gateway crash.

After P1:

1. A served invocation that produced no reply, and whose trimmed stderr begins with `sandbox-exec:`, fails with `agent-gateway could not start inside the server sandbox (exit N)`. The stderr text is never copied.
2. `AgentInvocationError.publicDiagnostic` is an anchored allowlist.
3. When `agenticSearch` fails with an `AgentInvocationError`:
   - `result.diagnostics` holds exactly one public reason;
   - `result.status` is `"error"`, `accepted` is `false`, and the top-level status is `"failed"`.
4. Every `agenticSearch` failure writes exactly one line, `kaiba: agenticSearch failed: <public reason>`, through the injectable `agenticSearchFailureLog` sink.

## Contract pinned for P2 and P4 (unchanged; already in the code)

```swift
extension AgentGatewayCLIInvoker {
  static func servedNoReplyDiagnostic(exitCode: Int32, stderr: Data) -> String
}
public extension AgentInvocationError {
  var publicDiagnostic: String { get }
}
// GraphQLNoteGraphQLService
public var agenticSearchFailureLog: @Sendable (String) -> Void
```

The allowlist contains these exact strings. `N` must match `-?[0-9]{1,10}`, and the whole string must match:

- `agent-gateway request failed`
- `agent-gateway produced no reply (exit N)`
- `agent-gateway could not start inside the server sandbox (exit N)`
- `agent-gateway exited with status N`
- `agent-gateway invocation timed out`
- `agent-gateway output exceeds the 256 KiB process limit`
- `agent reply exceeds the 256 KiB or 256-chunk output limit`
- `server agent-gateway is unavailable`

Mapping: `.notConfigured` gives `agent runtime is not configured`, every `.unavailable` gives `agent runtime is unavailable`, and any other `.failed` gives `agent request failed`.

## Non-goals

- No edit to any Swift source file. The four P1 source files are read-only in this run (see sharedPaths).
- No widening of `servedNoReplyDiagnostic`. Do not scan later lines and do not use `contains`.
- No GraphQL SDL, status value, DTO or KaibaClient change. No local-mode diagnostic change.
- No sandbox profile or execution-context change; that is P2.
- No edit to `Tests/AppCoreTests/AgentGatewayCLIInvokerTests.swift` or `Tests/AppCoreTests/AgentGatewayServedSafetyTests.swift`.

## writePaths

- `Tests/AppCoreTests/AgentGatewayPublicDiagnosticTests.swift`
- `Tests/AppGraphQLTests/AgenticSearchDiagnosticsGraphQLTests.swift`
- `impl-plans/active/release-0-1-17-p1-agentic-search-diagnostics.md`
- `tmp/release-0-1-17/P1`

## sharedPaths (read-only)

- `Sources/AppCore/AgentGatewayInvocationSanitization.swift`
- `Sources/AppCore/AgentGatewayCLIInvoker.swift`
- `Sources/AppGraphQL/NoteGraphQLService.swift`
- `Sources/AppGraphQL/NoteGraphQLAgenticSearch.swift`
- `Sources/AppCore/AgentGatewayExecutionIsolation.swift`
- `Tests/AppCoreTests/AgentGatewayServedSafetyTests.swift`

## sharedPathNotes

- `Tests/AppCoreTests/AgentGatewayPublicDiagnosticTests.swift`:
  - Rewrite only `testServedInvokerClassifiesSandboxExecStderrPrefix` and its private script helper (if it needs a second parameter).
  - Replace the one machine-home-style literal in `testPublicDiagnosticRejectsUnknownAndMalformedMessages`.
  - Leave the other tests byte-identical.
- `Tests/AppGraphQLTests/AgenticSearchDiagnosticsGraphQLTests.swift`: replace the two machine-home-style literals in the provider-text test, one in the stub message and one in the `contains` assertion, with the same `/opt/example/x` placeholder. Change nothing else.
- `Sources/AppCore/AgentGatewayInvocationSanitization.swift`: read-only. If the rewritten fixture still fails, do not edit it. Record `blocked: classifier mismatch` with the sanitized failure message (no paths), and stop.
- `Sources/AppCore/AgentGatewayExecutionIsolation.swift`: read-only (P2 owns it). The rewritten test must not depend on the current non-realpath profile, because P2 changes it.
- `tmp/release-0-1-17/P1`: evidence logs, `hashes.txt` and `intent.md` only. Earlier logs from session-278 stay; write this run's logs under `tmp/release-0-1-17/P1/resume/`.

## artifactRoots

- `tmp/release-0-1-17/P1`

## Fixture literal rule

The repository pre-commit hook rejects staged text that contains any absolute path rooted in the macOS users directory, the Linux home directory, or the Nix store. P4's local-path guard also rejects real Homebrew keg paths and real-looking `sk-or-v1-` keys.

Use `/opt/example/...`, `/srv/example/...`, paths built at runtime, and `FIXTURE` tokens. After the edit, this check must print nothing. It uses character classes, so the command text does not contain the literals itself:

`grep -nE '/U[s]ers/|/h[o]me/|/n[i]x/store/' Tests/AppCoreTests/AgentGatewayPublicDiagnosticTests.swift Tests/AppGraphQLTests/AgenticSearchDiagnosticsGraphQLTests.swift`

## Tests (input or situation -> expected outcome)

The rewritten `testServedInvokerClassifiesSandboxExecStderrPrefix` is macOS-only and keeps its `#if os(macOS)` guard.

Fixture:

- The test writes an executable fake gateway script under `<currentDirectoryPath>/tmp/AppCoreTests/`. Its first line is `#!` followed by a runtime-built interpreter path in the same directory, `missing-interpreter-<UUID>`, which is never created.
- The rest of the script can be anything, for example `exit 0`.
- Set permissions to 0o755, following the existing private `makeExecutableGatewayScript` in the same file (which imitates `Tests/AppCoreTests/AgentGatewayServedSafetyTests.swift:135-143`).
- Do not write `sandbox-exec:` from the script. The launcher writes it: `execvp` fails and `sandbox-exec` prints `sandbox-exec: execvp() of '<script>' failed: ...`, usually exiting 71. Step 3 observed this with a nonexistent target.

Invoker: as before, `AgentGatewayCLIInvoker(commandPath: script.path, vendor: "openrouter", model: "test-model", apiKeyEnvironment: "PROVIDER_TOKEN", environment: ["PROVIDER_TOKEN": "FIXTURE-token"], executionMode: .served)`, then `invoke(...)` with purpose `.search`.

Expected outcomes:

- The call throws `AgentInvocationError.failed(message)`. If it does not throw, use `XCTFail`. If it throws a different case, fail with the case name only.
- `message` has the prefix `agent-gateway could not start inside the server sandbox (exit ` and the suffix `)`, and the middle is all digits with an optional leading `-`.
- Do not assert a fixed exit code such as 3 or 71.
- `AgentInvocationError.failed(message).publicDiagnostic == message`, so it passes the allowlist.
- `message` contains neither `script.path`, nor its last path component, nor `execvp`, `No such file` or `Operation not permitted`.
- Delete the script in a `defer`.

Other tests in this file and in `AgenticSearchDiagnosticsGraphQLTests.swift` are unchanged apart from the literal replacement. They must still pass:

- `.failed("/opt/example/bin/agent-gateway failed").publicDiagnostic` gives `agent request failed`.
- The stub that throws `.failed("provider said FIXTURE-SECRET at /opt/example/x")` gives diagnostics `["agent request failed"]`, and the captured log contains neither `FIXTURE-SECRET` nor `/opt/example`.

## Pitfalls

- Do not make the script echo the prefix, and do not add `exec 2>&-` or similar tricks. A child under the profile is not a launcher failure (AI13).
- Do not use a symlink-based denial to make `sandbox-exec` fail. P2 resolves the gateway with realpath, so such a test would start passing for the wrong reason, or failing, after P2.
- Do not hard-code the shebang's interpreter path as an absolute literal. Build it at runtime from the test directory.
- Do not print or assert the raw launcher text. The assertion message on failure may include `message` only, which is already one of the fixed strings or the generic `produced no reply` string.
- Do not touch source files. The classifier is correct per the Step 3 review.

## Verification

```bash
mkdir -p tmp/release-0-1-17/P1/resume
bash -c 'PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter "AgentGatewayPublicDiagnosticTests|AgenticSearchDiagnosticsGraphQLTests|AgentGatewayCLIInvokerTests|AgentGatewayServedSafetyTests|NoteGraphQLSchemaInventoryTests|GraphQLIntrospectionTests" 2>&1 | tee tmp/release-0-1-17/P1/resume/swift-test.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run lint 2>&1 | tee tmp/release-0-1-17/P1/resume/lint.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'if [ -s tmp/release-0-1-17/P1/resume/changed-swift-files.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/release-0-1-17/P1/resume/changed-swift-files.nul 2>&1 | tee tmp/release-0-1-17/P1/resume/swiftlint-changed.log; code=${PIPESTATUS[0]}; else printf "%s\n" "No Swift files changed; selected-file SwiftLint not run."; code=0; fi; echo exit=$code; exit $code'
bash -c 'grep -nE "/U[s]ers/|/h[o]me/|/n[i]x/store/" Tests/AppCoreTests/AgentGatewayPublicDiagnosticTests.swift Tests/AppGraphQLTests/AgenticSearchDiagnosticsGraphQLTests.swift impl-plans/active/release-0-1-17-p1-agentic-search-diagnostics.md | tee tmp/release-0-1-17/P1/resume/guard-literals.log; test ! -s tmp/release-0-1-17/P1/resume/guard-literals.log'
bash -c 'git diff --name-only -- Sources | tee tmp/release-0-1-17/P1/resume/guard-sources.log; test ! -s tmp/release-0-1-17/P1/resume/guard-sources.log'
bash -c 'wc -l Tests/AppCoreTests/AgentGatewayPublicDiagnosticTests.swift Tests/AppGraphQLTests/AgenticSearchDiagnosticsGraphQLTests.swift | tee tmp/release-0-1-17/P1/resume/wc.log'
```

Expected evidence:

- `swift-test.log`: exit 0, and the XCTest line `Executed N tests, with 0 failures` with N > 0. Record N; the previous run selected 47. The log must show `testServedInvokerClassifiesSandboxExecStderrPrefix` passed. Swift-testing counts for this filter may be 0 and are not counted.
- `lint.log`: exit 0, with no serious violation in the two test files.
- `guard-literals.log` and `guard-sources.log` are empty, and both guards exit 0.
- Both test files are under 1000 lines.

## Done criteria

- [x] `publicDiagnostic` and `servedNoReplyDiagnostic` exist with the pinned signatures and exact strings (0172b87).
- [x] `agenticSearch` lives in `Sources/AppGraphQL/NoteGraphQLAgenticSearch.swift`, and the diagnostics and log line follow AI13 (0172b87).
- [x] `testServedInvokerClassifiesSandboxExecStderrPrefix` uses the missing-interpreter launcher fixture and passes. The focused suites exit 0 with XCTest N > 0 and 0 failures.
- [x] No machine-home-style or Nix-store path literal remains in the two test files or in this plan file (`guard-literals.log` is empty).
- [x] No `Sources/` file is changed in this run (`guard-sources.log` is empty). Strict changed-file SwiftLint and `mise run lint` exit 0.
- [x] The Progress Log records commands, exit codes, counts and log paths. Status is Completed.

## Progress Log

- 2026-10-05: Plan created.
- 2026-10-05: Implemented the public diagnostic allowlist and the served no-reply classifier in `Sources/AppCore/AgentGatewayInvocationSanitization.swift`, wired the served invoker, moved `agenticSearch` into `Sources/AppGraphQL/NoteGraphQLAgenticSearch.swift`, and added the injectable failure log and both XCTest classes.
- 2026-10-05: `mise run build` exited 0 (`tmp/release-0-1-17/P1/build-final.log`).
- 2026-10-05: The focused `swift test` exited 1: 47 XCTest cases, 46 passed and 1 failed (`testServedInvokerClassifiesSandboxExecStderrPrefix`, which got the no-reply string with exit 3). Logs: `tmp/release-0-1-17/P1/swift-test-rerun.log` and `tmp/release-0-1-17/P1/swift-test-isolated.log`. These also passed: `AgenticSearchDiagnosticsGraphQLTests` 6/6, `AgentGatewayCLIInvokerTests` 25/25, served safety 3/3, GraphQL introspection 7/7 and schema inventory 1/1.
- 2026-10-05: Strict lint of the changed files exited 0 (`tmp/release-0-1-17/P1/swiftlint-changed.log`). `mise run lint` exited 0 (`tmp/release-0-1-17/P1/lint.log`). The move guard was empty. All six Swift files are under 1000 lines, and `AgentGatewayCLIInvoker.swift` has 984 (`tmp/release-0-1-17/P1/wc-final.log`).
- 2026-10-06: Resume plan revised at Step 4 (session-279). The root cause is the fixture: a child shell under the profile, not a launcher failure. Remaining work: the missing-interpreter fixture, the literal replacement, and re-verification.
- 2026-10-06: Replaced the child-shell fixture in `testServedInvokerClassifiesSandboxExecStderrPrefix` with an executable whose runtime-built `#!` interpreter is missing. The test passed without depending on the launcher exit code and checked only the sanitized template and that launcher details were absent. Replaced machine-home-style fixture paths with `/opt/example` in both P1 test files. No production source changed.
- 2026-10-06: Focused command `PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter "AgentGatewayPublicDiagnosticTests|AgenticSearchDiagnosticsGraphQLTests|AgentGatewayCLIInvokerTests|AgentGatewayServedSafetyTests|NoteGraphQLSchemaInventoryTests|GraphQLIntrospectionTests"` exited 0: 47 XCTest tests, 47 passed, 0 failures; the launcher fixture passed. Complete log: `tmp/release-0-1-17/P1/resume/swift-test.log`.
- 2026-10-06: `xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/release-0-1-17/P1/resume/changed-swift-files.nul` exited 0 (log `tmp/release-0-1-17/P1/resume/swiftlint-changed.log`). `mise run lint` exited 0; it reported 3 non-serious violations across the repository and 0 serious violations (log `tmp/release-0-1-17/P1/resume/lint.log`).
- 2026-10-06: The literal guard and source-change guard exited 0 with empty logs (`tmp/release-0-1-17/P1/resume/guard-literals.log`, `tmp/release-0-1-17/P1/resume/guard-sources.log`). Both test files are under 1000 lines: 123 and 145 (`tmp/release-0-1-17/P1/resume/wc.log`). Strict lint used the NUL-delimited changed-file manifest `tmp/release-0-1-17/P1/resume/changed-swift-files.nul`.
- 2026-10-06: After the final plan edit, the literal guard and Sources diff guard exited 0 with empty logs (`tmp/release-0-1-17/P1/resume/guard-literals-final.log`, `tmp/release-0-1-17/P1/resume/guard-sources-final.log`); `git diff --check` exited 0.
