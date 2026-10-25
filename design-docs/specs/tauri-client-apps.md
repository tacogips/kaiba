# Tauri Client Apps

## Status

Accepted (2026-08-29). Initial implementation.

Revised (2026-10-25): documents the Local/Remote connection modes and the
bundled local service, and adds Test connection, recent remote endpoints, the
active-connection display and the plain-`http` warning (see "Connection modes"
and "Connection settings"). Decisions are recorded in
`design-docs/user-qa/tauri-client-connection-20261025.md`.

## Goal

Ship the existing SolidJS note client as installable macOS and iPhone apps
without creating a second note domain, database, or API implementation.

## Architecture

- `kaiba serve` remains the authoritative Swift server and store owner.
- `web/` remains the only client UI implementation for browsers, macOS, and
  iPhone.
- `web/src-tauri/` is a Tauri 2 shell. Its Rust code owns only native runtime
  setup and the HTTP plugin; product behavior stays in Swift and TypeScript.
- Browser requests remain same-origin. In a Tauri runtime, relative note API
  paths are resolved against a locally stored server endpoint and sent through
  Tauri's HTTP plugin, avoiding WebView cross-origin restrictions.
- The API bearer and native endpoint are stored in the app WebView's local
  storage. They are never compiled into the application. The bearer is bound to
  the endpoint that issued it: it is stored under
  `kaiba-note-bearer:<normalized endpoint>` and is unreadable for any other
  origin, so changing the configured endpoint presents no credential to the new
  host and deletes nothing, and a key issued by one server is never presented to
  another.

## Transport boundary

Runtime detection is the only switch: a client running without Tauri internals
keeps using the browser's same-origin transport, and a stored endpoint has no
effect there. A client running inside Tauri routes every note API call through
the HTTP plugin.

- Relative note API paths (`/graphql`, `/note/register`, `/note/events`,
  `/note/agent-stream`, `/files/{id}`) are resolved against the configured
  endpoint before dispatch. Query strings on a request path are preserved; the
  no-query rule applies to the stored endpoint, not to request paths.
- An absolute URL is kept as its own target (normalized by URL parsing) and a
  non-string request input is passed through untouched; all
  request targets originate in the fixed Kaiba client implementation, never
  from server-supplied data.
- The `/note/events` long-poll feed uses the same transport, so native clients
  receive change events with the same push latency as the browser client.
- Registration through the code path reports its client as `Kaiba App` from a
  native runtime and `Kaiba Web` from a browser, so credentials issued that way
  are attributable per surface. The attribution is not complete: the login
  screen's manual hint prints `kaiba client issue --name "Kaiba Web"` in every
  runtime, so a native user who follows it issues a key labelled `Kaiba Web`.
  Making that hint runtime-aware is a follow-up, not part of this change set.

## Endpoint validation

The endpoint is an origin, not a base path. A value is accepted only when it
parses as an absolute URL and satisfies all of:

- scheme is `http` or `https`; every other scheme is rejected.
- no user info (username or password).
- no query string and no fragment.
- no path beyond `/`.

Accepted values are normalized to a scheme-host-port origin with the trailing
slash removed before storage. An absent stored value yields the default
endpoint. A stored value that no longer validates falls back to the default
endpoint rather than failing the client, so a corrupted or hand-edited entry
cannot lock a user out of the app; the settings form still shows the failure
message when a user submits an invalid value.

## Platform behavior

The default endpoint is `http://127.0.0.1:8787`. This is useful for the macOS
app when `kaiba serve` runs on the same Mac. An iPhone user must configure a
server address reachable from the phone, such as an HTTPS hostname or the
server Mac's LAN address; the phone's own loopback address does not reach the
Mac. Production use over an untrusted network requires HTTPS.

