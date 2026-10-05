# P1 Served agenticSearch diagnostics: sandbox-start classification, public reason, server log

**Status**: In Progress.
**planId**: P1-agentic-search-diagnostics
**Wave**: 1
**dependsOn**: none
**Design Reference**: `design-docs/specs/ai-agent-integration.md` AI13 ("Fixed served diagnostics", "Public reason mapping (AppCore)", "agenticSearch surface", "Placement (1000-line limit)"), the GraphQL Surface Additions `agenticSearch` bullet, and Verification item 13 (bullets 4-6)
**Index**: `impl-plans/active/release-0-1-17.md`

## Intent and context

Today a served `agenticSearch` failure reaches the client only as `diagnostics: ["note operation failed"]`, for two reasons:

- `GraphQLNoteGraphQLService.agenticSearch` (`Sources/AppGraphQL/NoteGraphQLService.swift:728-758`) catches every error and calls `graphQLNoteResult(for:)` (`:926`). That function has no `AgentInvocationError` case, so `graphQLNotePublicDiagnostic` (`:943-970`) falls to `"note operation failed"`.
- The served gateway invoker already turns failures into fixed strings (`Sources/AppCore/AgentGatewayCLIInvoker.swift:139-160`, `Sources/AppCore/AgentGatewayInvocationSanitization.swift`). But when the child produces no reply, the served path drops stderr completely, so a `sandbox-exec` launch failure looks the same as any gateway crash.

After this plan:

1. A served invocation that produced no reply and whose stderr begins with `sandbox-exec:` fails with `agent-gateway could not start inside the server sandbox (exit N)`. The stderr text is never copied.
2. `AgentInvocationError` has a public, allowlist-based reason that is safe for GraphQL diagnostics and server logs.
3. When `agenticSearch` fails with an `AgentInvocationError`:
   - `result.diagnostics` is that one reason;
   - `result.status` stays `"error"`, `accepted` stays `false`, and the top-level `status` stays `"failed"`.
4. Every `agenticSearch` failure writes one stderr line, `kaiba: agenticSearch failed: <public reason>`, through an injectable sink.

## Contract pinned for P2 and P4

Both of these live in `Sources/AppCore/AgentGatewayInvocationSanitization.swift`.

```swift
extension AgentGatewayCLIInvoker {
  static func servedNoReplyDiagnostic(exitCode: Int32, stderr: Data) -> String
}
public extension AgentInvocationError {
  var publicDiagnostic: String { get }
}
```

The service gains one stored property in `Sources/AppGraphQL/NoteGraphQLService.swift`:

```swift
public var agenticSearchFailureLog: @Sendable (String) -> Void
```

Its default value writes `$0 + "\n"` to `FileHandle.standardError`, the same idiom as `Sources/AppServer/SearchEngineRuntimeController.swift:20-22`. Declare the default on the property itself. Do not add an init parameter, because the file is at 974 lines.

### Public reason mapping (exact)

`publicDiagnostic`:

- `.notConfigured` -> `agent runtime is not configured`
- `.unavailable(_)` -> `agent runtime is unavailable`. This resolves review finding DR-L1: every `unavailable` error maps here, including the served `server agent-gateway is unavailable`.
- `.failed(message)` -> `message` only if it exactly matches one of the following. `N` matches `-?[0-9]{1,10}`, and the whole string must match (anchored).
  - `agent-gateway request failed`
  - `agent-gateway produced no reply (exit N)`
  - `agent-gateway could not start inside the server sandbox (exit N)`
  - `agent-gateway exited with status N`
  - `agent-gateway invocation timed out`
  - `agent-gateway output exceeds the 256 KiB process limit`
  - `agent reply exceeds the 256 KiB or 256-chunk output limit`
  - `server agent-gateway is unavailable`
- `.failed` with any other message -> `agent request failed`

`servedNoReplyDiagnostic(exitCode:stderr:)`:

