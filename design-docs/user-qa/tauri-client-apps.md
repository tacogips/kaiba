# Tauri Client Apps — Decisions

Design reference: `design-docs/specs/tauri-client-apps.md`

Recorded 2026-08-29 while closing out the Tauri client implementation plan.

## Answered

### Which generated Apple files belong in git?

The XcodeGen inputs under `web/src-tauri/gen/apple/` are tracked; the derived
`kaiba-client.xcodeproj`, `build/`, `Externals/`, and `gen/schemas/` are not.
The repository's pre-existing `*.xcodeproj/` ignore rule already covers the
derived project, so `mise run tauri:ios:init` regenerates it without churn.

### Is `web/src-tauri/Cargo.lock` tracked?

Yes. The shell is an application crate, so its lockfile is committed to keep
native builds reproducible.

### Does the browser client honor a stored endpoint?

No. Endpoint storage and the endpoint UI are native-only. The served web client
stays same-origin regardless of what is in local storage.

## Pending

### Do native clients get their own release channel and name?

Status: Pending

The macOS bundle and iPhone app currently ride the Swift package version and
have no CHANGELOG entry, Homebrew Cask, or App Store pipeline of their own.
Signing, provisioning, notarization, and distribution are deferred to release
time and remain unowned.

The name is part of this decision. `productName` is `Kaiba`, so a macOS build
produces `Kaiba.app` — the same installed name as the resident menu-bar app
from `design-docs/specs/macos-menu-bar-app.md`, which the Homebrew Cask already
puts in `/Applications`. The identifiers differ (`com.tacogips.kaiba` versus
`dev.kaiba.Kaiba`), so nothing is overwritten, but two apps cannot ship under
one name. Options:

1. Rename the Tauri `productName` to `Kaiba Client`, matching the
   `kaiba-client` crate and the `kaiba-client_iOS` Apple target. This also
   rewrites `PRODUCT_NAME` in the tracked `gen/apple/project.yml`, so it
   requires a follow-up `mise run tauri:ios:init` in the same commit.
2. Rename the menu-bar app instead and keep `Kaiba` for the client.
3. Keep both names and never distribute the client bundle.

Until this is answered the client bundle stays build output only and is not
installed to `/Applications`.

### Are full macOS and iPhone builds a close-out gate?

Status: Pending

`mise run web:check`, `mise run tauri:check`, and `mise run test` are the gates
that run per change. Whether `mise run tauri:build` and `mise run
tauri:ios:build` must also pass before landing client changes is unresolved;
both are slow and the iPhone build needs Apple signing setup.

Evidence already in the tree for the plan's 'verify macOS/iPhone builds'
deliverable: `web/src-tauri/gen/apple/build/` holds `arm64-sim/` and
`kaiba-client_iOS.xcarchive` from a real iPhone build. That directory is
ignored, so the evidence is local only and does not survive a fresh clone —
which is exactly why the gate question matters.

### Should a non-loopback `http` endpoint be blocked or warned?

Status: Pending

The endpoint validator accepts any `http` host, so a LAN address sends the
bearer in plaintext. Options are to keep the current behavior, warn in the
settings form, or require HTTPS for non-loopback hosts.
