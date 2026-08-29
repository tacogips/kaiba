# Tauri Client Apps

## Status

Accepted (2026-08-29). Initial implementation.

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
  the endpoint that issued it: changing the configured origin drops the stored
  credential, so a key issued by one server is never presented to another.

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
authenticating. Saving a new endpoint reloads the WebView so every cached
client and subscription re-resolves against the new origin.

iPhone layout uses `viewport-fit=cover` with `env(safe-area-inset-*)` padding
on the document body, so the shared UI clears the notch and home indicator
without a phone-specific layout branch.

## Native permissions

The Tauri capability permits `http://**` and `https://**` because the actual
host is user-configurable and cannot be enumerated at build time. Endpoint
validation is therefore the effective guard on which origins the app contacts.
The HTTP plugin is built with `unsafe-headers`, which lifts the WebView's
forbidden-header restrictions on native requests. That is broader than the
client needs today: it sets only `Authorization` and `Content-Type`. The
feature should be dropped if no native request comes to require a restricted
header.

The WebView content-security policy is disabled (`"csp": null`). The client
renders no server-supplied HTML, so there is no injection sink to constrain
today, and a policy tight enough for the Vite dev server and the packaged
`tauri://` origin would have to be maintained by hand for both. A CSP must be
defined before the client renders any HTML it did not author.

`saveServerEndpoint` clears the stored bearer whenever the normalized origin
differs from the one currently in effect, and keeps it when the same origin is
re-saved. This is a client-side invariant, not a consequence of server
behavior: the only clear-on-failure path in the client is a 401 from the
GraphQL route, so it does not cover the note-events long poll, attachment
fetches or the agent-stream poll, and a server started with
`kaiba serve --allow-unauthenticated` never emits 401 at all. Without the
clear, repointing the client would send the previous server's credential to the
new host on every request for the life of the install.

Residual risk accepted for this release: the bearer lives in WebView local
storage and travels in plaintext when a user configures a non-loopback `http`
endpoint. The app does not downgrade or upgrade schemes on the user's behalf.
Requests leave through the Rust shell rather than `URLSession`, so iOS App
Transport Security does not apply and no OS-level warning is raised.

## Build surfaces

- `mise run tauri:dev` runs the macOS app against the Vite development server.
- `mise run tauri:build` produces the macOS application bundle.
- `mise run tauri:ios:init` generates the Tauri Xcode project when needed.
- `mise run tauri:ios:dev` runs the iPhone app for development.
- `mise run tauri:ios:build` builds the iPhone application.

The Vite dev server is pinned to port 1420 with `strictPort`, and binds a
non-loopback host only when `TAURI_DEV_HOST` is set, which is what lets a
physical iPhone reach a development build.

Validation gates are `mise run web:check` (typecheck, test, lint, build),
`mise run tauri:check` (`cargo fmt --check`, `cargo check`, `clippy -D
warnings`), and `mise run test` for the Swift suites.

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
