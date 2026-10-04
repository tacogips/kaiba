# P19 Server runtime controller: resolve, attach, hot-swap and disable without restart

**Status**: Completed. Accepted in session-264 (test-integrity, adversarial and integration review, comm-003910). The wave-8 serial repair RECON-W8-P19-TEST-RACE added a bounded wait in `Tests/AppServerTests/SearchEngineRuntimeControllerTests.swift`, and the combined-tree reconcile passed (`tmp/search-engine-adapter/reconcile/session-264-wave8/reconcile-summary.md`). Archived to `impl-plans/completed/` at Step 8 on 2026-10-05.
**planId**: P19-runtime-controller
**Wave**: 4
**dependsOn**: P8-server-sync-loop, P17-settings-core
**Design Reference**: `design-docs/specs/search-engine-adapter.md` D5 "Hot-swap" and "Sources and precedence"; "Delta scope and changed base rules" (invariant 1 rewording); SE3 "Who drains"
**Index**: `impl-plans/completed/search-engine-adapter.md`

## Intent and context

P8 wires a fixed engine from the config file into `KaibaServerRuntime` and runs one `SearchIndexSyncLoop`. D5 needs more than that:

1. The engine comes from the shared resolver: the config section, then store settings, then none.
2. A stored-settings error at start is not fatal: log it and run FTS-only. A config-section error stays fatal.
3. Saving settings hot-swaps the engine for every `NoteService` copy through the shared `SearchEngineSlot`. The old loop is stopped and awaited, and a new loop is started. An identity change backfills through activation.
4. Choosing `none` detaches the engine and stops the loop.
5. The change-event kick observer is always installed, and is a no-op when no loop runs.

Repository facts:

- **P8 (wave 1).**
  - `Sources/AppServer/SearchIndexSyncLoop.swift`: `actor SearchIndexSyncLoop(engine:tickInterval:debounce:log:)` with `start(service:)`, `nonisolated kick()`, `stop()`, `SearchIndexSyncKickObserver` and `FanOutNoteChangeObserver`.
  - Wiring in `KaibaServerRuntime.start`, plus `isSearchEngineAttachedForTesting`.
- **P12.**
  - `SearchEngineSlot`: `engine`, `replace`, `setManagedConfiguration`, `setEnvironment`, `setReloadHandler` and `reload`.
  - `NoteService.init(..., searchEngineSlot:)`.
- **P17.**
  - `NoteService.resolveSearchEngineSettings(configuration:)`;
  - `makeResolvedSearchEngine(configuration:environment:)`, which throws `KaibaConfigurationError` for the config case and `SearchEngineSettingsError.invalid` for the store case;
  - `SearchEngineSettingsResolution`.
- **Runtime.** `KaibaServerRuntime.swift`:
  - the dispatcher's own `NoteService(driver:)` is built at about line 145;
  - the main service at about line 158;
  - copies are passed to GraphQL, routers and the authenticator.

## Non-goals

- No GraphQL change; P18 owns it.
- No change to the drain algorithm or the loop cadence.
- No new configuration knob.
- No admin HTTP endpoint.

## writePaths

- `Sources/AppServer/SearchEngineRuntimeController.swift` (new)
- `Sources/AppServer/KaibaServerRuntime.swift`
- `Tests/AppServerTests/SearchEngineRuntimeControllerTests.swift` (new)
- `Tests/AppServerTests/SearchEngineServerRuntimeTests.swift`
- `impl-plans/completed/search-engine-adapter-p19-runtime-controller.md`

## sharedPaths (read-only)

- `Sources/AppServer/SearchIndexSyncLoop.swift`: read-only. The P8 loop and observers. Reuse them; do not change them.
- `Sources/AppCore/SearchEngineSlot.swift`: read-only. The P12 slot.
- `Sources/AppCore/SearchEngineSettingsResolver.swift`: read-only. The P17 resolver.
- `Sources/AppCore/SearchEngineFactory.swift`: read-only. Factory config validation.
- `Sources/AppCore/NoteService.swift`: read-only. The init `searchEngineSlot` parameter.
- `Sources/AppServer/NoteChangeFeed.swift`: read-only. `NoteChangeFeedObserver`.

## File-level changes

### `SearchEngineRuntimeController.swift` (new)

```swift
actor SearchEngineRuntimeController {
  init(slot: SearchEngineSlot,
       makeEngine: @escaping @Sendable (NoteService) throws -> (any SearchEngine)?,
       makeLoop: @escaping @Sendable (any SearchEngine) -> SearchIndexSyncLoop,
       log: @escaping @Sendable (String) -> Void)
  func start(service: NoteService) async
  func reload() async -> SearchEngineReloadOutcome
  nonisolated func kick()
  func stop() async
}
```

- **Default `makeEngine`, built in the runtime.** It is `{ try $0.makeResolvedSearchEngine(configuration: config.searchEngine, environment: environment) }`. Tests inject fakes.
- **`start(service:)`.**
  - Remember the service.
  - Install `slot.setReloadHandler { [weak self] in await self?.reload() ?? .init(active: false, indexIdentity: nil) }`. Capture strongly if `weak` is awkward for an actor, and clear the handler in `stop()`.
  - Then perform the same steps as reload.
