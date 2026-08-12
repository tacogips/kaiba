# AI Agent Integration

## Status

Accepted (invocation deferred: see "Deferral Boundary")

## Summary

Kaiba gains three AI capabilities without depending on riela:

1. **Note-level agent chat** — ask an agent about a note or imported
   document; conversations persist as `agent-conversation` notebooks.
2. **Ontology tag auto-extraction** — AI proposes tags (with tag
   classes) for notes and notebooks, applied with provenance `ai`.
3. **A pluggable agent runtime seam** — `AgentInvoking` — whose concrete
   implementation is the agent-gateway CLI once the agent runtime is
   extracted from riela into `tacogips/agent-gateway`.

Everything except the actual model invocation ships now: configuration,
persistence, dispatch wiring, CLI, GraphQL, and web UI all land with a
well-defined "agent unavailable" state.

## Deferral Boundary (resolved 2026-08-12)

The agent runtime was extracted from riela into `tacogips/agent-gateway`,
which now ships an ACP (Agent Client Protocol) stdio agent: `agent-gateway
client --vendor <v> --model <m> --system <s> --prompt -` runs one prompt
turn and emits ACP JSONL on stdout; the `session/prompt` response's
`_meta.agentGateway.resultText` carries the authoritative reply. Supported
vendors: claude-code, codex, cursor, openai, anthropic, gemini,
openrouter.

- Kaiba owns: the `AgentInvoking` protocol, the `ai` configuration
  schema, prompt construction, reply validation, persistence, dispatch,
  and every user-facing surface.
- agent-gateway owns: the runtime that actually talks to a model.
- The bridge is `AgentGatewayCLIInvoker: AgentInvoking`
  (`Sources/AppCore/AgentGatewayCLIInvoker.swift`): process spawn
  mirroring the anydoc pattern (zero SwiftPM dependencies), flattening
  turns + subject context into one prompt, preferring `resultText` over
  concatenated `agent_message_chunk`s, and surfacing JSON-RPC error
  responses as typed failures. `AgentInvokerFactory` constructs it when
  `ai.agent` names the `agent-gateway-cli` backend with a vendor and
  model and the binary resolves (`commandPath` else `PATH`); otherwise
  every AI surface reports the unavailable state with the specific
  reason, and `kaiba serve` force-disables the AI auto-actions so the
  outbox never accumulates.
- While serving with a runtime available, a maintenance tick recovers
  and retries pending dispatches every 30 seconds, so rows enqueued by
  other processes (e.g. `kaiba import` in another terminal) are drained
  without a restart.

## Design Decisions

- **AI1 — `AgentInvoking` protocol seam.**

  ```swift
  public protocol AgentInvoking: Sendable {
    func invoke(_ request: AgentInvocationRequest) async throws
      -> AgentInvocationResult
  }
  ```

  `AgentInvocationRequest` = purpose (`chat` | `tagExtraction`) + system
  prompt + prior turns + optional subject context markdown + optional
  provider/model. `AgentInvocationResult` = reply markdown. No streaming
  in the protocol: the HTTP server writes single responses, so replies
  land via persistence and the existing change feed.
- **AI2 — Configuration in the `ai` section of `config.json`.**

  ```json
  {
    "ai": {
      "agent": {
        "backend": "agent-gateway-cli",
        "commandPath": null,
        "provider": "openrouter",
        "model": "openai/gpt-5-mini",
        "apiKeyEnvironmentVariable": null
      },
      "autoTag": { "auto": "on" }
    }
  }
  ```

  `agent` absent means no runtime. `provider` names an agent-gateway
  vendor; `model` is required (the gateway takes an explicit model).
  `commandPath` overrides the `PATH` lookup for the `agent-gateway`
  binary. `apiKeyEnvironmentVariable` is the credential's environment
  variable NAME (never a value); when absent the gateway's per-vendor
  default applies (e.g. `OPENROUTER_API_KEY`). `autoTag.auto` defaults
  to `off`.
- **AI3 — Tag extraction contract.** The prompt carries the subject
  markdown plus an ontology snapshot (tag classes `person`, `year`,
  `event`, `document-kind`, `topic`; existing tag names; hierarchy) and
  demands a strict JSON array reply: `[{"name":..., "class":...,
  "parent":...?}]`. Validation rejects class `folder` and unknown
  classes; tags are resolved or created hierarchy-aware; assignments are
  applied with provenance `ai` at note and notebook level through the
  existing APIs, which already guarantee AI never overwrites or deletes
  human tags (D6). Agent-conversation notebooks are skipped.