- If stderr, decoded as UTF-8 (lossy is fine) with leading whitespace trimmed, has the prefix `sandbox-exec:`, return `agent-gateway could not start inside the server sandbox (exit <exitCode>)`.
- Otherwise return `agent-gateway produced no reply (exit <exitCode>)`, which is today's served string.

## Non-goals

- No change to the GraphQL SDL (`GraphQLNoteSchemaContract.swift`, `GraphQLContractProjector.swift`), the status values, the DTO shape or the KaibaClient.
- No change to `graphQLNoteResult(for:)` or `graphQLNotePublicDiagnostic` for other operations.
- No change to local-mode diagnostics. The local branch at `AgentGatewayCLIInvoker.swift:150-153` keeps its stderr tail.
- No sandbox profile change; that is P2.
- No change to chat, tag or translation persistence.
- No mapping of runtime `unavailable` to `agent-unavailable`.
- No change to `AgentInvocationError` cases.

## writePaths

- `Sources/AppCore/AgentGatewayInvocationSanitization.swift`
- `Sources/AppCore/AgentGatewayCLIInvoker.swift`
- `Sources/AppGraphQL/NoteGraphQLService.swift`
- `Sources/AppGraphQL/NoteGraphQLAgenticSearch.swift`
- `Tests/AppCoreTests/AgentGatewayPublicDiagnosticTests.swift`
- `Tests/AppGraphQLTests/AgenticSearchDiagnosticsGraphQLTests.swift`
- `impl-plans/active/release-0-1-17-p1-agentic-search-diagnostics.md`
- `tmp/release-0-1-17/P1`

## sharedPaths (read-only)

- `Sources/AppCore/AgentInvoking.swift`
- `Sources/AppCore/AIAgenticSearch.swift`
- `Sources/AppGraphQL/NoteGraphQLDocumentExecutor.swift`
- `Tests/AppCoreTests/AgentGatewayCLIInvokerTests.swift`
- `Tests/AppGraphQLTests/AgentChatGraphQLTests.swift`

## sharedPathNotes

- `Sources/AppCore/AgentGatewayCLIInvoker.swift`: intendedEdit is limited to the served branch of the no-reply diagnostic (currently lines 147-150). Replace the inline served string with a call to `Self.servedNoReplyDiagnostic(exitCode: execution.exitCode, stderr: execution.stderr)`. Change nothing else. The file has 984 lines and must stay under 1000; net growth should be 0 lines.
- `Sources/AppGraphQL/NoteGraphQLService.swift`:
  - Remove the `agenticSearch` method (lines 725-758, including its doc comment).
  - Add the `agenticSearchFailureLog` stored property with its default, next to `agentModel` and its doc comment.
  - The file must shrink.
- `Sources/AppGraphQL/NoteGraphQLAgenticSearch.swift`: new file, `extension GraphQLNoteGraphQLService`, holding the moved `agenticSearch` with the AI13 failure mapping and log call.
- `Sources/AppGraphQL/NoteGraphQLDocumentExecutor.swift`: read-only. Its `case "agenticSearch"` at line 336 keeps calling `service.agenticSearch(...)` unchanged.
- `Tests/AppGraphQLTests/AgentChatGraphQLTests.swift`: read-only. Imitate its `makeService`, `graphQLPayload` and `resultObject` helpers (lines 885-910) by copying them privately into the new test file.
- `tmp/release-0-1-17/P1`: evidence logs, `hashes.txt` and `intent.md` only.

## artifactRoots

- `tmp/release-0-1-17/P1`

## File-level changes

1. `AgentGatewayInvocationSanitization.swift`:
   - Add `servedNoReplyDiagnostic` and the `publicDiagnostic` extension exactly as pinned above.
   - Keep `sanitizedInvocationError` unchanged.
   - Use a fixed `Set<String>` for the exact strings, plus a small anchored check for the three `N` templates. A prefix/suffix check with an all-digits middle (optional leading `-`, at most 10 digits) is enough. Do not use a permissive `contains`.