- **`reload()`.**
  1. When `slot.managedConfiguration != nil` and the loop is already running, return the current outcome. It is a no-op.
  2. Otherwise, `engine = try makeEngine(service)`.
     - On a `SearchEngineSettingsError`, log `kaiba search-engine: stored settings invalid: <field>` and treat the engine as nil.
     - On any other error, log a sanitized message, using only the error type name, and treat it as nil.
  3. `await currentLoop?.stop()`.
  4. `slot.replace(engine)`.
  5. When the engine is non-nil, `let loop = makeLoop(engine)`, `await loop.start(service: service)`, and store it.
  6. Return `SearchEngineReloadOutcome(active: engine != nil, indexIdentity: engine?.indexIdentity)`.
- **`kick()`.** It is `nonisolated` and non-blocking. Keep the current loop reference in a small lock-protected `final class LoopBox: @unchecked Sendable`, so `kick()` can read it synchronously and call `loop.kick()`.
- **`stop()`.** Stop the loop, clear the box, clear the reload handler, and run `slot.replace(nil)`.
- **`SearchEngineControllerKickObserver: NoteChangeObserving`.** It calls `controller.kick()`.

### `KaibaServerRuntime.swift`

Replace P8's search wiring:

1. `let searchEngineSlot = SearchEngineSlot()`, then `searchEngineSlot.setManagedConfiguration(config.configuration.searchEngine)` and `searchEngineSlot.setEnvironment(config.environment)`.
2. **Fatal config validation.** Keep P8's early `_ = try SearchEngineFactory.make(configuration: config.configuration.searchEngine, environment: config.environment)` before building services. It is only a validation. A config error still fails start.
3. **Controller first.** Create the controller before the services. Then the observer is always `FanOutNoteChangeObserver([NoteChangeFeedObserver(feed: changeFeed), SearchEngineControllerKickObserver(controller: controller)])`.
4. **Shared slot.** Pass `searchEngineSlot: searchEngineSlot` to both the dispatcher's `NoteService` and the main `NoteService`. Remove P8's `service.searchEngine = ...` assignment.
5. **Start and stop.** After bind, `await controller.start(service: service)`. In `stop()`, `await controller.stop()`.
6. **Testing accessor.** Replace `isSearchEngineAttachedForTesting` so it returns `searchEngineSlot.engine != nil`. Keep the name so P8's tests compile.
7. **Budget.** The file stays under 380 lines.

### `SearchEngineServerRuntimeTests.swift` (P8's)

Update the expectations to the new semantics, keeping their intent:

- No section and no store settings -> start succeeds, and the accessor is false.
- An unreachable configured URL -> start does not block, and the accessor is true.
- `kind: opensearch` -> start throws mentioning `searchEngine.kind`.

## Pitfalls

- **Start must never wait on the network.** `makeEngine` only constructs. `ensureIndex` and activation run inside the loop.
- **Ordering in reload.** Stop the old loop before starting the new one, so no two loops drain at once. Replace the slot between them.
- **Actor re-entrancy.** Two concurrent `reload()` calls interleave at `await`. Guard with a reload generation counter, or serialize by chaining on a stored `Task`. The last call to finish must leave the slot equal to the result of a `makeEngine` call made after the last settings write, and exactly one loop must run. Test this.
- **The kick must not await.** It is called synchronously from `noteStoreDidChange`.
- **Sanitized logs.** Never interpolate settings, URLs with credentials, or errors that may contain secrets. Log field names and error type names only.
- **Config-managed stores.** `reload()` is a no-op after start. The GraphQL layer already rejects mutations, so this is defense in depth.

## Tests (`SearchEngineRuntimeControllerTests`, XCTest)

Use a temporary store. The `AppServerTests` target cannot see `Tests/AppCoreTests/FakeSearchEngine.swift`, so define a private recording fake engine in this test file. Imitate the private fake in P8's `Tests/AppServerTests/SearchIndexSyncLoopTests.swift`, with a settable `indexIdentity` and recorded `apply` batches. `makeEngine` returns instances of that fake chosen per test, and `makeLoop` builds `SearchIndexSyncLoop(engine:tickInterval: .milliseconds(100), debounce: .milliseconds(20), log:)`.

- Start with an engine -> `slot.engine` is set. A scoped copy (`service.scoped(...)` or a plain copy) sees it. The loop drains a created note within 2 seconds, so the fake records an upsert.
- `makeEngine` throws `SearchEngineSettingsError.invalid(field: "searchEngine.url")` -> `start` completes, `slot.engine` is nil, and the log contains `stored settings invalid: searchEngine.url`.
- Reload from identity A to B -> after reload, `slot.engine` has identity B, the old fake receives no apply after the reload returns, and the outbox was re-enqueued for every note (an activation backfill). Assert that `searchIndexOutboxStatus().pending` reaches the note count or that B receives upserts for all notes.
- Reload to nil -> `slot.engine` is nil, `isSearchEngineEnabled` is false on a copy, and further kicks cause no applies.
- Two concurrent reloads -> exactly one loop is active afterwards, verified because only one fake receives new applies after a write and kick.
- Managed configuration set -> after start, reload returns the same identity and `makeEngine` is not called again.
- The slot reload handler is installed after start, and `slot.reload()` returns a non-nil outcome. It is cleared after stop.