- **AI4 — Auto-tagging rides the existing auto-action outbox.**
  `KaibaAutoActionDispatcher` implements the `AutoActionDispatching`
  seam and routes on workflow id: `note-auto-tagging` (tag extraction),
  `note-agent-reply` (chat reply). Failures return `.failed` and use
  the existing lease/retry machinery (3 attempts). At serve startup,
  when an invoker exists, actions are reconciled via the idempotent
  `configureAutoAction` upsert (seeding only runs on fresh stores):
  `autoTag.auto=on` enables `default-ai-tagging-note-created`,
  `default-ai-tagging-note-updated`, and the new
  `default-ai-tagging-notebook-created`; `off` (or no invoker) disables
  them. `seedAutoActions` gains the `.notebookCreated` row for fresh
  stores. This is data seeding, not a schema migration.
- **AI5 — Manual triggers always exist.** `kaiba ai tag --note <id> |
  --notebook <id> [--dry-run]` runs extraction synchronously (not via
  outbox) and prints results; `kaiba ai status` reports configuration
  and invoker availability. The web UI's Info tab exposes the
  `requestTagExtraction` mutation, which enqueues a `note-auto-tagging`
  dispatch when a dispatcher is installed and reports
  `agent-unavailable` otherwise.
- **AI6 — Chat data model: conversation notebooks, no new tables.** A
  chat about note X is a notebook with kind tag
  `notebook-kind:agent-conversation`. Subject binding is recorded twice,
  deliberately: notebook `meta_json` `{"kaibaChat":{"subjectNoteId":...,
  "subjectNotebookId":...}}` for fast lookup (`json_extract`), and
  `source-citation` note links from turns to the subject note so the
  subject surfaces in the note graph and the Linked tab. Rejected: a
  dedicated `chat_sessions` table (duplicates turn idempotency, kind
  tagging, and auto-action enqueueing that conversation notebooks
  already have).
- **AI7 — Pending-turn lifecycle.** The existing
  `NoteConversationTurn` couples user and assistant markdown in one
  note, but interactive replies arrive later. `NoteService+AgentChat`
  adds: `startConversation`, `appendPendingChatTurn` (user half, note
  meta `{"kaibaChat":{"status":"pending"}}`), `completeChatTurn` /
  `failChatTurn` (status `answered` / `failed`; completion writes pass
  `originatingActionId` to suppress auto-action loops), and
  `listConversations(subjectNoteId:)`.
- **AI8 — Reply transport: outbox + change feed.** When an invoker
  exists, serve upserts auto-action `agent-chat-reply` (trigger
  `noteCreated`, filter `{"notebookKindTag":
  "notebook-kind:agent-conversation"}`, workflow `note-agent-reply`).
  A pending turn note fires it; the dispatcher invokes the agent with
  prior turns plus subject markdown and completes the turn. The web
  client observes the existing `GET /note/events` long-poll and
  refetches. Rejected: response streaming (requires rewriting the
  single-write HTTP server); a new push route (duplicates the feed).
  Until Phase D the action stays disabled and
  `sendAgentChatMessage` returns `agentStatus: "agent-unavailable"`
  while still persisting the user turn.

## GraphQL Surface Additions

Each field follows the full AppGraphQL touchpoint checklist (SDL,
projector line, field allowlists, root switch, selection types/fields,
service method, DTO, inputs, diagnostics, contract tests — updated in
the same change).

- Query `noteConversations(noteId, limit)` — conversations whose
  subject is the note.
- Mutation `sendAgentChatMessage(input)` — creates the conversation on
  first message, appends a pending turn, returns
  `{conversationNotebookId, turnNoteId, agentStatus}` where
  `agentStatus` is `pending` or `agent-unavailable`.
- Mutation `requestTagExtraction(input)` — manual tag extraction for a
  note or notebook; returns `queued` or `agent-unavailable`.
- Query `noteTagDetails(noteId)` — structured tag assignments
  `{name, className, provenance, parentName}` for the Info tab.
- Turn listing reuses notes-by-notebook queries; turn status/role is
  read from note meta JSON (exposed if not already).

## Verification (Phase D checklist)

1. `kaiba ai status` reports the backend available.
2. `kaiba ai tag --note <id> --dry-run` proposes ontology tags; the
   real run applies them with provenance `ai`; re-running never touches
   a human assignment.
3. `kaiba ai tag --notebook <id>` works at notebook level.
4. With `autoTag.auto=on` and serve running, `kaiba import <pdf>`
   triggers notebook and note tag dispatches; the attempt listing shows
   `dispatched`; killing serve mid-dispatch recovers via lease
   staleness on restart.
5. UI chat round-trip: send, pending, answered via the events feed;
   conversation persisted with kind tag, meta JSON, and
   `source-citation` links; idempotent resends do not duplicate turns.
6. `requestTagExtraction` from the Info tab queues and completes.
7. Failure modes: invalid model yields a `failed` turn with a message;
   removing the agent binary yields `agent-unavailable` in UI and CLI.
