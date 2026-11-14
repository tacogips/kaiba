# P8 Server wiring: engine construction, sync loop, change-event kick

**Status**: Completed. Accepted in session-264 (test-integrity, adversarial and integration review, comm-003910). The combined-tree wave-8 reconcile passed (`tmp/search-engine-adapter/reconcile/session-264-wave8/reconcile-summary.md`). Archived to `impl-plans/completed/` at Step 8 on 2026-10-05.
**planId**: P8-server-sync-loop
**Wave**: 1 (session-264)
**dependsOn**: P2-store-outbox, P3-elasticsearch-adapter, P4-sync-drain, P5-engine-query-service. P2, P4 and P5 are accepted dependencies, not redispatched. P3's code is complete in b466ced.
**Session-264 note**: Implement this plan as written. In the same wave, P12-delta-contract makes `NoteService.searchEngine` a computed property over a shared `SearchEngineSlot`. `service.searchEngine = searchEngine` keeps compiling and now updates every copy. In wave 4, P19-runtime-controller replaces this plan's runtime wiring with a controller that hot-swaps the engine. Keep `SearchIndexSyncLoop`, `SearchIndexSyncKickObserver` and `FanOutNoteChangeObserver` exactly as specified, because P19 reuses them unchanged. Verification records must be gate-compatible: each `swift test` record shows `exit=0` with an XCTest `Executed N tests, 0 failures`, N > 0.
**Design Reference**: `design-docs/specs/search-engine-adapter.md` SE3 "Who drains", SE2 (fatal configuration errors at server start), Invariants 1 and 2
**Index**: `impl-plans/completed/search-engine-adapter.md`

## Intent and context

When `kaiba serve` (or the macOS app, through the same runtime) starts with
an engine configured, the server does four things:

1. builds the adapter through the factory;
2. attaches it to the `NoteService` that GraphQL uses, so the capability is
   true and the engine queries work;
3. runs one background sync loop that prepares the index, activates sync,
   and drains on a fixed 15-second tick and after any note change event,
   debounced to 1 second;
4. stops the loop when the server stops.

When no engine is configured, nothing changes: no loop runs and no observer
wrapping happens.

Repository facts:

- `Sources/AppServer/KaibaServerRuntime.swift` is an actor.
  - `start(allowsEphemeralPort:)` builds `driver`, then `dispatcher`, then
    `let service = try NoteService(driver:autoActionDispatcher:changeObserver: NoteChangeFeedObserver(feed: changeFeed))`.
  - The existing periodic `maintenance` Task pattern is at about line 175,
    and `stop()` cancels it.
- `NoteChangeFeedObserver` is in `Sources/AppServer/NoteChangeFeed.swift:355`.
- `NoteChangeObserving.noteStoreDidChange` is synchronous and fire-and-forget
  (`Sources/AppCore/NoteChangeObserving.swift`).

## Non-goals

- No new configuration knobs. The cadence is fixed.
- No admin HTTP or GraphQL endpoint.
- No change to how GraphQL is wired, beyond assigning `service.searchEngine`.

## writePaths

- `Sources/AppServer/SearchIndexSyncLoop.swift`
- `Sources/AppServer/KaibaServerRuntime.swift`
- `Tests/AppServerTests/SearchIndexSyncLoopTests.swift`
- `Tests/AppServerTests/SearchEngineServerRuntimeTests.swift`
- `impl-plans/completed/search-engine-adapter-p8-server-sync-loop.md`

New files: `Sources/AppServer/SearchIndexSyncLoop.swift`, `Tests/AppServerTests/SearchIndexSyncLoopTests.swift`, `Tests/AppServerTests/SearchEngineServerRuntimeTests.swift`.

## sharedPaths (read-only)

- `Sources/AppCore/SearchEngineFactory.swift`
- `Sources/AppCore/SearchIndexSynchronizer.swift`
- `Sources/AppCore/SearchEngineSyncOutbox.swift`
- `Sources/AppCore/NoteService.swift`
- `Sources/AppServer/NoteChangeFeed.swift`

## sharedPathNotes

- `Sources/AppCore/SearchEngineFactory.swift`: read-only: P3 factory.
- `Sources/AppCore/SearchIndexSynchronizer.swift`: read-only: P4
  `drainUntilIdle`.
- `Sources/AppCore/SearchEngineSyncOutbox.swift`: read-only: P2
  `activateSearchEngineSync`.
- `Sources/AppCore/NoteService.swift`: read-only: the P5 `searchEngine`
  property.
- `Sources/AppServer/NoteChangeFeed.swift`: read-only: `NoteChangeFeedObserver`.

