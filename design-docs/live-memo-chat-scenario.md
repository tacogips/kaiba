# Live memo-chat scenario

## Repeat the run

```sh
mise run test:live-memo-chat
```

Requires macOS/Xcode, `agent-gateway` on PATH, and a signed-in Codex provider
with access to `gpt-5.6-luna`. This command makes real provider calls. Ordinary
`swift test` skips this test unless `KAIBA_LIVE_LUNA_SCENARIO=1` is set.

Every run creates a UUID-named `kaiba-live-luna-*` directory in the system
temporary directory. It asserts that the directory did not exist and that the
initialized database contains no notes before creating fixtures. It never
clears or opens the user's existing Kaiba store. The test prints the root and
retains the database and attachments for inspection; the HTTP listener stops
on completion or a thrown error.

For a separate manual UI check, first run `mise run web:check`, then run:

```sh
KAIBA_LIVE_UI_HOLD_SECONDS=600 mise run test:live-memo-chat
```

After the live assertions, the test prints `UI_READY` with its current local
endpoint and waits for the requested time. Open that URL, find the scenario
notebooks, and check the UI. The ephemeral port may change after restart.
Creating an empty `ui-finished` file inside that run's printed test root ends
the optional wait early. The wait itself does not assert UI behavior.

## Coverage

| Scenario | Verification |
| --- | --- |
| Empty database and document creation | HTTP GraphQL mutation; document type is `DOCUMENT` |
| Save a plain memo | Backing notebook created; zero provider calls |
| Open and reopen a memo | Stable notebook identity and `AGENT_CHAT` type |
| Ask about source and memo | Real reply contains facts supplied only in those contexts |
| Attach reference text | Attachment accepted through GraphQL; actual agent reads it |
| Branch at an earlier turn | Snapshot includes earlier history and attachment text, excludes a later parent fact |
| Change original source | Saved branch snapshot remains unchanged |
| Continue branch | Real reply recalls inherited facts and branch memo; parent turn count unchanged |
| Nested branch | Real reply recalls all ancestor facts and nested memo |
| Duplicate send | Replay of each idempotency key returns the same answered turn; no duplicate provider call |
| Stop and reopen database/server | Memo identity, notebook types and stored answer survive; a new real reply recalls the attachment |
| Expansion and navigation | Separate web integration tests cover mounted draft preservation, branch selection, opening a memo notebook, sending to that notebook and returning to source |
| Former context caps | Separate `AgentChatBranchTests` cover >200 KiB context, >100 turns, >200 notes and large parent attachment text |

This is a focused scenario for the memo/branch feature, not a claim that every
Kaiba feature, provider failure, platform or UI layout has been live-tested.

## Execution boundary

The fixture uses Kaiba's real SQLite driver, HTTP listener, GraphQL executor,
auto-action dispatcher, reply persistence and local `AgentGatewayCLIInvoker`.
It does not stub assistant replies or manually complete pending turns.

It explicitly injects the **local Codex gateway** into the test server. It does
not exercise `KaibaServerRuntime`'s production `.served` provider selection.
That path refuses tool-capable Codex providers; the OpenAI API credential was
unavailable in this environment. No production restriction was weakened to
make the test pass. Local Codex may also load working-directory instructions,
so answer checks assert semantic facts rather than exact prose.

## Recorded run — 2026-09-07

- Model: `gpt-5.6-luna`, vendor: `codex`, through local `agent-gateway`.
- Live XCTest: **1 passed, 0 failures**, 6 actual replies, 50.962 seconds.
- Log: `/tmp/kaiba-live-luna-final.log`.
- Retained root: `/var/folders/wn/q3_zjgs15t9_367s8627fd0w0000gn/T/kaiba-live-luna-09F95532-35ED-4F63-9C9D-3A03C4C48333`.
- Live invocation: `KAIBA_LIVE_LUNA_SCENARIO=1 swift test --filter LiveMemoChatScenarioTests`, with the Xcode toolchain/SDK environment used by the runner script.
- Web validation: `mise run web:check` passed (156 unit tests, 34 integration tests, typecheck, lint, build).
- SwiftLint: `mise run lint` passed with three existing warnings outside the added scenario.
- Regression command: `swift test --filter "LiveMemoChatScenarioTests|AgentChatBranchTests|MemoNotebookTests|AgentChatGraphQLTests|KaibaClientServerIntegrationTests"` passed: 39 tests passed, live test skipped without opt-in, zero failures.
- Native shell: `mise run tauri:check` passed.
- Runner checks: `bash -n scripts/test-live-memo-chat.sh`, `mise tasks info test:live-memo-chat` and `git diff --check` passed.
- **Direct visual/browser interaction was not verified:** browser discovery returned no connected browsers. The UI coverage above is component/store/router integration coverage, not a real-browser run.

The initial exploratory run completed the six reply assertions but was
interrupted during its optional UI wait when no browser was available. The
recorded passing result above is a subsequent clean-database run without that
wait, not the interrupted run.