2. `AgentGatewayCLIInvoker.swift`: the one-call substitution described in sharedPathNotes.
3. `NoteGraphQLAgenticSearch.swift` (new):
   - Move the method body and keep its behavior for the nil-invoker and success paths byte-for-byte.
   - In the `catch`:
     - If `error` is an `AgentInvocationError`, let `reason = error.publicDiagnostic` and build `GraphQLControlPlaneResult(accepted: false, status: "error", diagnostics: [reason])`.
     - Otherwise use `graphQLNoteResult(for: error)` and take `reason` from its first diagnostic. Fall back to `note operation failed` if that list is empty.
     - Call `agenticSearchFailureLog("kaiba: agenticSearch failed: \(reason)")` exactly once.
     - Return top-level status `"failed"`.
   - Keep the doc comment ("`status` is \"ok\", \"agent-unavailable\", or \"failed\"").
   - `CancellationError` is not special-cased. It is not an `AgentInvocationError`, so it takes the existing mapping.
4. `NoteGraphQLService.swift`: the removal and the stored property described in sharedPathNotes.

## Pitfalls

- Never put the query, the answer, environment values, stderr, provider text or file paths into the log line or into diagnostics.
- `publicDiagnostic` must be an allowlist: an unknown message must never pass through, even if it "looks safe". For example, `agent-gateway produced no reply (exit 1): secret` must map to `agent request failed`.
- `AgentInvocationError.failed` strings from local mode (stderr tails) must map to the generic reason.
- Do not rename or overload `invoke`. See the comment at `AgentGatewayCLIInvoker.swift:68-69` about overload recursion.
- `agenticSearchFailureLog` must be `@Sendable` because the struct is `Sendable`. The test capture box should be a `final class ... : @unchecked Sendable` guarded by `NSLock`, following `Tests/AppCoreTests/UserAgentToolLoopTests.swift:92` (`ChunkRecorder`).
- Keep `NoteGraphQLService.swift` and `AgentGatewayCLIInvoker.swift` under 1000 lines (check with `wc -l`).
- Do not touch `AgentGatewayExecutionIsolation.swift`; it belongs to P2.

## Tests (input or situation -> expected outcome)

`Tests/AppCoreTests/AgentGatewayPublicDiagnosticTests.swift` (new, XCTest):

- `servedNoReplyDiagnostic(exitCode: 71, stderr: "sandbox-exec: execvp() of '/x/agent-gateway' failed: Operation not permitted\n")` -> exactly `agent-gateway could not start inside the server sandbox (exit 71)`, with no `/x` and no `Operation`.
- The same call with leading whitespace or newline before `sandbox-exec:` -> the sandbox-start string.
- `servedNoReplyDiagnostic(exitCode: 1, stderr: "gateway stderr: secret-token")` -> `agent-gateway produced no reply (exit 1)`.
- Empty stderr -> `agent-gateway produced no reply (exit 0)` (for exitCode 0).
- Each allowlisted string, with the `N` templates filled with `0`, `1`, `71`, `-9` -> `publicDiagnostic` returns it unchanged.
- `.failed("agent-gateway produced no reply (exit 1): leaked")`, `.failed("agent-gateway produced no reply (exit x)")`, `.failed("provider-key-FIXTURE-secret")`, `.failed("/home/example/bin/agent-gateway failed")`, and `.failed("agent-gateway request failed ")` (trailing space) -> `agent request failed`.
- Fixture rule: test fixtures must not contain `/Users/`, `/opt/homebrew/Cellar` or real-looking `sk-or-v1-` keys, because P4's local-path and secret guards scan every changed file. Use `/home/example/...`, `/srv/example/...` and `FIXTURE` tokens instead.
- `.notConfigured` -> `agent runtime is not configured`.
- `.unavailable("agent-gateway binary not found: /opt/x")` and `.unavailable("server agent-gateway is unavailable")` -> `agent runtime is unavailable`.
- Behavioral, macOS only: a served invoker whose fake script writes `sandbox-exec: fake failure` to stderr and exits 3 throws `.failed("agent-gateway could not start inside the server sandbox (exit 3)")`.
  - Build the fake script with a private `makeExecutableGatewayScript` copied from `Tests/AppCoreTests/AgentGatewayServedSafetyTests.swift:135-143`.
  - Use vendor `openrouter`, `apiKeyEnvironment: "PROVIDER_TOKEN"`, and environment `["PROVIDER_TOKEN": "x"]`.
  - Note: the script runs inside the real sandbox, so the stderr prefix comes from the script. This proves the hook is wired.