Reading references (not path declarations): existing AppServerTests that start
a runtime with `startForTesting()`. Read them to learn how
`KaibaServeConfiguration` is built.

## File-level changes

### `Sources/AppServer/SearchIndexSyncLoop.swift` (new)

- `actor SearchIndexSyncLoop` (internal) has this init:
  `init(engine: any SearchEngine, tickInterval: Duration = .seconds(15), debounce: Duration = .seconds(1), log: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })`.
- `func start(service: NoteService)` starts exactly one Task. A second call
  is a no-op. The Task loops until cancelled:
  1. **Prepare.** Until prepared, call `try await engine.ensureIndex()`,
     then `try service.activateSearchEngineSync(indexIdentity: engine.indexIdentity)`.
     On error, log the sanitized message `kaiba search-engine: index not ready`
     and skip draining this round. Engine error descriptions are not emitted
     because transports may include sensitive connection details.
  2. **Drain.** When prepared, call
     `try await SearchIndexSynchronizer(service:).drainUntilIdle(engine:)`.
     On error, log it. When `report.failed > 0`, log
     `kaiba search-engine: <n> note(s) failed to sync`.
  3. **Wait.** Wait until a kick arrives or `tickInterval` elapses. After a
     kick, sleep `debounce` and swallow further kicks during that window,
     so they coalesce into one pass.
- `nonisolated func kick()` is callable from synchronous code. It signals
  the waiting loop, for example through an `AsyncStream<Void>` continuation
  created in init with the `.bufferingNewest(1)` policy, so kicks coalesce.
- `func stop() async` cancels the Task and awaits its completion.
- Drains never overlap: one Task runs them sequentially.
- `struct SearchIndexSyncKickObserver: NoteChangeObserving` holds the loop
  and calls `loop.kick()` on every event.
- `struct FanOutNoteChangeObserver: NoteChangeObserving` holds
  `[any NoteChangeObserving]` and forwards each event to every observer, in
  order.

### `Sources/AppServer/KaibaServerRuntime.swift`

1. **Engine.** Before building the main `service`, build
   `let searchEngine = try SearchEngineFactory.make(configuration: config.configuration.searchEngine, environment: config.environment)`.
   Configuration errors propagate and the server does not start, which is
   the same treatment `makeDriver` errors get.
2. **Observer.** When `searchEngine` is non-nil:
   - create `let syncLoop = SearchIndexSyncLoop(engine: searchEngine)`;
   - set the observer to
     `FanOutNoteChangeObserver([NoteChangeFeedObserver(feed: changeFeed), SearchIndexSyncKickObserver(loop: syncLoop)])`.

   Otherwise keep exactly `NoteChangeFeedObserver(feed: changeFeed)`.
3. **Service.** Make `service` a `var` and assign
   `service.searchEngine = searchEngine` right after construction, before
   it is passed to `GraphQLNoteGraphQLService`, the routers or the
   authenticator. Every copy must carry the engine.
4. **Loop start.** After the server binds, start the loop:
   `await syncLoop.start(service: service)`. Store it in a new
   `private var searchSync: SearchIndexSyncLoop?`.
5. **Stop.** In `stop()`, call `await searchSync?.stop()` and then set
   `searchSync = nil`, next to the `maintenance` cancellation.
6. **Do not touch the dispatcher.** Leave the separate `NoteService` built
   for the auto-action dispatcher alone. It does not need the engine.
7. **Budget.** Add at most about 30 lines. The file is 312 lines now.

## Pitfalls

- **Start-up must not wait on the engine.** Never call `ensureIndex` or
  `drain` inline in `start()`. An unreachable engine must not delay or fail
  start-up. Only factory configuration errors are fatal.
- **Construction order.** The observer must exist before the service is
  constructed, and the loop needs the service. That is why the loop is
  created first with only the engine, and receives the service in
  `start(service:)`.
- **The kick must not block.** `noteStoreDidChange` is synchronous. `kick()`
  must be `nonisolated` and non-blocking: yield to the continuation, with no
  `await`.
- **Unconfigured parity.** Without an engine the observer type and wiring
  must be identical to today.
- **Concurrency.** Swift 6 strict concurrency applies. The loop is an actor,
  and the observers are `Sendable` structs.

## Tests

`SearchIndexSyncLoopTests` (XCTest, AppServerTests):

- Define a private fake `SearchEngine` in this file that records ensureIndex
  and apply calls, has a togglable failure, and an `onApply` expectation
  hook. Use a temporary store from `NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot:))`.
