# Codex subscription chat

Kaiba invokes `agent-gateway client --vendor codex` on the server. Codex uses
its ChatGPT login; subscription credentials never enter the web client or
Kaiba's credential table. A saved personal `codex` entry stores only the
selected model and enabled state, with an empty key.

The server operator opts in with `ai.userAgent.allowCodexSubscription: true`.
This grants authenticated users access to the server's subscription. In the
Config screen, choose **Codex (subscription on server)**, enter an available
model, and save. The chat provider picker can switch between that personal
configuration and the configured server gateway. Both the normal chat composer
and the global Ask AI composer expose provider and model selection.

The server needs a current native `codex` executable and `agent-gateway` on
PATH, and file-based ChatGPT authentication in `$CODEX_HOME/auth.json` (or
`~/.codex/auth.json`). Run `codex -c cli_auth_credentials_store='"file"' login`
as the server OS user. API-key authentication is rejected for this provider.
The server opt-in and installed programs require operator setup; the Config
screen controls each user's subscription selection and default model.

The desktop app's embedded local server initializes missing settings with
Codex, `gpt-5.6-luna`, and subscription selection enabled. Existing agent
settings and explicit subscription opt-outs are preserved. Its executable
search path includes Homebrew locations so GUI launches can find the gateway
and Codex. Rebuild and restart the desktop app after server changes: its
bundled server is independent of the SwiftPM debug executable.

Subscription execution currently requires macOS, like the existing served API
gateway sandbox. Each invocation has a private temporary home and an outer
filesystem sandbox. Only the login file is copied; operator config, rules,
MCP servers, plugins and unrelated environment values are not inherited.
Shell, apps, hooks, browser, computer and multi-agent features are disabled;
Codex runs read-only with approvals disabled. The gateway's existing timeout,
process-group termination and output limits also apply. Temporary login
copies and session state are removed after completion, including failures.
Login refreshes within a temporary invocation are not written back to the
operator's credential store; if authentication expires, refresh the server login.

Codex does not support gateway model enumeration. The selector uses the local
Codex model cache plus the explicitly saved default. Model access remains
subject to the server account. Discovery never reads or returns tokens.

Chat turns snapshot provider and model. Dispatch rechecks the selected personal
provider and refuses to silently route a queued turn through a different
provider after settings change. Existing turns without a provider keep the
previous runtime selection behavior. Schema 20 upgrades schema 19's credential
provider constraint transactionally, preserving existing credentials.

Verification includes credential opt-in/rejection, provider snapshots, isolated
execution arguments, UI subscription saves without API keys, provider/model
selectors, and schema-19 credential preservation. The opt-in live smoke test is:

```sh
KAIBA_LIVE_SUBSCRIPTION_TEST=1 mise exec -- swift test --filter AgentGatewaySubscriptionTests.testLiveSubscriptionReply
```

Desktop verification must also exercise the built frontend against the bundled
local server: save Codex settings, change both selectors in Ask AI, send a
message, and continue in the conversation pane. Check the outgoing GraphQL
input contains both `provider` and `model`, both replies become visible, and
the controls fit the narrow pane. Transport and asynchronous Settings-to-chat
navigation have regression tests; component mocks alone do not cover them.

To make Codex the server default as well, merge these settings into the existing
server configuration and restart Kaiba:

```json
{
  "ai": {
    "agent": {
      "backend": "agent-gateway-cli",
      "provider": "codex",
      "model": "gpt-5.6-luna"
    },
    "userAgent": {
      "allowCodexSubscription": true
    }
  }
}
```

The model above is an example verified by the live test; use a model available
to the server account. Personal subscription settings can also be used without
an `ai.agent` default.
