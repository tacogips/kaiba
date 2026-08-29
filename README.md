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

The local note store lives at `~/.kaiba/note-store.sqlite`, with attachments
under `~/.kaiba/files/` (override the root with `--note-root` or
`KAIBA_NOTE_ROOT`). Kaiba configuration lives at
`~/.config/kaiba/config.json` (override with `--config` or
`KAIBA_CONFIG_PATH`). No Riela path or environment variable is consulted.
See `design-docs/specs/command.md` for the full CLI
and `design-docs/specs/kaiba-note.md` for the design.

## Libraries

Notebooks are grouped into named libraries, and each library decides whether a
caller that presented no credential may see it at all:

```bash
kaiba library create shared --title "Shared" --auth required
kaiba library list
kaiba --library shared add --body '# Only for signed-in callers'
kaiba library move <notebook-id> --to shared
```

`--library <name>` (or `KAIBA_LIBRARY`) selects the library a command reads
and writes; without a selection writes land in the `default` library, which is
seeded open so a store behaves exactly as it did before libraries existed.

Access to a library that requires authentication is granted per account:

```bash
kaiba library grant shared --user <user-id>
kaiba library members shared
kaiba library revoke shared --user <user-id>
```

An `--allow-unauthenticated` note-API request reaches only the open libraries,
whatever grants exist. An authenticated account reaches the open libraries plus
the ones it was granted. The local CLI is the operator view and spans every
library. Holding a note, notebook, or file id does not get past this: fetch by
id, search, graph traversal, and `GET /files/<id>` all answer "not found" for a
library the caller cannot reach.

A library can name its own credential scope. Policy stays in the store and the
config holds only names, never values:

```json
{
  "libraries": [
    { "name": "shared", "kinkoPath": "logical:kaiba/shared", "storageProfile": "gateway" }
  ]
}
```

`kaiba library env shared` prints that scope and the environment variables it
supplies, so the invocation is ready to paste:

```bash
kinko --path logical:kaiba/shared exec -- kaiba --library shared serve
```

See `design-docs/specs/library.md` for the design.

## External database and file storage

The default configuration is local SQLite. A Turso or libSQL SQL-over-HTTP
database can be selected without putting its token in the configuration file:

```json
{
  "database": {
    "kind": "turso",
    "url": "libsql://my-kaiba-database.turso.io",
    "authTokenEnvironmentVariable": "KAIBA_TURSO_TOKEN",
    "allowInsecureLoopbackHTTP": false
  },
  "storageProfiles": []
}
```

The remote database must provide the SQLite features Kaiba uses: JSONB, FTS5,
and the FTS5 trigram tokenizer. `libsql://` and `turso://` URLs are sent over
HTTPS. Plain HTTP is accepted only when explicitly enabled for a loopback test
server.

Named S3-compatible profiles let all CLI, GraphQL, and server paths use the
same external file storage. Credentials remain in environment variables:

```json
{
  "database": { "kind": "sqlite" },
  "storageProfiles": [{
    "name": "gateway",
    "endpoint": "http://127.0.0.1:8443",
    "region": "us-east-1",
    "bucket": "kaiba-files",
    "accessKeyIdEnvironmentVariable": "KAIBA_S3_ACCESS_KEY",
    "secretAccessKeyEnvironmentVariable": "KAIBA_S3_SECRET_KEY",
    "keyPrefix": "attachments"
  }]
}
```

`s3-gateway` can expose either a local filesystem or an upstream S3
service through that profile. The integration gates exercise Kaiba upload and
download through its POSIX backend and through its MinIO-backed S3 backend:

```bash
mise run test:turso
mise run test:s3-gateway
```

The S3 gateway test expects a sibling checkout at `../s3-gateway` by
default and uses Docker (Colima is supported) for MinIO. Override the checkout
with `S3_GATEWAY_REPOSITORY`.

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

The viewer treats attached tags as navigation subjects. Click an underlined
tag term or tag chip to open its Memo, History, and Links tabs across every
notebook. Tag memo creation is safe under concurrent submissions, agent context
respects its UTF-8 byte budget, and Links loads the complete paginated occurrence
set while clearing results immediately when the selected tag changes.

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

## macOS and iPhone clients

The same SolidJS client is packaged with Tauri 2 for macOS and iPhone. Start a
Kaiba server first, then run or build the native client:

```bash
kaiba serve --web-root web/dist
mise run tauri:dev
mise run tauri:build

# One-time generation, then iPhone development/build:
mise run tauri:ios:init
mise run tauri:ios:dev
mise run tauri:ios:build
```

The macOS app defaults to `http://127.0.0.1:8787`. In the native app's Config
screen, set the Kaiba server URL and reconnect. A physical iPhone must use an
HTTPS or LAN address reachable from the phone; its loopback address does not
refer to the Mac. Authentication uses the same API key or registration flow as
the browser client.

`mise run tauri:build` emits `Kaiba.app`, which is the same installed name the
Homebrew Cask uses for the resident menu-bar app. The bundle identifiers differ
-- the client is `com.tacogips.kaiba` and the Cask app is `dev.kaiba.Kaiba` --
so neither overwrites the other's preferences or state, but the file names
collide. The client bundle is build output only: do not copy it into
`/Applications` under the current name. See
`design-docs/specs/tauri-client-apps.md` for the unresolved naming decision.

## Development

```bash
mise install
mise run build
mise run test
swift run kaiba --help
```

The package uses Swift Package Manager with:

- System library target: `CKaibaSQLite3` (sqlite3)
- Library targets: `AppCore` (note domain + command logic),
  `AppGraphQL` (note GraphQL executor), `AppServer` (local HTTP server)
- Executable target: `AppCLI`
- Installed executable: `kaiba`
- Shared web/native client: `web/` (SolidJS + Vite + Tauri 2; `bun run build`)

Document conversion is consumed exclusively through `anydoc-swift`'s
`AnydocKit` product. macOS development and release builds use its published
XCFramework automatically and do not require a local Cargo build or
`PKG_CONFIG_PATH`.

## Homebrew Formula

Build local formula archives:

```bash
mise run build:homebrew -- darwin-arm64 darwin-x64
```

Render a formula after both platform archives exist:

```bash
mise run homebrew:formula -- 0.1.0
```

Render directly into the default sibling tap checkout:

```bash
mise run homebrew:tap-formula -- 0.1.0
```

Install from the tap after the formula is published:

```bash
brew tap tacogips/tap
brew install kaiba
```

## Homebrew Cask

The Cask workflow builds signed, notarized, and stapled macOS DMG artifacts.
Apple signing credentials must stay local and must not be committed.

Check the build plan:

```bash
mise run build:homebrew-cask -- --dry-run darwin-arm64 darwin-x64
```

Build with local signing credentials:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  mise run build:homebrew-cask -- darwin-arm64 darwin-x64
```

Render a Cask:

```bash
mise run homebrew:cask -- 0.1.0
```

For a tagged release, build, upload, and render the tap Cask:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  mise run release:homebrew-cask-local -- v0.1.0
```

See `packaging/homebrew/README.md` and `.agents/skills/` for release workflows.
