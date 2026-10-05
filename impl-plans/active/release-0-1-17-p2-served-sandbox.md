# P2 Served sandbox root-cause fix and live agenticSearch proof

**Status**: Planned.
**planId**: P2-served-sandbox
**Wave**: 2
**dependsOn**: P1-agentic-search-diagnostics. Both plans edit the AppCore module, and P1's sanitized diagnostics make the baseline live run informative.
**Design Reference**: `design-docs/specs/ai-agent-integration.md`: the Runtime and Provider Adapter Boundary paragraph, and AI13 ("Executable resolution", "Profile additions", "What does not change", "Diagnosis gate"), and Verification item 13 (bullets 1-3 and the live test)
**Index**: `impl-plans/active/release-0-1-17.md`

## Intent and context

Served `agenticSearch` with backend `agent-gateway-cli`, provider `openrouter` and model `openai/gpt-5-mini` fails under `/usr/bin/sandbox-exec`, while the unsandboxed `kaiba ai search` succeeds with the same configuration.

`AgentGatewayCLIInvoker.servedSandboxProfile(binary:workspace:)` (`Sources/AppCore/AgentGatewayExecutionIsolation.swift:193-211`) has three gaps:

- It grants `file-read*` on the literal `URL(fileURLWithPath: binary).standardizedFileURL.path`. That path is not symlink-resolved. A Homebrew `bin/agent-gateway` is a symlink into the formula keg, and Seatbelt matches the physical path.
- It grants `(subpath "/etc")`, but `/etc` is a symlink to `/private/etc`, so TLS certificates, `hosts` and `resolv.conf` are unreadable.
- It has no `mach-lookup` rules for TLS trust (`trustd`, `SecurityServer`) or DNS and network configuration (`dnssd`, `configd`, `networkd`).

The server subscription profiles already add exactly these rules and work: `Sources/AppCore/AgentGatewaySubscription.swift:88-93` and `Sources/AppCore/ClaudeSubscriptionExecution.swift:35,49-55`.

After this plan:

1. In served mode, `executionContext(mode: .served, ...)` resolves the gateway with Darwin `realpath(3)` before it creates the workspace. It passes the physical path both to `servedSandboxProfile` and as the `sandbox-exec` target argument.
2. `servedSandboxProfile` additionally contains:
   - `(allow file-read* (subpath "/private/etc") (literal "/private/var/run/resolv.conf"))`
   - `(allow mach-lookup (global-name "com.apple.trustd") (global-name "com.apple.SecurityServer") (global-name "com.apple.SystemConfiguration.configd") (global-name "com.apple.networkd") (global-name "com.apple.dnssd.service"))`
3. A live, env-gated test proves that served `agenticSearch` returns `status ok` with a non-empty answer.

## Non-goals and invariants (must stay true)

These must stay true:

- `(deny default)` stays first after `(version 1)`. `(import "system.sb")` stays.
- Writes are allowed only inside the workspace subpath plus the `/dev/null` literal.
- No `subpath` read of the gateway's directory, the configured symlink's directory, or the keg.
- No new environment keys, and the reserved-key set (`servedReservedEnvironmentKeys`) is unchanged. `HOME`, `TMPDIR` and `XDG_*` stay inside the workspace.
- Tool-capable vendors (`claude-code`, `codex`, `cursor`) are still refused in served mode.
- Linux still fails closed; the non-macOS branch is unchanged.

Out of scope:

- Do not edit `AgentGatewaySubscription.swift` or `ClaudeSubscriptionExecution.swift`. Their appended rules become harmless duplicates; do not clean them up.
- Do not edit P1's files (`AgentGatewayInvocationSanitization.swift`, `AgentGatewayCLIInvoker.swift`, `NoteGraphQLService.swift`, `NoteGraphQLAgenticSearch.swift`).
- Do not use `URL.resolvingSymlinksInPath()` for the binary. It can rewrite `/private/var` to `/var`, and the physical path is required. Use the `realpath` + `free` idiom of `AgentGatewayExecutionIsolation.swift:72-77`.

## writePaths

- `Sources/AppCore/AgentGatewayExecutionIsolation.swift`
- `Tests/AppCoreTests/AgentGatewayServedSandboxProfileTests.swift`
- `Tests/AppGraphQLTests/LiveServedAgenticSearchTests.swift`
- `design-docs/specs/ai-agent-integration.md`
- `impl-plans/active/release-0-1-17-p2-served-sandbox.md`
- `tmp/release-0-1-17/P2`

