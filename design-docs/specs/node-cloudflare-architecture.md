# Node and Cloudflare Workers Architecture

## Status

Accepted for the Node migration on `feature/node-cloudflare-worker`.

## Goals

- Run Kaiba's API on Cloudflare Workers.
- Keep notes, notebooks, tags, links, search, and other deterministic data
  operations available through GraphQL.
- Remove the `kaiba` subcommand as an AI-agent integration surface.
- Execute every AI operation with credentials supplied by the end user.
- Let OCR, tagging, translation, and agent work choose different vendors and
  models independently.

## Runtime Boundary

Kaiba has two deliberately separate runtimes:

1. `apps/api` is a Cloudflare Worker. It exposes `/graphql` and stores data in
   D1. It contains no AI SDK dependency, vendor client, model selection, or
   vendor credential.
2. `packages/ai` is a JavaScript SDK used in a trusted caller runtime such as a
   desktop app, local Node/Bun process, automation Worker, or server. It receives
   user-owned vendor credentials in memory, invokes the selected model, and
   performs Kaiba reads and writes through typed GraphQL tools.

An AI agent never shells out to `kaiba`, and no GraphQL field starts hidden
server-side AI work. A tagging action, for example, reads a note through
GraphQL, asks the action's configured vendor for structured tags, and applies
the result through the GraphQL `applyNoteTags` mutation.

## Repository Layout

```text
apps/api/                 Cloudflare Worker and GraphQL schema
packages/domain/          Note, notebook, tag, and link entities
packages/application/     Use cases and repository ports
packages/adapter/         D1 and in-memory repository adapters
packages/ai/              BYOK AI SDK and GraphQL tools
web/                      SolidJS client (migrated incrementally to the SDK)
```

Dependencies point inward:

```text
domain <- application <- adapter <- apps/api
                    ^
                    +---- packages/ai (GraphQL client boundary only)
```

## GraphQL Surface

The first Worker contract keeps the central non-AI operations:

- Queries: `health`, `note`, `notes`, `notebook`, `notebooks`, `tags`, and
  `searchNotes`.
- Mutations: `createNote`, `updateNote`, `deleteNote`, `createNotebook`,
  `applyNoteTags`, `removeNoteTag`, `linkNotes`, and `unlinkNotes`.

AI-specific legacy fields such as `requestTagExtraction`,
`requestNotebookTranslation`, `sendAgentChatMessage`, `agenticSearch`, and
auto-action dispatch are intentionally absent. Equivalent behavior belongs in
`@kaiba/ai` actions or tools.

The Worker may require `Authorization: Bearer <KAIBA_API_TOKEN>`. This token
protects Kaiba data and is unrelated to vendor credentials.

## Persistence

D1 is the source of truth. The initial migration defines notebooks, notes,
tags, note-tag assignments, note links, and an FTS5 index. Timestamps are stored
as UTC ISO-8601 strings. IDs are UUIDs generated with Web Crypto.

Attachments will use R2 in a later migration slice. The Node migration does not
copy the Swift filesystem or S3 adapters into the Worker because Workers have
no local persistent filesystem.

## BYOK AI Routing

`@kaiba/ai` defines these action IDs:

- `ocr`
- `tagging`
- `translation`
- `agent`
- `agentSearch`
- `title`

Every action maps to a complete vendor selection:

```typescript
type AiActionRoute = {
  vendor: "openai" | "anthropic" | "google" | "openai-compatible";
  model: string;
  apiKey: string;
  baseURL?: string;
};
```

There is no global fallback key. Missing action configuration fails before a
network request. `openai-compatible` requires an explicit HTTPS base URL.
Read APIs return redacted route metadata and never expose `apiKey`.

Provider capability is validated per operation: OCR requires image input,
tagging requires structured output, and agent execution requires tool calling.
Tests use injected model executors and never contact live vendors.

## Security Rules

- Vendor API keys are never placed in GraphQL variables, D1, Worker logs,
  Wrangler configuration, or error messages.
- The SDK accepts credentials only as runtime values and keeps them out of
  serializable route metadata.
- GraphQL tools have exactly the caller's Kaiba bearer token and no ambient
  authority.
- Tool inputs are schema validated and writes re-enter ordinary GraphQL
  mutations.
- A browser may use the SDK only when the chosen vendor explicitly supports
  browser-origin requests; a trusted local/server runtime is the default.

## References

- Monja's Bun workspace and Cloudflare Worker/D1 clean architecture.
- Monja's provider-neutral AI adapter and typed-tool design, modified here so
  credentials are user-supplied and never stored by the service.
- `tacogips/ign-template/bun-ts-v1` for Bun, strict TypeScript, Biome, mise,
  and repository documentation conventions.
