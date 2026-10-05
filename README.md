# kaiba

A local-first, ontology-oriented note app for the command line, extracted
from the Riela Note subsystem. Notes live in notebooks, carry markdown
bodies (the first `# ` heading is the title), and are organized through
tags with world-model classes (`person`, `year`, `event`, `topic`, ...),
tag hierarchies, and provenance tracking (human vs AI vs system). Notes
can be linked to each other, commented on, marked read-only, and carry
content-addressed file attachments (local by default, migratable to
S3-compatible storage). Search is SQLite FTS5 with tag/class filters,
contextual indexing, relaxed multi-term matching with rank fusion, and
graph expansion ranked by personalized PageRank
(`design-docs/specs/note-retrieval-fusion.md`). An optional Meilisearch
engine adds engine-ranked, ontology-aware search and related notes (see
[Optional search engine](#optional-search-engine)).

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
`KAIBA_CONFIG_PATH`).
See `design-docs/specs/command.md` for the full CLI
and `design-docs/specs/kaiba-note.md` for the design.

## PDF and image notebooks

For dedicated Google OCR, see [Google Document AI setup](design-docs/specs/google-document-ai-ocr.md).

```bash
kaiba import book.pdf --max-ocr-pages 2
kaiba import scan.jpg --max-ocr-pages all
kaiba page-ocr <note-id>
```

Each physical page becomes a note whose page image is rendered by deterministic
PDFKit/CoreGraphics code (standalone images keep their own bytes); no AI provider
produces page images. The reader shows only the page images, with vertical text
and binding-aware page navigation, and offers OCR for pending pages. There is no
Text/Original toggle. OCR text is hidden: it is used only for search and for
agent context, and page bodies cannot be edited (annotate pages with comments).
Use `0` to import originals without OCR. The New Notebook screen also accepts
PDF/image uploads up to 1 MiB. Stores from earlier versions are migrated on first
open (schema version 22): existing page text moves to the hidden search text, so
those pages stay searchable.

Asking the agent while viewing a page sends that page's image plus the page's
OCR text, the neighbouring pages' OCR text and related text found by search.
Anthropic Messages, OpenAI chat completions and agent-gateway (including the
Claude Code subscription) receive the image. Providers that cannot accept
images (for example `openai-compatible` and cursor) get only the text and a
notice that the image was not sent.

Native Vision handles local OCR. Configure `import.analysis` and optionally
`import.ocr` for independent agent-gateway providers, including Codex and
Claude Code subscriptions. Figure extraction has been removed, and an
`import.figures` setting is ignored. Enable `ai.autoTag.auto` and set
`ai.autoTag.prompt` to tag notebooks and recognized pages automatically.
See [document import configuration](design-docs/specs/document-import.md) and
[document page images](design-docs/specs/design-document-page-images.md) for
examples, server subscription opt-ins, upload limits and the agent context budget.
Other formats (EPUB, Word, HTML, Markdown, text, ...) still import as readable
Markdown notes.

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

## Optional search engine

When configured, the optional search engine provides engine-ranked note search
and related notes. Without an engine, Kaiba keeps its built-in search behavior.
Search results are filtered by the engine and checked again against the note
store before they are returned.

### Engine

Meilisearch is the bundled adapter and the default. It is a single Rust
binary (no JVM) with built-in Japanese segmentation (`jpn` locale); related
notes are composed by Kaiba from text, link, tag and entity searches. The
engine is reached only by the Kaiba backend: clients talk to Kaiba's GraphQL
API and never to the engine directly. The Elasticsearch adapter was removed;
a `searchEngine.kind` of `elasticsearch` is now rejected as unsupported.

Add a `searchEngine` section to `config.json`. Every field is optional; an
empty section selects Meilisearch:

```json
{
  "searchEngine": {
    "kind": "meilisearch",
    "url": "http://127.0.0.1:7700",
    "indexPrefix": "kaiba"
  }
}
```

When `url` is omitted, the server uses the `KAIBA_MEILISEARCH_URL` environment
variable, and falls back to `http://127.0.0.1:7700` when it is unset.
An empty or whitespace-only `url` is also treated as omitted; resolution
happens on the server host.

For a remote Meilisearch server, use `https` and add
`"apiKeyEnvironmentVariable": "KAIBA_MEILISEARCH_API_KEY"`; keep the key in
the environment, not in `config.json`. Use an API key restricted to the
`<prefix>-notes-*` index pattern and only the required actions: search,
documents add/delete, indexes create/get, settings update and tasks get. Do
not use the Meilisearch master key. Meilisearch's health endpoint does not
require authentication, so **Test connection** can report the server as
available even when the API key is wrong; authenticated index operations or
backfill will reveal an invalid key.

For local development, use the compose setup in `docker/meilisearch/compose.yaml`:

```bash
mise run search:up         # starts colima first on macOS if Docker is not running
mise run search:status
mise run search:test-live  # brings Meilisearch up, then runs the live tests
mise run search:down
```

The local compose service binds to `127.0.0.1` and runs in development mode
without a master key, so it is for local use only and must not be exposed to
a network.

Switch engines in **Settings** or by changing the `searchEngine` section in
`config.json`. A change to engine identity triggers an index backfill through
the durable outbox; existing notes remain searchable through full-text search
while it runs. Kaiba does not delete the old engine index automatically.

The server syncs the index on startup, after note changes, and every 15 seconds.
Changes are stored in a durable outbox and retried when the engine is
unavailable, so note writes do not fail because of the engine. Access is
filtered in the engine query and re-checked by the note store.

Use the CLI to inspect or operate the index:

```bash
kaiba search-engine status
kaiba search-engine sync
kaiba search-engine reindex
```

These commands require a store administrator. They use the `searchEngine`
section first, then the settings saved from **Settings**, and exit with code 2
and `search engine is not configured` when neither selects an engine.

To clear stale documents, delete the current index and rebuild it:

```bash
curl -X DELETE http://127.0.0.1:7700/indexes/<prefix>-notes-v1
kaiba search-engine reindex
```
 See the [search engine design](design-docs/specs/search-engine-adapter.md)
for configuration, behavior, and rollout details.

### Ontology-aware search and settings

Engine search can filter by a tag and its descendants, or by tag class and
optional tag value. Matching query terms also expand deterministically to up
to 10 tag names: CJK names use substring matching, while Latin names use
whole-word matching. Exact tag matches receive a 4.0 boost and ancestor-path
matches receive a 2.0 boost. Search can request tag and tag-class facets as
refinement hints.

Related notes combine text similarity, linked notes, shared tags, nearby tags
and shared person or event tags. Results include machine-readable reasons such
as `linked`, `shared-tag`, `shared-entity` and `text-similarity`; the web panel
shows those reasons.

With an engine attached, graph search (`includeLinked: true`), the agent
`search_notes` tool (with either `include_linked` value) and AI search grounding
fuse engine and full-text results deterministically. Provenance identifies the
contributing sources. Retrieval uses no LLM; if an engine call fails, Kaiba
returns the existing full-text results.

A `searchEngine` section in `config.json` takes precedence and locks the
connection settings. Without that section, administrators can choose an
adapter and manage its connection from **Settings**. Secrets are write-only
and are bound to the normalized URL and authentication mode; changing either
requires entering the secret again. The URL field in **Settings** may be left
empty to use the server default; clients never receive the resolved value.
The plain-`http` loopback rule applies to the host running the Kaiba server,
not to the device running the client. With the server default, a changed
`KAIBA_MEILISEARCH_URL` takes effect at the next server start and triggers a
backfill. If an API key is stored, it is not sent to the new host; enter the
key again in **Settings**. **Test connection** checks unsaved
settings, avoids a network call when a credential cannot be reused for the
target, and sanitizes returned errors. Saving settings hot-swaps the shared
engine without a server restart. A changed index identity triggers a backfill
into the `-v2` index. After upgrading, the old `-v1` index is not used and can
be deleted by the operator after confirming the new index is populated.

## Learning notebook

Kaiba includes a SolidJS learning notebook and a local HTTP note API (GraphQL).
Create a notebook in **My notebooks**, save your notes, then choose **Study this
note** to ask AI for an explanation, a quiz, or connections between ideas.
Choose **Memo only** to save a thought without an AI reply. Writable notes can
also be edited directly. Saved notes and discussions use the same knowledge
store as the CLI and Riela; unsaved drafts stay only in the current app session.

Start the web client:

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

The local listener requires Apple's Network framework, so `kaiba serve` is
unavailable on Linux. The Linux CLI and `KaibaClient` SDK can still access a
remote server; local GraphQL execution does not require the listener.

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

# discover the authenticated endpoint schema; the token stays in the environment
kaiba graphql schema --endpoint http://127.0.0.1:8787 \
  --api-key-env KAIBA_API_KEY --filter '^(notes|Note)$' --output text
```

`kaiba graphql schema` retrieves standard authenticated introspection from the
endpoint. Its optional ICU regular expression matches root-field and type names;
output includes the forward transitive type dependencies needed to understand
each match. Use `--allow-unauthenticated` only for a trusted loopback server.
Remote unauthenticated access additionally requires
`--allow-remote-unauthenticated`; non-loopback HTTP additionally requires
`--allow-insecure-http`. Text and stable sorted JSON output are supported.

Swift clients can depend on the standalone `KaibaClient` library product. It
normalizes the endpoint, requires an explicit bearer or unauthenticated choice,
executes arbitrary GraphQL, exposes readiness/schema APIs and typed common note
operations, and never opens a Kaiba store or falls back to in-process services:

```swift
import KaibaClient

let client = try KaibaClient(
  endpoint: URL(string: "https://kaiba.example.com")!,
  authentication: .bearer(try KaibaBearerToken(
    ProcessInfo.processInfo.environment["KAIBA_API_KEY"] ?? ""
  ))
)
let readiness = try await client.probeReadiness()
let schema = try await client.fetchSchema()
```

Requests default to a 2 MiB encoded limit, responses to 8 MiB, and a ten-second
timeout; configurable timeouts are capped at 24 hours. Redirects are refused,
caller cancellation remains cancellation, and diagnostics do not retain
request bodies, response bodies, or bearer values. Typed conveniences cover
notes, notebooks, tags, attachments, comments, notebook/document ingest,
conversations, and long-term memory. Ingest and long-term-memory append calls
require caller-provided idempotency keys; the client does not retry
automatically. Long-term-memory operations require an authenticated, enabled
administrator, except for the server's explicit loopback operator mode.

Transport, authentication, HTTP, GraphQL, decoding, and schema failures remain
distinct `KaibaClientError` categories. Schema discovery is intentionally
bounded to the SDK's canonical introspection document rather than providing a
general-purpose GraphQL introspection engine.

## Personal AI agent (your own API key)

Any user can chat with an agent that runs on their **own** provider key and
acts on their notes through tools executed inside the kaiba server
(`design-docs/specs/user-agent-tools.md`). The tools are kaiba's own note
operations (search, read, create, edit, comment, tag, link, delete, undo),
bound to the signed-in user's permissions, so the agent can do what that user
could do through the API and nothing more.

```bash
# operator: store a key for a user (the key is read from the environment or
# stdin, never from an argument); provider is anthropic, openai, openrouter,
# or openai-compatible (the last needs ai.userAgent.allowCustomBaseURL)
export MY_KEY=sk-...
kaiba ai credential set --provider anthropic --model claude-opus-5 \
  --api-key-env MY_KEY --user <user-id>
kaiba ai credential show --user <user-id>      # provider, model, key hint only
kaiba ai credential disable --user <user-id>   # fall back to the server runtime
```

In the web viewer the same lives under Settings > "Personal AI agent"
(GraphQL `userAgentCredential`, `setUserAgentCredential`,
`setUserAgentCredentialEnabled`, `clearUserAgentCredential`). Once a user has
an enabled credential, their chat turns run through it; tag extraction,
translation, and agentic search still use the server's `ai.agent` runtime.
Server policy lives in `config.json`:

```json
{ "ai": { "userAgent": { "enabled": true, "allowCustomBaseURL": false, "maxToolRounds": 24 } } }
```

## macOS and iPhone clients

The same SolidJS client is packaged with Tauri 2 for macOS and iPhone. On macOS,
the app defaults to Local mode and starts its bundled Kaiba service automatically.
No separately installed CLI or manually started HTTP server is needed. Run or
build the native client:

```bash
mise run tauri:dev
mise run tauri:build

# One-time generation, then iPhone development/build:
mise run tauri:ios:init
mise run tauri:ios:dev
mise run tauri:ios:build
```

In Settings > Server connection, choose **Local — this Mac** or **Remote server**.
Local notes persist in the app's local data directory, under `local/`, separately
from the CLI's `~/.kaiba` store. The app chooses an available loopback port and
stops its child service on exit. Local mode grants the desktop user access to all
libraries in this app-owned store; it does not listen on the LAN. Startup errors
preserve the database and report the local service log path. Builds include the
matching Swift executable via `scripts/build-tauri-local-service.sh`.

Remote mode retains its URL and server-specific credentials when switching back
to Local. Existing installations with a saved server URL retain Remote mode.
To use a separate server, start `kaiba serve` there and enter its URL in Settings.
On iPhone, only Remote mode is supported. A physical iPhone must use an
HTTPS or LAN address reachable from the phone; its loopback address does not
refer to the Mac. That Server connection form is native-only: the browser
client always talks to the origin that served it, so its Config screen shows no
such card.

Authentication uses the same API key or registration flow as the browser
client, and the credential is stored per server origin. Pointing the native
client at a different server therefore starts unauthenticated rather than
carrying the previous server's bearer to a new host, and correcting a mistyped
URL reads the earlier session back. A native request whose target does not
resolve to the configured server origin is refused before it is sent.

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

`mise run check` runs every verification gate: Swift tests, SwiftLint,
`web:check` (typecheck, test, lint, and build of the shared web/native client)
and `tauri:check` (`cargo fmt --check`, `check`, and `clippy` on the Tauri Rust
shell). `web:check` is a thin wrapper around `bun run check` in `web/`, the same
script the "Web client check" GitHub Actions workflow runs, so the local gate
and CI cannot drift. `tauri:check` needs a macOS toolchain and runs locally
only.

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

### Reusable source analyses

Open a document notebook and expand **Analyses** above the reader. Select source
notes and apply Summary, Key concepts, Research questions, Action items, or your
own instructions. Save a named custom template to reuse it across notebooks;
templates follow the existing server-backed web settings and are shared by
clients using the same store.

Each selected note gets a separate source-linked agent discussion using the
provider/model selected in the AI composer (or server defaults). **Open result**
shows its saved request, streamed reply, and any failure. Results also remain
available through the source's discussions and conversation history after reload.
Submission is not completion. Leaving the notebook stops further submissions;
already submitted work continues on the server. Check source discussions before
repeating a submission whose network response was lost. Source text is preserved.
Requested citations are generated by the model and should be checked against the
source. Source selection controls initial context; existing agent tool permissions
still apply.

See the [source analyses design](design-docs/source-analyses.md)
and [implementation plan](impl-plans/source-analyses.md).

For an opt-in browser check with real agent replies, use
[`scripts/test-source-analyses-browser.py`](scripts/test-source-analyses-browser.py)
against an empty, isolated localhost server configured with an AI provider. It
creates synthetic sources, applies a batch and a custom template, checks saved
results after reload, and retains screenshots and JSON evidence. It invokes the
provider three times and refuses to run against a non-empty store.

### Codex subscription for server chat

Enable `ai.userAgent.allowCodexSubscription` in the server's `config.json`, and
install `agent-gateway` and Codex CLI on the server PATH. Log in to Codex with
ChatGPT as the server OS user using file-based credential storage. Then select
**Codex (subscription on server)** in **Settings → Personal AI agent**, enter a
model, and save; no API key is needed. Provider and model selectors are available
in chat and Ask AI. This currently requires a macOS server.

See [subscription setup and execution details](design-docs/codex-subscription-chat.md).
