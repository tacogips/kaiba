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
  `web/dist`, served by `kaiba serve --web-root web/dist`).

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
  `swift-s3-gateway` is the verified interface for exposing local POSIX storage
  or forwarding to MinIO/S3.

## Release Surfaces

- Homebrew formula archives under `dist/homebrew/`
- Signed and notarized Cask DMGs under `dist/homebrew-cask/`