## sharedPaths (read-only)

- `Sources/AppCore/AgentGatewayCLIInvoker.swift`
- `Sources/AppCore/AgentGatewayInvocationSanitization.swift`
- `Sources/AppCore/AgentGatewaySubscription.swift`
- `Sources/AppCore/ClaudeSubscriptionExecution.swift`
- `Sources/AppCore/AgentInvoking.swift`
- `Sources/AppGraphQL/NoteGraphQLAgenticSearch.swift`
- `Tests/AppCoreTests/AgentGatewayCLIInvokerTests.swift`
- `Tests/AppCoreTests/AgentGatewaySubscriptionTests.swift`
- `Tests/AppCoreTests/ClaudeSubscriptionExecutionTests.swift`

## sharedPathNotes

- `Sources/AppCore/AgentGatewayExecutionIsolation.swift`:
  - In the served branch of `executionContext`, resolve the binary with `realpath` before any workspace is created.
  - If resolution fails, throw `AgentInvocationError.unavailable("server agent-gateway executable is unavailable")`. The invoker sanitizes it to `server agent-gateway is unavailable`, and P1 maps it to `agent runtime is unavailable`.
  - Use the physical path for `servedSandboxProfile(binary:workspace:)` and as `arguments[2]` (`["-p", profile, physicalBinary] + arguments`).
  - Add the two rule lines inside `servedSandboxProfile`, after the existing read rules and before the write rule.
  - Change nothing else in the file.
- `design-docs/specs/ai-agent-integration.md`: conditional edit. Only if the diagnosis gate forces one of the three bounded extra allowances, append it to the AI13 "Profile additions" list in one line with its reason. If no extra allowance is adopted, leave the file untouched.
- `Tests/AppCoreTests/AgentGatewayCLIInvokerTests.swift`: read-only. `testServedInvokerUsesIsolatedWorkspaceAndAllowlistedEnvironment` (lines 247-315) must keep passing unchanged. It is the guard against sibling reads and external writes.
- `Tests/AppCoreTests/AgentGatewaySubscriptionTests.swift` and `ClaudeSubscriptionExecutionTests.swift`: read-only; they must keep passing.
- `Sources/AppGraphQL/NoteGraphQLAgenticSearch.swift`: read-only (P1). The live test calls `agenticSearch` through the executor.
- `tmp/release-0-1-17/P2`: evidence logs, `hashes.txt`, `intent.md` and sandbox log captures only.

## artifactRoots

- `tmp/release-0-1-17/P2`

## Task order

1. **Baseline diagnosis**, before any source edit, after P1 has landed:
   - Write the live test file first; it is test-only.
   - Run it with the gate on (command L1 below). It is expected to fail. Record the sanitized diagnostics that the test prints, for example `agent-gateway could not start inside the server sandbox (exit N)` or `agent-gateway request failed`.
   - Capture the Sandbox violation log (command D1) for the same time window.
   - In the Progress Log, record only the denied operation names (for example `file-read-data`, `mach-lookup`) and path classes (for example "gateway keg executable", "/private/etc"). No secrets and no machine-local absolute paths.
2. **Fix**: make the `AgentGatewayExecutionIsolation.swift` changes described above.
3. **Unit tests**: write `AgentGatewayServedSandboxProfileTests.swift`.
4. **Re-verify**:
   - Rerun the live test. It must pass with XCTest `Executed N tests` and N > 0.
   - Rerun D1. It must show no denial for the gateway process during the passing run.
5. **Bounded escalation**, only if step 4 still fails or shows gateway denials. You may add only these, each confirmed by a D1 denial:
   - a global `(allow file-read-metadata)`;
   - `(allow file-lock (subpath <workspace>))`;
   - individual `file-read*` literals for dylibs that `otool -L <physical gateway>` reports outside `/System` and `/usr/lib`. Do not add a `subpath`; compute these at runtime only if the dylib set is genuinely required.

   Record each adopted allowance in the AI13 list (see sharedPathNotes) and add an assertion for it in the profile test. If any other allowance would be needed, stop: record `blocked: needs user decision` with the exact denial class in the Progress Log, and do not widen further. P4 and the user then decide through `design-docs/user-qa/ai-agent-runtime-and-ui.md`.

## Tests (input or situation -> expected outcome)

