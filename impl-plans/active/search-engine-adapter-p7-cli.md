# P7 CLI: kaiba search-engine status|sync|reindex

**Status**: Ready
**planId**: P7-cli
**Wave**: 3
**dependsOn**: P2-store-outbox, P3-elasticsearch-adapter, P4-sync-drain
**Design Reference**: `design-docs/specs/search-engine-adapter.md` SE6
**Index**: `impl-plans/active/search-engine-adapter.md`

## Intent and context

Operators need a foreground way to inspect sync state, push pending rows,
and backfill. This plan adds the async command `kaiba search-engine` with
three subcommands.

- The command logic lives in AppCore, so AppCoreTests can test it: there is
  no AppCLI test target.
- `Sources/AppCLI/main.swift` only dispatches.
- Patterns to imitate:
  - async dispatch: the `"ai"` block in `Sources/AppCLI/main.swift` (parse,
    then `run` returns `(String, Int32)`, then exit);
  - option and subcommand parsing: `Sources/AppCLI/AICommand.swift`;
  - store construction:
    `NoteService(driver: KaibaConfigurationLoader.makeDriver(configuration:noteRoot:environment:))`
    after `createDirectory`, as in `AICommand.run`;
  - text and JSON rendering: `Sources/AppCore/CommandDatabase.swift`
    (`renderJSON` / `JSONObject`).

## Non-goals

- No change to any other command.
- Other commands never build the adapter. A broken engine configuration must
  not affect them.
- No `--jwt` or `--library` support for this command.
- No detach command. That is an open question in user-qa.

## writePaths

- `Sources/AppCore/CommandSearchEngine.swift`
- `Sources/AppCore/Command.swift`
- `Sources/AppCLI/main.swift`
- `Tests/AppCoreTests/SearchEngineCommandTests.swift`
- `impl-plans/active/search-engine-adapter-p7-cli.md`

New files: `Sources/AppCore/CommandSearchEngine.swift`, `Tests/AppCoreTests/SearchEngineCommandTests.swift`. The edit to `Sources/AppCore/Command.swift` is usage text only.

## sharedPaths (read-only)

- `Sources/AppCore/SearchEngineFactory.swift`
- `Sources/AppCore/SearchEngineSyncOutbox.swift`
- `Sources/AppCore/SearchIndexSynchronizer.swift`
- `Sources/AppCore/NoteService+LibraryEnforcement.swift`
- `Tests/AppCoreTests/FakeSearchEngine.swift`

## sharedPathNotes

- `Sources/AppCore/SearchEngineFactory.swift`: read-only: P3 factory.
- `Sources/AppCore/SearchEngineSyncOutbox.swift`: read-only: P2 activation,
  enqueue-all and status.
- `Sources/AppCore/SearchIndexSynchronizer.swift`: read-only: P4
  `drainUntilIdle`.
- `Sources/AppCore/NoteService+LibraryEnforcement.swift`: read-only:
  `requireStoreAdministrator()`.
- `Tests/AppCoreTests/FakeSearchEngine.swift`: read-only: P1 fake.

## File-level changes

### `Sources/AppCore/CommandSearchEngine.swift` (new)

```swift
public enum SearchEngineCommand {
  public struct Options: Sendable { /* noteRoot, configuration, subcommand, json: Bool */ }
  public enum Subcommand: String, Sendable { case status, sync, reindex }
  public static func parse(arguments: [String], noteRoot: String, configuration: KaibaConfiguration) throws -> Options
  public static func run(_ options: Options, environment: [String: String]) async -> (String, Int32)
  static func run(_ options: Options, environment: [String: String], engine: (any SearchEngine)?) async -> (String, Int32)
}
```

The public `run` builds the engine with `SearchEngineFactory.make`. The
internal overload takes an injected engine for tests and skips the factory.

**Parsing.**

- The first argument is the subcommand, one of `status|sync|reindex`.
- `--output json` is accepted for every subcommand. `--output text` is the
  default.
- Any other argument is an error, with the message
  `unknown search-engine argument: <arg>`.
- A missing subcommand gives the usage error
  `search-engine requires a subcommand: status|sync|reindex`.

**Run flow:**

1. **Engine.** A factory `KaibaConfigurationError` gives
   `("Error: invalid search engine configuration: <field or variable name>", 2)`.
   A nil engine gives `("Error: search engine is not configured", 2)`.
2. **Store.** Open the store as `AICommand` does, then call
   `service.requireStoreAdministrator()`. A failure gives `("Error: ...", 1)`.