The endpoint control is rendered only in a native runtime, in two places: the
Config screen's server connection section, and a compact form on the login
screen so an unauthenticated user can correct an unreachable server before
authenticating. The component owns the Config section's `<section>` and heading
rather than receiving them from the caller, so "rendered only in a native
runtime" covers the surrounding chrome: a caller cannot leave an empty card on
the Config screen in the browser build. Saving a new endpoint reloads the WebView so every cached
client and subscription re-resolves against the new origin.

## Connection modes

A native client runs in one of two modes, stored under
`kaiba-connection-mode`:

- `local`: the shell starts the bundled `kaiba` executable
  (`start_local_server`, `web/src-tauri/src/local_server.rs`) on a free
  loopback port with `--allow-unauthenticated --as-admin`, against the app's
  own store under the app local data directory (`local/`). Requests in this
  mode carry no `Authorization` header, and the credential key in effect is
  `kaiba-note-bearer:local`, which is never sent. Local mode is macOS only;
  `supportsLocalService()` is false on iPhone and the shell refuses the
  command there.
- `remote`: requests go to the stored endpoint (`kaiba-server-endpoint`)
  under the per-origin credential rules below.

When the mode key is absent (first launch), an install that already holds a
saved endpoint keeps Remote, iPhone defaults to Remote, and macOS defaults to
Local. There is no separate first-run chooser. First launch either works
(Local) or leaves the shell showing a load error, and in both cases the
connection settings are one click away (see "Reachability").

Saving Local first awaits `start_local_server` and stores the mode only if it
succeeds, so a service that fails to start reports its error (including the
`service.log` path) in the form and leaves the previous mode in effect.

## Connection settings

`ServerConnectionSettings` is the single connection UI, rendered in full on
the Config screen and compact on the login screen. It contains:

- **Mode select**: Local (disabled where `supportsLocalService()` is false)
  or Remote.
- **Remote URL field**: validated by `normalizeServerEndpoint` as described in
  "Endpoint validation". A rejected value shows the validator's message and is
  neither stored nor recorded.
- **Plain-`http` warning**: a non-blocking inline notice when the entered URL
  uses `http` and its host is not loopback (`localhost`, `127.0.0.0/8`,
  `[::1]`). The notice says that the API key travels unencrypted. Saving is
  not blocked, because LAN servers reached from an iPhone are an intended use.
- **Test connection** (Remote only): probes the entered URL without saving it.
  See "Test connection".
- **Recent servers** (Remote only, hidden when the list is empty): picking an
  entry fills the URL field. It does not save or switch. See "Recent remote
  endpoints".
- **Active connection line**: shows what is in effect now, read from storage
  and not from unsaved form state. It reads `Local — this Mac` in Local mode,
  or `Remote — <host[:port]>` taken from the stored endpoint. It appears in
  both the full and compact forms, so the login screen names the server that
  is asking for a credential.
- **Save/Reconnect**: stores the endpoint (Remote, through
  `saveServerEndpoint`) and the mode (through `saveConnectionMode`), records
  the endpoint in the recent list, then reloads the WebView. Saving does not
  require a passed test. A server that is down at the moment can still be
  configured, and a mistyped origin costs nothing because credentials are
  scoped per origin.

### Switching and per-account state

Every successful save reloads the WebView, including a save that only
re-selects the current target. The reload is the reset mechanism for
per-account in-memory state: the app store, caches, note-events long poll,
autosave queues, writers and the cached local-service promise are all rebuilt
against the new target. No in-place reset path is added. Credentials are not
touched by a switch: Remote to Remote, Remote to Local and Local to Remote
each read the key of the target in effect after the reload, so a previously
signed-in origin is signed in again when the user switches back.

### Test connection

The probe runs only in a native runtime, through the Tauri HTTP plugin
directly, not through `serverRequest`. `serverRequest` resolves against the
endpoint currently in effect, while the probe targets an unsaved candidate.
Steps:

1. Normalize the candidate with `normalizeServerEndpoint`. A validation
   failure is reported as the validator's message, and nothing is sent.