`Tests/AppCoreTests/AgentGatewayServedSandboxProfileTests.swift` (new, XCTest). Each test that needs the macOS sandbox guards with `#if os(macOS)` and throws `XCTSkip` otherwise.

Setup for the symlink cases: a real script lives at `tmp/AppCoreTests/sandbox-real-<uuid>/gateway.sh`, and a symlink at `tmp/AppCoreTests/sandbox-link-<uuid>/agent-gateway` points to it. Both paths are under the current directory, as in `makeExecutableGatewayScript` at `Tests/AppCoreTests/AgentGatewayServedSafetyTests.swift:135-143`.

- `executionContext(mode: .served, vendor: "openrouter", binary: <symlink>, arguments: ["client"], environment: ["PROVIDER_TOKEN": "t", "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"], apiKeyEnvironment: "PROVIDER_TOKEN")`:
  - `context.binary == "/usr/bin/sandbox-exec"`;
  - `context.arguments[0] == "-p"`;
  - `context.arguments[2]` equals `realpath(<real script>)`;
  - `context.arguments[1]` (the profile) contains `(literal "<physical script path>")` and does not contain the symlink path;
  - the profile does not contain `(subpath "<physical script directory>")` or `(subpath "<symlink directory>")`.
  - Call `cleanUp()` in a `defer`.
- The same context's profile:
  - contains `(subpath "/private/etc")`, `(literal "/private/var/run/resolv.conf")` and each of the five `global-name` entries;
  - starts with `(version 1)` followed by `(deny default)`;
  - its only `file-write*` rule names the workspace subpath and `/dev/null`. Assert that the profile has exactly one `(allow file-write*` occurrence and that it contains `context.workspace!.path`.
- The same context's environment:
  - the keys are exactly `{HOME, TMPDIR, XDG_CONFIG_HOME, XDG_CACHE_HOME, PROVIDER_TOKEN, PATH, LANG}`;
  - `HOME` and `TMPDIR` equal the workspace path, and both `XDG_*` values have the workspace path as a prefix;
  - there is no `LC_ALL` because it was not provided.
- A binary path that does not exist (`tmp/AppCoreTests/missing-<uuid>/agent-gateway`) -> `executionContext(mode: .served, ...)` throws `AgentInvocationError.unavailable`. Do not assert on the shared temporary directory's contents; parallel tests make that flaky. Resolving before creating the workspace is a code-review point, not a test.
- Behavioral: a served `AgentGatewayCLIInvoker` with `commandPath: <symlink>`, vendor `openrouter` and `apiKeyEnvironment: "PROVIDER_TOKEN"`. The script reads stdin and prints the ACP result line used in `AgentGatewayCLIInvokerTests.swift:291-292`, with resultText `symlinked reply`. `invoke` returns `symlinked reply`. Before the fix, this fails because the physical script is unreadable.
- Regression, unchanged existing tests: `AgentGatewayCLIInvokerTests`, `AgentGatewayServedSafetyTests`, `AgentGatewaySubscriptionTests`, `ClaudeSubscriptionExecutionTests`, `DocumentGatewayIsolationTests` -> pass.

`Tests/AppGraphQLTests/LiveServedAgenticSearchTests.swift` (new, XCTest):

- Gate: `ProcessInfo.processInfo.environment["KAIBA_LIVE_AGENT_GATEWAY"] == "1"` and a non-empty `OPENROUTER_API_KEY`. Otherwise `throw XCTSkip("Set KAIBA_LIVE_AGENT_GATEWAY=1 and OPENROUTER_API_KEY to run the served agenticSearch live test")`, following `Tests/AppServerTests/LiveMemoChatScenarioTests.swift:12-13`.
- Configuration:
  - `KaibaAIConfiguration(agent: KaibaAgentBackendConfiguration(backend: "agent-gateway-cli", commandPath: nil, provider: "openrouter", model: env["KAIBA_LIVE_AGENT_GATEWAY_MODEL"] ?? "openai/gpt-5-mini", apiKeyEnvironmentVariable: "OPENROUTER_API_KEY"))`. Check the initializer labels against `Sources/AppCore` and `Tests/AppCoreTests/AgentGatewayCLIInvokerTests.swift:70-77`.
  - Build the invoker with `AgentInvokerFactory.makeInvoker(configuration:, environment: ProcessInfo.processInfo.environment, executionMode: .served)`.
  - If that returns nil while the gate is on, fail with `XCTFail("agent-gateway served runtime unavailable: ...")`, giving the `describeAvailability` text. Do not skip.
