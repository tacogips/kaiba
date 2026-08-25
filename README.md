# kaiba

Kaiba is an ontology-oriented note application built as a Bun/TypeScript
monorepo. Its deterministic data API runs on Cloudflare Workers with GraphQL
Yoga and D1. AI features run outside the Kaiba Worker through `@kaiba/ai`, use
end-user vendor keys, and access notes only through GraphQL tools.

There is no `kaiba` AI subcommand and no server-side AI mutation.

## Architecture

```text
web or trusted JS automation
  |-- GraphQL ----------------------> Cloudflare Worker --> D1
  `-- @kaiba/ai --> selected vendor --^ typed GraphQL tools
```

- `apps/api`: Worker, GraphQL schema, D1 adapter composition, static assets.
- `packages/domain`: note, notebook, tag, and provenance types.
- `packages/application`: deterministic use cases and repository ports.
- `packages/adapter`: D1 and in-memory repositories.
- `packages/ai`: user-key provider routing, OCR/tag/translation actions, and <!-- gitleaks:allow -->
  Kaiba GraphQL tools.
- `web`: SolidJS app served by the Worker.

See [the architecture design](design-docs/specs/node-cloudflare-architecture.md)
and [migration plan](impl-plans/active/node-cloudflare-migration.md).

## Development

```bash
mise install
mise run install
mise run db-migrate-local
mise run dev
```

The local Worker is available at `http://localhost:8787`; GraphQL is at
`http://localhost:8787/graphql`. D1 migration `0001_init.sql` creates a
`default` notebook.

Verification:

```bash
mise run lint
mise run test
mise run build
```

## Riela work orchestration

Run repository work through the preferred Fable/Codex workflow with automatic
Codex-only fallback:

```bash
mise run workflow -- \
  --variables-file request.json \
  --output jsonl
```

The launcher validates `codex-goal`, then prefers
`fable-and-improve-codex`. It switches to `codex-goal` only when the Claude
executable or Fable workflow is unavailable, or when execution reports a
Fable/Claude authentication, quota, capacity, model-access, or backend
availability failure. Other workflow failures remain visible and do not trigger
a second run.

To select the Codex-only Riela flow explicitly:

```bash
KAIBA_FORCE_CODEX_RIELA=1 mise run workflow -- \
  --variables-file request.json \
  --output jsonl
```

## GraphQL

The Worker exposes deterministic note operations even when no AI vendor is
configured:

```bash
curl http://localhost:8787/graphql \
  -H 'content-type: application/json' \
  -d '{"query":"query { notes { id title tags { name provenance } } }"}'
```

Create and tag a note:

```graphql
mutation {
  createNote(
    input: {
      notebookId: "default"
      bodyMarkdown: "# My note\nMarkdown body"
      tags: ["idea"]
      provenance: human
    }
  ) {
    id
    title
  }
}
```

Set the optional Kaiba data API bearer token as a Worker secret:

```bash
cd apps/api
mise exec -- bunx wrangler secret put KAIBA_API_TOKEN
```

This bearer token is unrelated to AI vendor keys.

## User-key AI SDK

Each action has an independent vendor, model, and user key. Keys are runtime
values; the SDK's redacted routing view never returns them.

```typescript
import { KaibaAi } from "@kaiba/ai";

const kaiba = new KaibaAi({
  kaiba: {
    endpoint: "https://kaiba.example.com/graphql",
    token: process.env.KAIBA_API_TOKEN,
  },
  routes: {
    ocr: {
      vendor: "google",
      model: "your-image-capable-model",
      apiKey: process.env.GOOGLE_GENERATIVE_AI_API_KEY!,
    },
    tagging: {
      vendor: "anthropic",
      model: "your-structured-output-model",
      apiKey: process.env.ANTHROPIC_API_KEY!,
    },
    translation: {
      vendor: "openai",
      model: "your-translation-model",
      apiKey: process.env.OPENAI_API_KEY!,
    },
  },
});

await kaiba.tagNote({ noteId: "note-id" });
await kaiba.translateNote({
  noteId: "note-id",
  targetLanguage: "Japanese",
  writeBack: true,
});
```

`createKaibaTools()` supplies `searchNotes`, `getNote`, `createNote`,
`updateNote`, `applyNoteTags`, and `linkNotes`. Every write goes through the
ordinary GraphQL API with the caller's Kaiba bearer token. No tool shells out to
a CLI.

The web app holds vendor keys in page memory only. A trusted local/server
JavaScript runtime is recommended because some vendors reject browser-origin
requests.

## Cloudflare deployment

1. Create a D1 database and replace the placeholder `database_id` in
   `apps/api/wrangler.toml`.
2. Apply remote migrations.
3. Set `KAIBA_API_TOKEN` if the API must require a bearer token.
4. Build and deploy.

```bash
cd apps/api
mise exec -- bunx wrangler d1 create kaiba
mise exec -- bunx wrangler d1 migrations apply kaiba --remote
cd ../..
mise run build
cd apps/api
mise exec -- bunx wrangler deploy
```

The Worker serves `web/dist`, routes `/graphql` to GraphQL Yoga, and exposes a
public `/health` endpoint. AI vendor keys are not Wrangler secrets or Worker
bindings.

## Migration note

The Swift CLI, local server, macOS menu-bar wrapper, and Homebrew release flows
were removed on the Node migration branch. Historical designs remain under
`design-docs/`; the current runtime contract is
`design-docs/specs/node-cloudflare-architecture.md`. Existing Swift SQLite data
requires an explicit export/import tool before production cutover; the new D1
schema intentionally does not read local filesystem state.