- Existing `AgentGatewayCLIInvokerTests.testServedInvokerSuppressesGatewayCredentialDiagnostics` (expects `agent-gateway produced no reply (exit 1)`) must keep passing unchanged.

`Tests/AppGraphQLTests/AgenticSearchDiagnosticsGraphQLTests.swift` (new, XCTest; `@testable import AppGraphQL`):

- Failing stub invoker throws `.failed("agent-gateway produced no reply (exit 71)")`. Call `service.agenticSearch(query: "q")` -> `status == "failed"`, `result.status == "error"`, `result.accepted == false`, `result.diagnostics == ["agent-gateway produced no reply (exit 71)"]`. Exactly one captured log line, equal to `kaiba: agenticSearch failed: agent-gateway produced no reply (exit 71)`.
- Stub throws `.failed("provider said FIXTURE-SECRET at /home/example/x")` -> diagnostics `["agent request failed"]`. The captured log contains neither `FIXTURE-SECRET` nor `/home/example`.
- Stub throws `.unavailable("binary not found: /srv/example/x")` -> diagnostics `["agent runtime is unavailable"]`.
- Empty query (an AIAgenticSearchService `invalidInput`) -> keeps the existing mapping: `result.status == "invalid_request"`, and diagnostics start with `invalid note request:`. One log line is written.
- Success stub -> `status == "ok"`, non-empty `answerMarkdown`, and zero log lines.
- `agentInvoker == nil` -> `status == "agent-unavailable"` and zero log lines.
- Through `NoteGraphQLDocumentExecutor(service:)`, the query `query { agenticSearch(query: "q", limit: 5) { status answerMarkdown result { accepted status diagnostics } } }` with the failing stub -> `data.agenticSearch.result.diagnostics == ["agent-gateway produced no reply (exit 71)"]` and no `errors`.

## Verification

```bash
mkdir -p tmp/release-0-1-17/P1
bash -c 'mise run build 2>&1 | tee tmp/release-0-1-17/P1/build.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter "AgentGatewayPublicDiagnosticTests|AgenticSearchDiagnosticsGraphQLTests|AgentGatewayCLIInvokerTests|AgentGatewayServedSafetyTests|NoteGraphQLSchemaInventoryTests|GraphQLIntrospectionTests" 2>&1 | tee tmp/release-0-1-17/P1/swift-test.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run lint 2>&1 | tee tmp/release-0-1-17/P1/lint.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'grep -n "agenticSearch(" Sources/AppGraphQL/NoteGraphQLService.swift | tee tmp/release-0-1-17/P1/guard-moved.log; test ! -s tmp/release-0-1-17/P1/guard-moved.log'
bash -c 'wc -l Sources/AppCore/AgentGatewayInvocationSanitization.swift Sources/AppCore/AgentGatewayCLIInvoker.swift Sources/AppGraphQL/NoteGraphQLService.swift Sources/AppGraphQL/NoteGraphQLAgenticSearch.swift Tests/AppCoreTests/AgentGatewayPublicDiagnosticTests.swift Tests/AppGraphQLTests/AgenticSearchDiagnosticsGraphQLTests.swift | tee tmp/release-0-1-17/P1/wc.log'
```