- Service: a temporary store (`makeService` pattern from `Tests/AppGraphQLTests/AgentChatGraphQLTests.swift:885-893`) with two notes, for example one containing "Yamada Taro is the project lead for the lighthouse survey." Then `GraphQLNoteGraphQLService(service:, agentInvoker:, agentProvider: "openrouter", agentModel: <model>)`.
- Execute through `NoteGraphQLDocumentExecutor(service:)`: `query { agenticSearch(query: "Who leads the lighthouse survey?", limit: 5) { status answerMarkdown result { accepted status diagnostics } } }`.
- Assert `status == "ok"` and that `answerMarkdown`, trimmed, is non-empty. On failure, include `result.diagnostics` (already sanitized by P1) in the assertion message. Never print environment values.

## Commands

```bash
mkdir -p tmp/release-0-1-17/P2
bash -c 'test -n "$OPENROUTER_API_KEY" && echo present || echo absent' | tee tmp/release-0-1-17/P2/key-presence.log
# L1 live test (baseline before the fix, final after the fix; use distinct log names)
bash -c 'KAIBA_LIVE_AGENT_GATEWAY=1 PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter LiveServedAgenticSearchTests 2>&1 | tee tmp/release-0-1-17/P2/live-final.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
# D1 sandbox violation capture for the run window (repeat after the fix as sandbox-final.log)
bash -c 'log show --last 10m --style compact --predicate "sender == \"Sandbox\" AND eventMessage CONTAINS \"agent-gateway\"" 2>&1 | tee tmp/release-0-1-17/P2/sandbox-final.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mise run build 2>&1 | tee tmp/release-0-1-17/P2/build.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter "AgentGatewayServedSandboxProfileTests|AgentGatewayCLIInvokerTests|AgentGatewayServedSafetyTests|AgentGatewaySubscriptionTests|ClaudeSubscriptionExecutionTests|DocumentGatewayIsolationTests|AgentGatewayPublicDiagnosticTests" 2>&1 | tee tmp/release-0-1-17/P2/swift-test.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run lint 2>&1 | tee tmp/release-0-1-17/P2/lint.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'wc -l Sources/AppCore/AgentGatewayExecutionIsolation.swift Tests/AppCoreTests/AgentGatewayServedSandboxProfileTests.swift Tests/AppGraphQLTests/LiveServedAgenticSearchTests.swift | tee tmp/release-0-1-17/P2/wc.log'
bash -c 'git diff -- design-docs | tee tmp/release-0-1-17/P2/design-diff.log'
```

For the baseline run, use the same L1 command with `live-baseline.log`, and the same D1 command with `sandbox-baseline.log`. The baseline is expected to exit non-zero. It is diagnosis evidence, not a gate.

Expected evidence:

- `key-presence.log` reads `present`. If it reads `absent`, record `blocked: OPENROUTER_API_KEY absent`. The live gate is then not passed, and nothing is reported as passed.
- `live-final.log`: exit 0, and an XCTest line `Executed N tests, with 0 failures` where N > 0 for this class. The swift-testing `0 tests` line is not counted.
- `sandbox-final.log` shows no gateway denial during the passing run window. Note in the Progress Log that the window was checked; give counts only. If `log show` itself is unavailable (permission or tool error), record `blocked: <exact error>` for D1. In that case the live pass is the only root-cause evidence; say so explicitly.
- Unit swift test exit 0 with XCTest N > 0. build and lint exit 0. Files are under 1000 lines.
- `design-diff.log` is empty unless a bounded allowance was adopted, in which case it shows exactly that one-line addition.

## Done criteria

- [ ] The served context launches and allows only the realpath-resolved gateway; the profile contains the `/private/etc`, `resolv.conf` and five `mach-lookup` rules; invariants hold.
- [ ] The profile, environment and symlink behavioral tests pass; existing isolation and subscription tests pass unchanged.
- [ ] The live test passes with XCTest N > 0 and the Sandbox log is clean for the gateway, or the plan is explicitly blocked with the exact reason, never reported as passed.
- [ ] Any extra allowance is one of the three bounded ones, documented in AI13 and asserted in a test.
- [ ] The Progress Log records baseline and final diagnostics (sanitized), commands, exit codes, counts and log paths.

## Progress Log

- 2026-10-05: Plan created.