## Verification

```bash
mise run build
bash -c 'mkdir -p tmp/search-engine-adapter/P19 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter SearchEngineRuntimeController 2>&1 | tee tmp/search-engine-adapter/P19/controller.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P19 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter SearchEngineServerRuntime 2>&1 | tee tmp/search-engine-adapter/P19/runtime.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P19 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter AppServerTests 2>&1 | tee tmp/search-engine-adapter/P19/server-suite.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P19 && mise run lint 2>&1 | tee tmp/search-engine-adapter/P19/lint.log; echo exit=${PIPESTATUS[0]}'
grep -n "searchEngineSlot\|SearchEngineRuntimeController\|SearchEngineControllerKickObserver" Sources/AppServer/KaibaServerRuntime.swift
wc -l Sources/AppServer/KaibaServerRuntime.swift Sources/AppServer/SearchEngineRuntimeController.swift
```

Expected evidence:

- Every `swift test` run shows `exit=0` with an XCTest `Executed N tests, 0 failures`, N > 0, including the full `AppServerTests` suite.
- `KaibaServerRuntime.swift` is under 380 lines.

## Done criteria

- [x] The runtime shares one slot across every service, and the controller resolves, attaches, hot-swaps and detaches.
- [x] A stored-settings error is non-fatal; a config error is still fatal.
- [x] Concurrent reloads converge on one loop, and the kick is always installed and non-blocking.
- [x] All verification shows `exit=0` with positive counts.

## Progress Log

- 2026-10-04: Plan created (session-264).
- 2026-10-05: Implemented the runtime controller and shared-slot server wiring. The controller serializes reload and stop operations across actor suspension, awaits the old loop before replacing the slot, installs a lock-backed synchronous kick path, logs stored-setting failures by field only, and treats config-managed reloads as no-ops after initial resolution. `KaibaServerRuntime` keeps early config validation fatal, shares one slot with dispatcher and main services, always installs the feed/controller observer, starts after bind, and stops the controller with the server.
- 2026-10-05: Final-source verification passed: `mise run build` (exit 0); `swift test --filter SearchEngineRuntimeController` (7/7, exit 0; `tmp/search-engine-adapter/P19/controller-attempt-6.log`); `swift test --filter SearchEngineServerRuntime` (3/3, exit 0; `runtime.log`); full `swift test --filter AppServerTests` (128 run, 1 skipped, 0 failures, exit 0; `server-suite.log`); selected-file strict SwiftLint on the three changed Swift files (exit 0); and `mise run lint` (exit 0, 13 repository-wide non-serious diagnostics, none in changed P19 files). `KaibaServerRuntime.swift` is 346 lines; controller is 150 lines.
- 2026-10-05: Superseded attempts are retained in `tmp/search-engine-adapter/P19/controller-attempt-{1,2,3,4,5}.log`: attempt 1 found explicit Swift 6 closure captures, attempt 2 found an async XCTest polling expression, attempt 3 exposed a test fixture using a different slot from the controller, and attempts 4-5 were blocked by concurrent P18 GraphQL test compile errors. The fixture now passes the shared slot, and attempt 6 compiled and passed all seven controller tests on the current source.
- 2026-10-05: Resolved test-integrity finding `TI-P19-REPLACED-LOOP-STOP-UNOBSERVED` (comm-003878) in `Tests/AppServerTests/SearchEngineRuntimeControllerTests.swift`: added a lock-protected loop recorder; identity-change, detach, and concurrent-reload tests directly kick each replaced loop and verify no fresh probe note reaches its engine within 200 ms. The concurrent test records all three loops, probes both replaced loops, then directly kicks the final loop as a positive control and verifies the receiving engine identity matches `slot.engine`. Restored-source evidence: controller 7/7 (`controller-restored-attempt-7.log`, exit 0), runtime 3/3 (`runtime-attempt-7.log`, exit 0), full AppServerTests 128 run / 1 env-gated skip / 0 failures (`server-suite-attempt-7.log`, exit 0), strict selected-file SwiftLint using `changed-swift-files-attempt-7b.nul` (`swiftlint-changed-attempt-7b.log`, exit 0), and `mise run lint` (`lint-attempt-7.log`, exit 0; 3 non-serious repository-wide violations). Negative control: removing the reload stop made the identity, detach, and concurrent probe assertions fail (7 run / 3 failures, exit 1; `negative-control-no-stop.log`); restored controller hash verified OK by `shasum -a 256 -c controller-source.sha256`. `KaibaServerRuntime.swift` remains 346 lines and `SearchEngineRuntimeController.swift` 150 lines.
