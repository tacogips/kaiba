# AGENTS.md

This file provides guidance to coding agents working in this repository.

## Response Rules

- Begin the first response in a conversation with: "I will continue thinking
  and providing output in English."
- Think and respond in English regardless of the user's language.
- Acknowledge this file and summarize the request in the first response.
- Do not use emojis.

## Project Overview

Kaiba is a Bun/TypeScript monorepo. Its GraphQL API runs on Cloudflare Workers,
uses D1 persistence, and serves a SolidJS web client. AI work is isolated in
`@kaiba/ai`, uses end-user API keys, and calls Kaiba through GraphQL tools.

The Cloudflare Worker must remain AI-vendor neutral. Do not add AI SDK imports,
vendor keys, or model calls to `apps/api`, `packages/domain`,
`packages/application`, or `packages/adapter`.

## Development Environment

- Language: TypeScript with maximum strictness.
- Runtime and package manager: Bun.
- Environment and task runner: mise.
- API runtime: Cloudflare Workers.
- Data: Cloudflare D1.

## Common Commands

```bash
mise install
mise run install
mise run lint
mise run test
mise run build
mise run db-migrate-local
```

## Riela Workflow Fallback

Use `mise run workflow -- <riela-run-options>` for repository work that should
use the Fable/Codex improvement workflow. The launcher prefers
`fable-and-improve-codex` and automatically continues with the Codex-only
`codex-goal` workflow when Claude/Fable is missing, cannot validate, or reports
an availability, authentication, quota, capacity, or model-access failure.

Do not use the fallback for unrelated implementation, verification, or workflow
logic failures; surface those failures instead. Set `KAIBA_FORCE_CODEX_RIELA=1`
to select the Codex-only workflow explicitly.

## Code Rules

- Preserve inward dependencies: domain <- application <- adapter <- app.
- Keep each TypeScript source file below 1000 lines and split by responsibility.
- Use Web Platform APIs in Worker-reachable code; do not assume Node filesystem
  or process APIs.
- Keep GraphQL deterministic. OCR, tagging, translation, title generation,
  agent search, and tool loops belong in `packages/ai` or a trusted caller.
- Never persist, log, place in GraphQL, or return AI vendor API keys.
- Use per-action routing; do not introduce a global fallback vendor key.
- Validate with the narrowest relevant test, then run lint, all tests, and the
  Wrangler dry-run when shared behavior changes.

## Git Commit Policy

When asked to commit, stage and commit automatically without confirmation. Do
not add AI attribution or co-authorship. Keep commits focused and describe the
primary change, technical concepts, files, problem solving, impact, and TODOs.

## Documentation

Place design documents under `design-docs/`, implementation plans under
`impl-plans/`, and user decisions under `design-docs/user-qa/`.