2. `GET <candidate>/healthz`. A network failure, or no response within 5
   seconds (the request is aborted), gives **unreachable**. Any response
   other than HTTP 200 with a JSON body whose `service` is `"kaiba"` and
   `status` is `"ok"` gives **not a kaiba server**.
3. `POST <candidate>/graphql` with `{"query":"{ __typename }"}` and the same
   timeout. HTTP 200 gives **connected** (the server accepts unauthenticated
   requests). HTTP 401 gives **sign-in required**. Any other status gives
   **server error (HTTP n)**. A network failure here also gives
   **unreachable**.

Credential rule: the probe sends no `Authorization` header to any origin,
including the candidate. Both targets are fixed paths on the normalized
candidate and pass `assertServerOrigin(target, candidate)` before dispatch.
When the result is sign-in required and a credential is already stored under
`serverCredentialKey(candidate)`, the message adds that the saved key will be
used after connecting. That check is a local storage presence test. The value
is not read into the request. The result is shown inline. It changes no
storage and does not gate Save.

### Recent remote endpoints

- Storage: `kaiba-recent-server-endpoints` in WebView local storage, a JSON
  array of normalized origins, most recent first, without duplicates, bounded
  to 5.
- Written only by a successful Remote save, after `saveServerEndpoint`
  returns. A Test connection, a validation failure, or a Local save does not
  record anything.
- Read defensively: unparsable JSON yields an empty list, and every entry is
  re-validated with `normalizeServerEndpoint`, so invalid entries are
  dropped. A corrupted value cannot break the form, matching the endpoint
  fallback rule.
- The list holds origins only, never credentials. An entry evicted from the
  list leaves that origin's `kaiba-note-bearer:<origin>` key in place. As
  stated below, nothing prunes per-origin credentials.
- Native-only, like the endpoint itself. The browser build neither reads nor
  writes the list.

### Reachability

The connection settings must be reachable from every state the native client
can be in:

- **Unauthenticated / registration** (`auth === 'unauthenticated'`, including
  the capture page's unregistered fallback): `LoginView` renders the compact
  form.
- **Unreachable or erroring server**, or a local service that failed to start
  (`auth` stays `unknown` and the catalog load fails): the shell still renders.
  The error toast shows the failure, and the header Settings button opens the
  Config screen, which renders `ServerConnectionSettings` independently of
  any server response. No connection screen replaces the shell.
- **Authenticated**: the Config screen.

The integration tests are the guard for this invariant: with a failing
transport, the Settings route must render the connection form.

iPhone layout uses `viewport-fit=cover` with `env(safe-area-inset-*)` padding
on the document body, so the shared UI clears the notch and home indicator
without a phone-specific layout branch.

## Native permissions

The Tauri capability permits `http://*:*` and `https://*:*` because the actual
host is user-configurable and cannot be enumerated at build time. Endpoint
validation is therefore the effective guard on which origins the app contacts.
The HTTP plugin is built with no extra features. `unsafe-headers`, which lifts
the WebView's forbidden-header restrictions on native requests, was dropped:
the plugin's forbidden-header list covers `Cookie`, `Host`, `Origin`,
`Referer`, `proxy-*`, `sec-*` and the other fetch-spec restricted names, and
the client sets only `Authorization`, `Content-Type` and `Accept`, none of
which is restricted. Keeping the feature would have let any script reaching the
WebView forge those headers against any `http`/`https` origin for no functional
benefit. Reinstating it requires a native request that genuinely needs a
restricted header, and revisiting this paragraph.

The WebView content-security policy is disabled (`"csp": null`). The client
renders no server-supplied HTML, so there is no injection sink to constrain
today, and a policy tight enough for the Vite dev server and the packaged
`tauri://` origin would have to be maintained by hand for both. A CSP must be
defined before the client renders any HTML it did not author.

The credential is stored per origin, under
`kaiba-note-bearer:<normalized endpoint>`, and the client reads the key
belonging to the endpoint currently in effect. A bearer is therefore only ever
readable for the host that issued it, and repointing the client cannot present
it anywhere else. This is a client-side invariant, not a consequence of server
behavior: the only clear-on-failure path in the client is a 401 from the
GraphQL route, so it does not cover the note-events long poll, attachment
fetches or the agent-stream poll, and a server started with
`kaiba serve --allow-unauthenticated` never emits 401 at all. Without the
scoping, repointing the client would send the previous server's credential to
the new host on every request for the life of the install.

Scoping rather than deleting is deliberate. An endpoint is free text, a typo
passes validation, and the only in-app recovery is pasting a key issued on the
server host, so destroying the credential on every origin change would make one
mistyped character an unrecoverable state on a phone away from that host. With
per-origin keys, correcting the endpoint makes the original credential readable
again, and no confirmation prompt is needed because nothing was lost. An
Clearing is per origin for the same reason: `clearCredential()` drops the key
for the endpoint currently in effect and leaves other origins' credentials in
place, so a 401 from one server does not sign the user out of the others.
Nothing prunes the keys of origins the user no longer uses.

An install created before scoping holds one unscoped `kaiba-note-bearer` value;
it belongs to the endpoint in effect, so it is filed under that origin on first
read, and `saveServerEndpoint` files it under the outgoing origin if the
endpoint changes first.

Residual risk accepted for this release: the bearer lives in WebView local
storage and travels in plaintext when a user configures a non-loopback `http`
endpoint. The app does not downgrade or upgrade schemes on the user's behalf.
The settings form warns about such an endpoint but does not block it (see
"Connection settings").
Requests leave through the Rust shell rather than `URLSession`, so iOS App
Transport Security does not apply and no OS-level warning is raised.

## Build surfaces

- `mise run tauri:dev` runs the macOS app against the Vite development server.
- `mise run tauri:build` produces the macOS application bundle.
- `mise run tauri:ios:init` generates the Tauri Xcode project when needed.
- `mise run tauri:ios:dev` runs the iPhone app for development.
- `mise run tauri:ios:build` builds the iPhone application.

Bundled local service: `beforeBuildCommand` runs
`scripts/build-tauri-local-service.sh release`, which builds the Swift `kaiba`
product for the target triple and copies it to
`web/src-tauri/local-service/kaiba-<triple>`. `tauri.macos.conf.json` declares
`externalBin: ["local-service/kaiba"]`. Tauri resolves that to the
triple-suffixed file and installs it as `Kaiba.app/Contents/MacOS/kaiba`,
which is the path `local_server.rs` executes. A bare
`local-service/kaiba` file, if present, is a leftover and is not bundled. A
build is fresh when the bundled `Contents/MacOS/kaiba` is byte-identical to
`local-service/kaiba-<triple>` and both mtimes postdate the build start. The
built app must not be launched to check this, because Local mode opens the
user's real app store under the app local data directory. Runtime checks run
the bundled executable directly with `--note-root`, `--config` and
`KAIBA_SQLITE_PATH` pointing under `tmp/`.

The Vite dev server is pinned to port 1420 with `strictPort`, and binds a
non-loopback host only when `TAURI_DEV_HOST` is set, which is what lets a
physical iPhone reach a development build.

Validation gates are `mise run web:check` (typecheck, test, lint, build),
`mise run tauri:check` (`cargo fmt --check`, `cargo check`, `clippy -D
warnings`), and `mise run test` for the Swift suites. `mise run check` runs all
of them. The client's tests are the only mechanical guard on the credential
rules below, so `web:check` and `tauri:check` are named in the AGENTS.md command
list rather than left to whoever remembers them. `web:check` is pure bun and
needs no macOS, so it runs in CI on `ubuntu-24.04`
(`.github/workflows/web-check.yml`) on every push to `main` and every pull
request, which is what mechanically enforces the credential rules below.
`tauri:check` and the bundle builds are the parts that require a macOS
toolchain; they have no CI job, so their enforcement point remains the AGENTS.md
command list and local `mise run check`.

Build-time environment exposure: `web/vite.config.ts` sets
`envPrefix: ['VITE_', 'TAURI_ENV_']`. The prefix is deliberately not the bare
`TAURI_` the Tauri scaffold uses, because `vite build` runs inside `tauri build`
through `beforeBuildCommand`, and that process environment carries
`TAURI_SIGNING_PRIVATE_KEY` when updater signing is configured; a bare prefix
would expose it on `import.meta.env` and inline it into the shipped bundle
wherever source referenced it.

## Rollout constraints

- The bundle identifier is `com.tacogips.kaiba`; the shell crate and
  `tauri.conf.json` version track the Swift package version.
- Platform floors are macOS 14 and iOS 17.
- Naming collision, unresolved by design: `productName` is `Kaiba`, so
  `mise run tauri:build` emits `Kaiba.app`, and `macos-menu-bar-app.md` already
  ships a different `Kaiba.app` — the resident menu-bar server, identifier
  `dev.kaiba.Kaiba` — into `/Applications` through the Homebrew Cask. The
  identifiers differ, so nothing overwrites anything today, but the two names
  are indistinguishable to a user. This client bundle is build output only: it
  is in no Cask, no DMG, and no installer, and it must not be installed to
  `/Applications` under the current name. Renaming `productName` — `Kaiba
  Client` matches the `kaiba-client` crate and the `kaiba-client_iOS` Apple
  target — is a precondition of any distribution, not of this change set.
  The rename also rewrites `PRODUCT_NAME` in the tracked
  `gen/apple/project.yml`, so it must be followed by `mise run tauri:ios:init`
  and committed together. The final name is a user decision recorded in
  `design-docs/user-qa/tauri-client-apps.md`. Because `README.md` is what
  actually tells a reader to run `mise run tauri:build`, that section must
  carry the same caveat; a constraint stated only here does not reach the
  person running the build.
- Tracked in git: the Rust shell, `Cargo.lock`, the capability file, icons, the
  XcodeGen inputs under `gen/apple/` (`project.yml`, `Info.plist`, entitlements,
  `LaunchScreen.storyboard`, `Assets.xcassets`, `Podfile`, `ExportOptions.plist`,
  generated Objective-C++ entry point and bindings), and **both ignore files**:
  the root `.gitignore` and the nested `web/src-tauri/gen/apple/.gitignore` that
  Tauri writes. The nested file is untracked today and is the only source of the
  `Externals/` and `xcuserdata/` rules, so omitting it publishes a tree where
  those paths are unignored for every clone.
- Ignore rules by provenance, because only one of them predates this change:
  - Pre-existing: `*.xcodeproj/` (root `.gitignore:9`), which already excludes
    the derived `gen/apple/kaiba-client.xcodeproj/`.
  - Added by this change set to the root `.gitignore`: `web/src-tauri/target/`,
    `web/src-tauri/gen/apple/build/`, `web/src-tauri/gen/schemas/`.
  - Supplied only by the nested `gen/apple/.gitignore`: `Externals/`,
    `xcuserdata/`, and `build/` again.
  Both ignore files must land in the same commit as the files they exclude.
  Locally this is invisible — git honors an uncommitted `.gitignore` on disk, so
  staging today already skips the generated paths. The damage shows up in the
  next clone and in CI, where neither rule exists and `target/`, `gen/schemas/`,
  `Externals/` and `xcuserdata/` become committable noise.
- The Xcode project is regenerated from the tracked inputs by
  `mise run tauri:ios:init`, so regeneration produces no repository churn. One
  consequence of the split: the tracked `capabilities/default.json` carries
  `"$schema": "../gen/schemas/desktop-schema.json"` while `gen/schemas/` is
  ignored, so a fresh clone has a dangling schema reference until the first
  native build regenerates it. This affects editor completion only, not the
  build.
- Apple signing, provisioning, notarization, and App Store upload remain
  release-time concerns and are not part of this change.