- Cases:
  - Start with `tickInterval 0.2s` and `debounce 0.05s`. ensureIndex is
    called and the store is activated, so the outbox state row exists.
    Create a note, then `kick()`: within 2 seconds the fake has received an
    upsert for it.
  - With an engine whose ensureIndex fails first and then succeeds, the
    loop retries on the tick and eventually drains. Nothing crashes, and
    the log closure received "index not ready".
  - Ten kicks in a burst cause at most 2 apply calls for one pending note.
  - After `stop()`, a new note write followed by `kick()` causes no further
    apply calls within 0.5 seconds.

`SearchEngineServerRuntimeTests` (XCTest, AppServerTests; reuse the runtime
`startForTesting()` pattern from existing AppServerTests):

- P6, which owns the GraphQL capability field, runs in parallel, so these
  tests must not query GraphQL. Instead, add one internal read-only
  accessor to the runtime, `var isSearchEngineAttachedForTesting: Bool`.
  It is true when `searchSync != nil`.
- Cases:
  - No `searchEngine` section: start succeeds, and the accessor is false.
  - A section with `url: http://127.0.0.1:1` (unreachable) and kind
    elasticsearch: start succeeds without waiting on the engine, the
    accessor is true, and `stop()` returns.
  - `kind: opensearch`: `start` throws, and the error mentions
    `searchEngine.kind`.

## Verification

```bash
mise run build
bash -c 'mkdir -p tmp/search-engine-adapter/P8 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter SearchIndexSyncLoop 2>&1 | tee tmp/search-engine-adapter/P8/loop.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P8 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter SearchEngineServerRuntime 2>&1 | tee tmp/search-engine-adapter/P8/runtime.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P8 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter AppServerTests 2>&1 | tee tmp/search-engine-adapter/P8/server-suite.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P8 && mise run lint 2>&1 | tee tmp/search-engine-adapter/P8/lint.log; echo exit=${PIPESTATUS[0]}'
grep -n "SearchEngineFactory.make\|searchSync\|searchEngine = " Sources/AppServer/KaibaServerRuntime.swift
wc -l Sources/AppServer/KaibaServerRuntime.swift Sources/AppServer/SearchIndexSyncLoop.swift
```

Expected evidence:

- `exit=0` for every run, including the full AppServerTests suite.
- `KaibaServerRuntime.swift` is under 350 lines.

## Done criteria

- [x] The server builds the engine from configuration and attaches it to the
      GraphQL service. Configuration errors fail start-up.
- [x] The sync loop prepares, activates, drains on tick and on kick, and
      stops cleanly. An unreachable engine never blocks start-up.
- [x] Without the section, the runtime wiring is identical to today.
- [x] All required verification commands show `exit=0`.

## Progress Log

- 2026-10-04: Plan created.
- 2026-10-04: Implemented `SearchIndexSyncLoop`, synchronous kick signaling,
  ordered observer fan-out, and conditional runtime wiring. Added retry,
  activation-state assertion, kick coalescing, stop, no-engine,
  unreachable-engine, and invalid engine-kind coverage. Runtime source is 336
  lines. Final current-tree verification: `mise run build` exit 0;
  `SearchIndexSyncLoop` 4/4 and `SearchEngineServerRuntime` 3/3 passed;
  complete `AppServerTests` 121 tests, 1 skipped, 0 failures; changed-file
  strict SwiftLint exit 0; repository `mise run lint` exit 0 with 3 warning
  diagnostics in files outside this plan. Final logs are `build-final.log`,
  `loop-final.log`, `runtime-final.log`, `server-suite-final.log`,
  `swiftlint-changed-final.log`, and `lint-final.log` under
  `tmp/search-engine-adapter/P8/`. Formal integration review and later workflow
  finalization remain downstream.
- 2026-10-04: Addressed test-integrity finding `P8-TI-RETRY-DRAIN-VACUOUS` in
  `SearchIndexSyncLoopTests.testPrepareFailureRetriesAndLogsSanitizedMessage`.
  The test now creates a note before start, waits for at least two prepare
  attempts and that note's upsert, asserts the activation row, and checks the
  secret substring across all log messages. Current-source loop tests passed
  4/4; full `AppServerTests` passed 121 tests with 1 pre-existing skip and 0
  failures; strict changed-file SwiftLint passed. Evidence: `loop-final.log`,
  `server-suite-final.log`, `swiftlint-changed-final.log`, and
  `final-source-identity.sha256` under `tmp/search-engine-adapter/P8/`.
  Production code and the other P8 tests were unchanged.
