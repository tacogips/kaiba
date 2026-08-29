# Architecture

## Status

Accepted

## Overview

`kaiba` is a standalone, local-first note application extracted from the
Riela Note subsystem. It is a Swift Package Manager project with a
domain library, a CLI executable, tests, and release automation for
Homebrew. See `kaiba-note.md` for the note domain design.

## Targets

- `CKaibaSQLite3`: system-library target exposing the sqlite3 C API.
- `AppCore`: the note domain and command logic — SQLite wrapper
  (`SQLiteDatabase`), store schema and migrations (`NoteStoreSchema`),
  the `NoteService` facade (notes, notebooks, ontology tags, links,
  comments, files, FTS5 search, system memory, auto-action
  outbox), local/S3 file stores, and the `AppCommand` CLI router.
- `AppGraphQL`: note GraphQL document executor — parsing, variable
  validation, projection, DTO contracts, and the authoritative
  note-only schema (`GraphQLContractProjector.schemaContract`).
- `AppServer`: local HTTP server — Network.framework listener, request
  parser, deterministic route handler (`/graphql`, `/note/register`,
  `/note/events`, `/healthz`), static SPA resolver, QR client
  registration authenticator, and the note change feed.
- `AppCLI`: command line entry point producing the `kaiba` executable,
  including the long-running `kaiba serve` command.
- `AppCoreTests` / `AppGraphQLTests`: vendored Riela Note domain and
  note GraphQL suites plus kaiba CLI round-trip tests.
- `web/`: SolidJS note viewer (vite + tailwind; `bun run build` →
  `web/dist`, served by `kaiba serve --web-root web/dist`). The same assets are
  packaged by `web/src-tauri/` as macOS and iPhone clients; native requests use
  a configured server endpoint and Tauri's HTTP plugin.

## Identifiers

Every entity id is a distinct type, not a bare string: `NoteID`,
`NotebookID`, `LibraryID`, `UserID`, `TagID`, `TagClassID`, `FileID`,
`CommentID`, `APIClientID`, `AutoActionID`, `AutoActionDispatchID`,
`WorkflowID` (`Sources/AppCore/KaibaIdentifiers.swift`). Passing a
notebook id where a note id belongs is a compile error rather than an
empty query result.

- Each type wraps the same raw string and encodes as that bare string, so
  stored rows, GraphQL values, and HTTP payloads are unchanged.
- Conversion is always explicit — there is no string-literal conformance.
  Raw text becomes an id only at a boundary: a SQL row
  (`SQLiteRow.identifier(_:as:)`), a GraphQL argument
  (`requiredIdentifier`/`optionalIdentifier`), a CLI argument
  (`CommandCursor.extractIdentifierOption`), or an HTTP path.
- Fresh ids come from `KaibaIdentifier.generate()`, which keeps the
  `<prefix>-<milliseconds>-<uuid>` shape the store has always used.
- The web reader mirrors this with branded string types (`NoteId`,
  `NotebookId`, ... in `web/src/notes/ids.ts`); the brand is compile-time
  only, so payloads stay plain JSON strings.

## JSON

No JSON in the package is handled as `Any`. Every payload — CLI
`--output json`, note and notebook `meta_json`, JWT segments, the
Turso/libSQL SQL-over-HTTP pipeline, and agent-gateway ACP lines — is
built and read through `JSONValue`/`JSONObject`
(`Sources/AppCore/JSONValue.swift`), with `JSONValue(parsing:)` and
`encodedString(prettyPrinted:)` replacing `JSONSerialization`. A value
the JSON writer cannot represent is a compile error rather than a
runtime `NSInvalidArgumentException`, and reads use typed accessors
(`asString`, `asInt`, `asObject`, `identifier(_:as:)`) instead of
unchecked casts. Encoding sorts keys and leaves slashes unescaped, which
is the byte-for-byte output the store had before.

## Data Layout

- Note root: `~/.kaiba/` by default (`--note-root` or `KAIBA_NOTE_ROOT`
  override).
- `<note-root>/note-store.sqlite`: SQLite database (WAL, FTS5).
- `<note-root>/files/<xx>/<file-id>`: content-addressed local file
  storage, sha256-verified; files can be migrated to S3-compatible
  storage.
- Configuration: `~/.config/kaiba/config.json` by default (`--config` or
  `KAIBA_CONFIG_PATH` override). The configuration stores only environment
  variable names for database and object-storage credentials.
- Database backends: local SQLite by default, or Turso/libSQL through the
  SQL-over-HTTP v2 pipeline with connection batons preserving transactions.
- File backends: local files by default, or named S3-compatible profiles.
  `s3-gateway` is the verified interface for exposing local POSIX storage
  or forwarding to MinIO/S3.

## Release Surfaces

- Homebrew formula archives under `dist/homebrew/`
- Signed and notarized Cask DMGs under `dist/homebrew-cask/`
- Tauri macOS client bundles under `web/src-tauri/target/release/bundle/`, and
  Tauri iPhone builds from the Xcode project regenerated under
  `web/src-tauri/gen/apple/`. These are build output only, not distributed: the
  client currently builds as `Kaiba.app`, the same installed name the Cask DMG
  uses for the resident menu-bar app in `macos-menu-bar-app.md`, so it must be
  renamed before distribution. See `tauri-client-apps.md`.
