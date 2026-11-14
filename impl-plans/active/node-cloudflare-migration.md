# Node and Cloudflare Workers Migration Plan

**Status**: Complete
**Design Reference**: `design-docs/specs/node-cloudflare-architecture.md`
**Created**: 2026-08-25

## Deliverables

### TASK-001: Bun workspace foundation

- [x] Replace SwiftPM-oriented root tasks with Bun workspace tasks.
- [x] Adopt maximum-strictness TypeScript and Biome configuration from the
      Bun TypeScript template.
- [x] Replace the incompatible viewer with a SolidJS GraphQL/BYOK client.

### TASK-002: Domain, application, and persistence

- [x] Define Worker-safe domain types and repository ports.
- [x] Implement deterministic note/notebook/tag/link use cases.
- [x] Implement D1 and in-memory adapters.
- [x] Add the initial D1 migration including FTS search.

### TASK-003: GraphQL Worker

- [x] Expose deterministic operations at `/graphql` with GraphQL Yoga.
- [x] Add optional bearer protection using `KAIBA_API_TOKEN`.
- [x] Ensure no AI operation or AI dependency exists in the Worker graph.
- [x] Add API tests with the in-memory adapter.

### TASK-004: User-key AI SDK and tools

- [x] Add per-action provider/model/key routing.
- [x] Support OpenAI, Anthropic, Google, and OpenAI-compatible vendors.
- [x] Add GraphQL tools for reads, writes, search, links, and tag assignment.
- [x] Implement OCR, tagging, translation, and tool-loop actions.
- [x] Test routing, redaction, and tool behavior without live vendor calls.

### TASK-005: Migration cleanup and verification

- [x] Remove the Swift CLI/server implementation and obsolete release flows.
- [x] Update README and developer tasks.
- [x] Run formatting, lint, type checking, tests, and Wrangler dry-run.
- [x] Record the intentionally deferred legacy SQLite import tool.

## Progress Log

### 2026-08-25

- Created `feature/node-cloudflare-worker`.
- Reviewed the current Swift/GraphQL implementation, Monja architecture and AI
  plan, and a generated checkout of `tacogips/ign-template/bun-ts-v1`.
- Fixed the runtime and credential boundary in the design document.
- Implemented the GraphQL Worker, D1 migration, layered repositories, BYOK AI
  SDK/tools, and the new SolidJS client.
- Verified local D1 migration, lint, type checking, core/web tests, web build,
  and Wrangler dry-run. Live vendor calls were intentionally not performed.
- Added a validated Riela launcher that prefers `fable-and-improve-codex` and
  falls back to Codex-only `codex-goal` solely for Fable availability failures.