Expected evidence:

- build exit 0.
- `swift test` exit 0, with an XCTest `Executed N tests, with 0 failures` line where N > 0. Record N; it includes both new classes.
- lint exit 0 with no serious violations in touched files.
- `guard-moved.log` is empty, which means `agenticSearch(` is no longer defined in `NoteGraphQLService.swift`.
- Every file in `wc.log` is under 1000 lines, and `AgentGatewayCLIInvoker.swift` is at most 984 lines.

## Done criteria

- [x] `publicDiagnostic` and `servedNoReplyDiagnostic` exist with the pinned signatures and exact strings.
- [x] `agenticSearch` lives in `Sources/AppGraphQL/NoteGraphQLAgenticSearch.swift`; diagnostics and the log line follow AI13.
- [ ] All listed tests exist and pass with XCTest N > 0; the existing served-diagnostic tests pass unchanged. The P1 XCTest suites ran, but the macOS fake-gateway hook test did not observe its scripted stderr prefix; see the Progress Log.
- [x] build and lint exit 0; line limits are met.
- [x] The Progress Log records commands, exit codes, counts and log paths.

## Progress Log

- 2026-10-05: Plan created.
- 2026-10-05: Implemented the fixed public diagnostic allowlist and served no-reply stderr classifier in `Sources/AppCore/AgentGatewayInvocationSanitization.swift`; wired the served invoker in `Sources/AppCore/AgentGatewayCLIInvoker.swift`; moved `agenticSearch` into `Sources/AppGraphQL/NoteGraphQLAgenticSearch.swift`; added injectable safe failure logging and both XCTest classes.
- 2026-10-05: `mise run build` exited 0. Complete log: `tmp/release-0-1-17/P1/build-final.log`.
- 2026-10-05: The focused Swift test command `PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter "AgentGatewayPublicDiagnosticTests|AgenticSearchDiagnosticsGraphQLTests|AgentGatewayCLIInvokerTests|AgentGatewayServedSafetyTests|NoteGraphQLSchemaInventoryTests|GraphQLIntrospectionTests"` exited 1 after 47 XCTest cases: 46 passed, 1 failed. The failing case is `AgentGatewayPublicDiagnosticTests.testServedInvokerClassifiesSandboxExecStderrPrefix`: the fake gateway exits 3 but the served invocation reports `agent-gateway produced no reply (exit 3)` instead of the expected sandbox-start reason. Complete initial log: `tmp/release-0-1-17/P1/swift-test-rerun.log`; after changing the fixture to the existing shell `echo` idiom, the isolated rerun still exited 1 with 47 cases, 46 passed, 1 failed. Complete log: `tmp/release-0-1-17/P1/swift-test-isolated.log`. The other new diagnostic and GraphQL tests passed, including 6/6 in `AgenticSearchDiagnosticsGraphQLTests`; existing `AgentGatewayCLIInvokerTests` (25/25), served safety (3/3), GraphQL introspection (7/7), and schema inventory (1/1) passed unchanged.
- 2026-10-05: Selected-file strict lint, `xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/release-0-1-17/P1/changed-swift-files.nul`, exited 0; complete log: `tmp/release-0-1-17/P1/swiftlint-changed.log`. Repository-wide `mise run lint` exited 0 with 3 non-serious warnings in unchanged files; complete log: `tmp/release-0-1-17/P1/lint.log`.
- 2026-10-05: `grep -n "agenticSearch(" Sources/AppGraphQL/NoteGraphQLService.swift` produced an empty `tmp/release-0-1-17/P1/guard-moved.log` and the guard exited 0. The six Swift files are below 1000 lines; `AgentGatewayCLIInvoker.swift` is 984 lines. Complete count log: `tmp/release-0-1-17/P1/wc-final.log`; guard exit 0.
