# kaiba

A local-first, ontology-oriented note app for the command line, extracted
from the Riela Note subsystem. Notes live in notebooks, carry markdown
bodies (the first `# ` heading is the title), and are organized through
tags with world-model classes (`person`, `year`, `event`, `topic`, ...),
tag hierarchies, and provenance tracking (human vs AI vs system). Notes
can be linked to each other, commented on, marked read-only, and carry
content-addressed file attachments (local by default, migratable to
S3-compatible storage). Search is SQLite FTS5 with tag/class filters.

## Quick Start

```bash
kaiba add --body '# My first note
Anything markdown.' --tag idea

kaiba list                      # newest first
kaiba search idea               # FTS + snippet
kaiba show <note-id>            # body, tags, links, files, comments
kaiba notebook list
kaiba --help                    # full command surface
```

The note store lives under `~/.kaiba/` (override with `--note-root` or
`KAIBA_NOTE_ROOT`). See `design-docs/specs/command.md` for the full CLI
and `design-docs/specs/kaiba-note.md` for the design.

## Web Viewer

Kaiba includes the SolidJS note viewer ported from riela and a local
HTTP note API (GraphQL):

```bash
cd web && bun install && bun run build && cd ..
kaiba serve --web-root web/dist
```

`kaiba serve` prints the endpoint plus a registration URL / terminal QR
code; open the URL to register the browser (bearer token, stored
hashed). Use `--allow-unauthenticated` to skip auth on a trusted
machine. The server exposes `POST /graphql`, `GET /note/events`
(long-poll live updates), `GET|POST /note/register`, and serves the
viewer SPA.

## API Access

```bash
# machine access: issue an API key (printed once), use it as a bearer
kaiba client issue --name my-tool
curl -X POST http://127.0.0.1:8787/graphql \
  -H "Authorization: Bearer <api-key>" \
  -H 'Content-Type: application/json' \
  -d '{"query":"query Tags { tags { result { accepted } value { name } } }"}'

# or execute GraphQL locally without a server
kaiba graphql 'query Tags { tags { result { accepted } value { name } } }'
```

## Development

```bash
nix develop
task build
task test
swift run kaiba --help
```

The package uses Swift Package Manager with:

- System library target: `CKaibaSQLite3` (sqlite3)
- Library targets: `AppCore` (note domain + command logic),
  `AppGraphQL` (note GraphQL executor), `AppServer` (local HTTP server)
- Executable target: `AppCLI`
- Installed executable: `kaiba`
- Web viewer: `web/` (SolidJS + vite; `bun run build`)

## Homebrew Formula

Build local formula archives:

```bash
task build:homebrew -- darwin-arm64 darwin-x64
```

Render a formula after both platform archives exist:

```bash
task homebrew:formula -- 0.1.0
```

Render directly into the default sibling tap checkout:

```bash
task homebrew:tap-formula -- 0.1.0
```

Install from the tap after the formula is published:

```bash
brew tap user/tap
brew install kaiba
```

## Homebrew Cask

The Cask workflow builds signed, notarized, and stapled macOS DMG artifacts.
Apple signing credentials must stay local and must not be committed.

Check the build plan:

```bash
task build:homebrew-cask -- --dry-run darwin-arm64 darwin-x64
```

Build with local signing credentials:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  task build:homebrew-cask -- darwin-arm64 darwin-x64
```

Render a Cask:

```bash
task homebrew:cask -- 0.1.0
```

For a tagged release, build, upload, and render the tap Cask:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  task release:homebrew-cask-local -- v0.1.0
```

See `packaging/homebrew/README.md` and `.agents/skills/` for release workflows.