3. **Subcommand:**
   - **`status`:**
     - Call `engine.health()`. If it throws, report `available: false` and
       the error's description.
     - Read `service.searchIndexOutboxStatus()`.
     - Text output is one `key value` per line, for:
       - `kind elasticsearch` (from the configuration);
       - `index-identity`;
       - `available`;
       - `health-detail`;
       - `activated`;
       - `pending`;
       - `failing`;
       - `due`;
       - `next-due-at`, or `-` when there is none.
     - JSON output uses the same keys in camelCase.
     - Exit 0, even when the engine is unavailable.
     - Never print the URL or any credential.
   - **`sync`:**
     - Call `try await engine.ensureIndex()`. If it throws, return
       `("Error: <description>", 1)`.
     - Call `service.activateSearchEngineSync(indexIdentity: engine.indexIdentity)`.
     - Call `SearchIndexSynchronizer(service:).drainUntilIdle(engine:)`.
     - Print `activated <true|false> pushed <n> failed <n> remaining <n>`,
       or JSON.
     - Exit 1 when `failed > 0`, otherwise 0.
   - **`reindex`:** the same as `sync`, but after activation it also calls
     `service.enqueueAllNotesForSearchEngineSync()`, and the output includes
     `enqueued <n>`.

### `Sources/AppCore/Command.swift`

Add a "Search engine (optional, see design-docs/specs/search-engine-adapter.md)"
block to the `usage` text:

```
search-engine status [--output json|text]
search-engine sync [--output json|text]
search-engine reindex [--output json|text]
```

Each line gets a one-line comment, in the same style as the existing usage
text. Change nothing else.

### `Sources/AppCLI/main.swift`

- Add a block, modeled on the `"ai"` block, before the synchronous
  `AppCommand` fallback.
- When the command token is `"search-engine"` and
  `commandRequestsHelp(..., valueOptions: ["--output", "--note-root", "--config"])`
  is false:
  1. remove the token;
  2. call `extractGlobalConfiguration(from:)`;
  3. call `SearchEngineCommand.parse`;
  4. `await run(options, environment: ProcessInfo.processInfo.environment)`;
  5. print to stdout when the exit code is 0, otherwise to stderr;
  6. call `exit(code)`.
- A parse error writes `Error: <error>` and exits 2.

## Pitfalls

- Never print secrets. The status output uses only the configuration
  `kind`, `indexIdentity`, health detail and outbox counts. Never print
  `url` or environment values.
- Configuration errors exit 2, operational failures exit 1, and success
  exits 0.
- `requireStoreAdministrator` always passes for the unscoped CLI. Still call
  it, for consistency with `db check`.
- Do not route through the synchronous `AppCommand.run`: the engine is
  async.
- Do not add the subcommand to `AppCommand`'s switch in `Command.swift`.
  Only the usage text changes there.

## Tests

`SearchEngineCommandTests` (XCTest). Use a temporary note root under
`tmp/`, as `GraphQLSchemaAuthorizationTests` does, and call the internal
`run(..., engine:)` overload with `FakeSearchEngine`:

- Parsing:
  - `[]` gives the usage error.
  - `["bogus"]` gives an error.
  - `["status", "--output", "json"]` gives `json` true.
  - `["sync", "--extra"]` gives `unknown search-engine argument: --extra`.
- No configuration (`engine: nil` and a configuration with no section)
  gives exit 2 with "search engine is not configured".
- The public `run` with `searchEngine.kind = "opensearch"` gives exit 2,
  and the output contains `searchEngine.kind`.
- `sync` on a store with 2 notes gives exit 0. The output contains
  `pushed 2`, and the fake holds 2 documents. A second `sync` gives
  `pushed 0` and `activated false`.
- `reindex` after `sync` gives exit 0 with `enqueued 2` and `pushed 2`.
- `sync` with the fake's failure set:
  - when `ensureIndex` throws: exit 1, and the output contains
    "search engine unavailable";
  - when only `apply` fails, through `failingNoteIds`: exit 1 with
    `failed 1`.
- `status` with an unavailable fake gives exit 0 with `available false`.
  The JSON output has the keys `indexIdentity`, `pending`, `failing` and
  `due`. The output never contains "http".

## Verification

```bash
mise run build
bash -c 'mkdir -p tmp/search-engine-adapter/P7 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter SearchEngineCommand 2>&1 | tee tmp/search-engine-adapter/P7/command.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P7 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter CommandCLI 2>&1 | tee tmp/search-engine-adapter/P7/cli-regression.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P7 && mise run lint 2>&1 | tee tmp/search-engine-adapter/P7/lint.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P7/root && printf "{}" > tmp/search-engine-adapter/P7/empty-config.json && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift run kaiba --note-root tmp/search-engine-adapter/P7/root --config tmp/search-engine-adapter/P7/empty-config.json search-engine status 2>&1 | tee tmp/search-engine-adapter/P7/unconfigured.log; echo exit=${PIPESTATUS[0]}'
grep -n "search-engine" Sources/AppCore/Command.swift Sources/AppCLI/main.swift
```

Expected evidence:

- `exit=0` for the test and lint runs.
- `unconfigured.log` shows "search engine is not configured" with `exit=2`.
  This proves the unconfigured path.

## Done criteria

- [ ] `kaiba search-engine status|sync|reindex` works with the specified
      output and exit codes.
- [ ] No secrets appear in output. Configuration errors exit 2.
- [ ] Usage text is updated. Other commands are unaffected, and the
      `CommandCLI` regression passes.

## Progress Log

- 2026-10-04: Plan created.
