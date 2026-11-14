# Tauri client connection settings, 2026-10-25

Design reference: `design-docs/specs/tauri-client-apps.md` ("Connection modes",
"Connection settings").

Request (2026-10-25): build the Tauri client app and make its connection target
configurable. The decisions below were made in design to fill the gaps the
request left open. Each one can be revisited without changing the credential
rules.

## Answered

### How many recent remote endpoints are kept?

Five, most recent first, without duplicates, in WebView local storage under
`kaiba-recent-server-endpoints`. Only a successful Remote save adds an entry.
Testing a URL does not. The list holds origins only. Evicting an entry does
not delete that origin's stored credential.

### What does Test connection check, and what does it send?

It checks `GET /healthz` first: HTTP 200 with `service: "kaiba"` and
`status: "ok"` means the host is a kaiba server. It then sends
`POST /graphql` with `{ __typename }` and reads only the status code. The
results are:

- connected (200)
- sign-in required (401)
- server error (any other status)
- not a kaiba server (a failed health check)
- unreachable (network failure, or no answer within 5 s)

The probe sends no bearer to any origin, including the candidate itself, so it
cannot leak a credential. When the candidate already has a saved key, a
sign-in-required result says that the key will be used after connecting.

### Must a test pass before an endpoint can be saved?

No. Test connection is advisory. Saving a server that is currently down is
allowed, and per-origin credential scoping already makes a mistyped origin
harmless.

### How is per-account state reset on a switch?

Every save reloads the WebView, as before. No in-place reset is added.

### Is there a first-run connection chooser?

No. A first launch defaults to Local on macOS and to Remote on iPhone, and an
existing saved endpoint keeps Remote. When the default target fails, the shell
still renders and the header Settings button reaches the connection form. The
login screen also embeds the compact form.

### Should a non-loopback `http` endpoint be blocked or warned?

The form warns and does not block. Blocking would break LAN servers reached
from an iPhone. This closes the pending question in
`design-docs/user-qa/tauri-client-apps.md`.

### Does the Swift server or the Rust shell change?

No. `/healthz` and the GraphQL 401 already exist. The HTTP capability already
allows any `http`/`https` origin. `tauri:build` already rebuilds the bundled
`kaiba` through `beforeBuildCommand`.

## Pending

### Naming and distribution of the client bundle

This is unchanged and still pending in `design-docs/user-qa/tauri-client-apps.md`.
`Kaiba.app` from `mise run tauri:build` is build output only. It is unsigned
and must not be installed to `/Applications`.
