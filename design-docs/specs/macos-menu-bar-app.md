# macOS Menu-Bar App

## Status

Accepted (2026-08-23). Initial implementation.

## Summary

- The Cask release ships a real macOS app bundle, `Kaiba.app`, in addition to
  the `kaiba` CLI. Launching it makes kaiba a **resident menu-bar app**: it runs
  the note server in-process and stays up in the status bar until quit.
- The app is an **accessory** app (`LSUIElement`): no Dock tile, no window, just
  an `NSStatusItem` whose menu shows server status and offers Open web UI,
  Start/Stop, Start-at-login, and Quit.
- On launch it **auto-starts** the server on loopback in authenticated mode
  (the same bootstrap as `kaiba serve`), and it can **register as a Login Item**
  so it is resident across reboots.
- Both entry points share one bootstrap, `KaibaServerRuntime`, so the app and
  the CLI stand up an identical server over the same store.

## Motivation

`kaiba serve` is a foreground process that blocks until interrupted. Running the
note server as a background service therefore meant wiring up `nohup`, a
`launchd` plist, or a terminal left open. The product is a "system-memory
service for AI agents" (the Cask `desc`), which is exactly the kind of thing a
person expects to launch once and forget. A menu-bar app is the idiomatic macOS
answer: double-click to start, glance at the menu bar to see it running, toggle
launch-at-login once.

Before this change the Cask staged only the bare CLI binary (`binary "kaiba"`),
so there was no `.app` to launch at all.

## Design Decisions

- **M1 — Accessory menu-bar app, not a windowed app.** `setActivationPolicy(.accessory)`
  plus `LSUIElement=true` keeps kaiba out of the Dock and the app switcher. A
  resident background service should not own a window or steal focus; its entire
  surface is the status-bar menu.

- **M2 — One shared bootstrap (`KaibaServerRuntime`).** The server setup —
  driver, `NoteService`, AI dispatcher, GraphQL executor, authenticator, route
  handlers, and the `KaibaLocalHTTPServer` — moved out of `ServeCommand.run`
  into `KaibaServerRuntime` (an actor in `AppServer`). `kaiba serve` now prints
  the runtime's `start()` result and blocks; the app shows it in a menu and
  calls `stop()` on quit. There is no second implementation of the server to
  drift.

- **M3 — Auto-start on launch, loopback + authenticated.** The app starts the
  server when it launches. It always binds `127.0.0.1` in authenticated mode
  (`--allow-unauthenticated` is not offered): a background app the person may
  forget is running must never be the thing that opens the store to the network.
  The menu can Stop and Start it again within the session.

- **M4 — Login Item via `SMAppService`.** "Start at login" registers the app
  with `SMAppService.mainApp` (`register()`/`unregister()`), the modern
  replacement for login-item shims. The menu item reflects the current
  `status` and toggles it. This is what makes "resident" survive a reboot.

- **M5 — Same store as the CLI.** The app resolves its note root and
  `config.json` through the same `AppCommand.resolveNoteRoot` /
  `resolveConfigPath` the CLI uses, so `Kaiba.app` and `kaiba` on the same Mac
  operate one store. Auth (the JWT signing key, `api_clients`) is shared for
  free because it lives in that store.

- **M6 — Optional bundled SPA.** If the app bundle carries the built reader at
  `Contents/Resources/web`, the runtime serves it as the web root and "Open web
  UI" lands on the reader; otherwise the menu still opens the API endpoint. The
  bundle works with or without the SPA staged.

- **M7 — Clean shutdown.** Quit stops the runtime (releasing the port and
  closing the sqlite handle) before `NSApplication.terminate`, so a relaunch
  does not race a still-bound port.

- **M8 — A stylized brain icon, shared with the web app.** The status item
  shows a stylized brain (two hemispheres, central fissure, gyri), matching the
  web app favicon (`web/public/favicon.svg`) so the CLI-served reader and the
  menu-bar app read as one product. The menu icon is a monochrome, stroke-only
  version of the same shape, embedded in `KaibaMenuBarAppDelegate` and loaded as
  a **template** `NSImage` so macOS tints it to the menu-bar appearance
  (light/dark, active/inactive). If SVG decoding ever fails it falls back to the
  `brain` SF Symbol, itself a stylized brain, so the icon is always a brain.

## Packaging

- `packaging/macos/Info.plist.template` — the bundle's `Info.plist` with
  `LSUIElement`, `CFBundleIdentifier=dev.kaiba.Kaiba`,
  `CFBundleExecutable=KaibaApp`, `LSMinimumSystemVersion=14.0`, and `@VERSION@`
  placeholders.
- `scripts/assemble-macos-app-bundle.sh` — pure, unsigned bundle staging from a
  built `KaibaApp` binary (and optional built SPA). Runs locally without Apple
  credentials, so the bundle layout is testable.
- `scripts/build-homebrew-cask-release.sh` — builds the `KaibaApp` release
  product per target, assembles the bundle, signs the nested executable and then
  the `.app` under the hardened runtime, and stages `Kaiba.app` into the same
  DMG as the `kaiba` CLI. The existing notarize/staple/`spctl` flow is unchanged.
- `scripts/render-homebrew-cask.sh` — the cask now declares both
  `app "Kaiba.app"` and `binary "kaiba"`, so `brew install --cask kaiba` puts
  Kaiba in `/Applications` and links the CLI into the Homebrew prefix.

## Targets

- `KaibaApp` — new executable target (`Sources/KaibaApp`), depends on `AppCore`
  and `AppServer`. `main.swift` installs the accessory `NSApplication`;
  `KaibaMenuBarAppDelegate` (`@MainActor`) owns the status item and drives the
  runtime. Everything is guarded by `#if canImport(AppKit)` with a
  macOS-only fallback so a Linux build of the package still compiles.

## Non-Goals

- A windowed or Dock app, a preferences window, or an embedded browser.
- Multiple concurrent servers or per-window instances; the app owns one runtime.
- Auto-updates (Sparkle); the Cask's `livecheck` handles version discovery.
- Exposing `--allow-unauthenticated` / `--as-admin` from the app (M3). Those
  stay CLI-only, where the operator types them explicitly.

## Verification

- `AppServerTests/KaibaServerRuntimeTests`: configuration defaults are loopback
  and authenticated; `start()` binds a real socket, reports the endpoint and an
  authenticated registration URL, answers `/healthz` over HTTP, and `stop()`
  tears the server down; an unauthenticated configuration reports the
  unauthenticated mode.
- `kaiba serve` continues to print the same `endpoint=` / `noteRoot=` /
  `registrationURL=` banner it always did (now sourced from the runtime).
- `scripts/assemble-macos-app-bundle.sh` produces a bundle whose `Info.plist`
  carries the version and `LSUIElement`, verified with `PlistBuddy`.
- `scripts/build-homebrew-cask-release.sh --dry-run` lists the staged app
  bundle; `scripts/render-homebrew-cask.sh` emits a cask with `app "Kaiba.app"`.
