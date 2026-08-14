# AI Agent Integration

## Status

Accepted

## Traceability

- Workflow issue: `direct-workflow:comm-002100`
- Composition reference: the user's desktop screenshot
  `Screenshot 2026-08-12 at 21.13.56.png` (kept outside the repository)
- Agent contract references:
  `Sources/AppCore/AgentInvoking.swift` and
  `Sources/AppCore/AgentGatewayCLIInvoker.swift`

## Issue Scope: `direct-workflow:comm-002100`

- **In scope:** AI10-AI11 and only the minimum GraphQL, service, persistence,
  prompt-construction, model-catalog, and adapter integration necessary for
  the right-pane model selector and bounded agent-turn attachments.
- **Out of scope:** AI1-AI9 except where their existing contracts are consumed
  unchanged, plus auto-tagging, translation, search, provider selection,
  runtime replacement, and other AI feature expansion.
- The existing `AgentInvoking`, `AgentStreamingInvoking`, outbox, persisted-turn,
  and change-feed flows are compatibility boundaries. This issue may carry the
  snapshotted model and validated attachment context through them but must not
  redesign those flows.

## Summary

Kaiba gains three AI capabilities without depending on riela:

1. **Note-level agent chat** — ask an agent about a note or imported
   document; conversations persist as `agent-conversation` notebooks.
2. **Ontology tag auto-extraction** — AI proposes tags (with tag
   classes) for notes and notebooks, applied with provenance `ai`.
3. **A pluggable agent runtime seam** — `AgentInvoking` — whose concrete
   implementation is the extracted `tacogips/agent-gateway` CLI runtime.

Configuration, model invocation, persistence, dispatch wiring, CLI, GraphQL,
streaming progress, and web UI share the same runtime boundary. When that
runtime is absent or invalid, every surface retains a well-defined
`agent-unavailable` state.

## Runtime and Provider Adapter Boundary

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
- Codex and Cursor remain provider choices behind the same
  `AgentGatewayCLIInvoker` ACP adapter. Kaiba does not launch either vendor
  CLI directly, add provider-specific composer behavior, or interpolate
  provider/model values into shell commands. This intentionally diverges
  from copying a Codex- or Cursor-specific client integration: the desktop
  capture informs composition only, while agent-gateway owns vendor
  differences and Kaiba owns validation, prompt construction, and persistence.
- The bridge is `AgentGatewayCLIInvoker: AgentInvoking`
  (`Sources/AppCore/AgentGatewayCLIInvoker.swift`): process spawn
  mirroring the anydoc pattern (zero SwiftPM dependencies), flattening
  turns + subject context into one prompt, preferring `resultText` over
  concatenated `agent_message_chunk`s, and surfacing JSON-RPC error
  responses as typed failures. `AgentInvokerFactory` constructs it when
  `ai.agent` names the `agent-gateway-cli` backend with a vendor and
  model and the binary resolves (`commandPath` else `PATH`).
  `AgentGatewayCLIModelCatalog` similarly delegates model discovery to
  `agent-gateway models`, without requiring a configured model.
  When invocation requirements are not met, every AI surface reports
  the unavailable state with the specific
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

  `AgentInvocationRequest` = purpose (`chat` | `tagExtraction` |
  `translation` | `search`) + system prompt + prior turns + optional
  subject context markdown + optional provider/model.
  `AgentInvocationResult` = reply markdown. Streaming rides a separate
  seam (2026-08-12): `AgentStreamingInvoking` adds
  `invoke(_:onChunk:)`, which `AgentGatewayCLIInvoker` implements by
  parsing ACP `agent_message_chunk` lines incrementally. During serve,
  the dispatcher publishes chunks through `AgentReplyStreamPublishing`
  into `AgentReplyStreamHub`, and clients long-poll
  `GET /note/agent-stream?turn=<turnNoteId>&cursor=N` — the HTTP server
  still writes single responses; the final reply stays authoritative
  via persistence and the change feed.
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
      "autoTag": { "auto": "on" },
      "translate": {
        "provider": null,
        "model": null,
        "defaultTargetLanguage": null
      }
    }
  }
  ```

  `agent` absent means no runtime. `provider` names an agent-gateway
  vendor; `model` is required (the gateway takes an explicit model).
  `commandPath` overrides the `PATH` lookup for the `agent-gateway`
  binary. `apiKeyEnvironmentVariable` is the credential's environment
  variable NAME (never a value); when absent the gateway's per-vendor
  default applies (e.g. `OPENROUTER_API_KEY`). `autoTag.auto` defaults
  to `off`. `translate.provider`/`translate.model` override the agent
  vendor for translation requests only (set `model` whenever `provider`
  differs — model ids are vendor-specific);
  `translate.defaultTargetLanguage` backs `kaiba ai translate` when
  `--to` is omitted.
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
- **AI8 — Reply transport: outbox + transient chunks + durable change feed.**
  When an invoker
  exists, serve upserts auto-action `agent-chat-reply` (trigger
  `noteCreated`, filter `{"notebookKindTag":
  "notebook-kind:agent-conversation"}`, workflow `note-agent-reply`).
  A pending turn note fires it; the dispatcher invokes the agent with
  prior turns, bounded attachments, and subject markdown. During invocation,
  ordered `agent_message_chunk` values flow through
  `AgentReplyStreamPublishing` to `AgentReplyStreamHub`; the web pane reads
  them through the turn-scoped `GET /note/agent-stream` long-poll route.
  This preserves the HTTP server's single-response boundary and deliberately
  avoids SSE, WebSocket, and a store-wide push channel. The completed or
  failed turn is persisted as the authority, then `GET /note/events` causes
  clients to refetch and replace transient stream state. Poll waiters are
  turn-scoped and remain tracked from registration until response return:
  publishing or finishing a turn wakes only that turn's waiters, while response
  completion, timeout, or client cancellation unregisters the request. Finishing
  a stream captures its in-flight poll requests as terminal-delivery obligations,
  including requests woken by a preceding chunk whose response has not returned.
  The stream remains protected until every captured request has
  returned a snapshot containing all buffered chunks after its cursor and the
  terminal status, or that request is cancelled. New polls after the terminal
  transition read the retained terminal snapshot immediately but do not add a
  delivery obligation. A terminal stream also receives a 35-second delivery
  grace measured from its terminal transition. This exceeds the route's 30-second
  maximum long-poll timeout by five seconds, covering the normal gap in which a
  client consumes a non-terminal response and starts its next poll. The grace is
  satisfied when at least one poll response returns a terminal snapshot, or when
  its deadline expires; cancellation alone does not satisfy it. Only after all
  captured obligations are discharged and the grace is satisfied does the stream
  enter the bounded late-poller retention set. Capacity cleanup evicts only
  entries in that set, oldest terminal transition first. Cleanup runs when a
  stream finishes, a poll returns or cancels, a poll or publication accesses the
  hub, and when the grace deadline fires, so a terminal stream with no poller
  eventually becomes eligible without requiring unrelated traffic. Active
  streams, terminal streams with undelivered obligations, and terminal streams
  still awaiting first delivery within grace are never capacity-evicted; the hub
  may temporarily exceed its target until protection ends. This guarantees
  concurrent and between-polls terminal delivery within the bounded grace without
  promising indefinite replay after an old terminal entry becomes eligible and
  is capacity-evicted. If the invoker is unavailable,
  `sendAgentChatMessage` still persists the user turn and returns
  `agentStatus: "agent-unavailable"`; no stream is opened.
- **AI9 — Notebook translation.** A translation is a
  `notebook-kind:translation` notebook created up front in `pending`
  state, with meta JSON `{"kaibaTranslation":{"sourceNotebookId":...,
  "targetLanguage":..., "status":"pending|completed|failed",
  "error":...?}}` (the `kaibaChat` precedent). `AITranslationService`
  invokes the agent once per source note (purpose `translation`, prompt
  demands the translated markdown only, structure preserved, code/URLs
  untranslated; whole-document code fences are stripped from replies),
  appends each translated note (provenance `ai`, note meta
  `kaibaTranslation.sourceNoteId`, writes carry `originatingActionId`
  so no auto-actions fire), then flips the status. Already-translated
  notes are counted and skipped, so an outbox retry — the manual
  dispatch uses workflow `notebook-translation`, routed by
  `KaibaAutoActionDispatcher` — or `kaiba ai translate --resume <id>`
  resumes where a failed run stopped instead of re-paying for finished
  pages. The per-feature vendor override rides
  `AgentInvocationRequest.provider/model` (`ai.translate` config, CLI
  `--provider`/`--model`). There is no automatic trigger: translation
  is always requested manually (CLI synchronously; UI/GraphQL via a
  manually enqueued dispatch, like `requestTagExtraction`).
- **AI10 — Chat model choice is an immutable turn snapshot.** Model
  discovery uses `AgentGatewayCLIModelCatalog` for the configured provider
  and exposes ids and display metadata to authenticated web clients. The
  configured `ai.agent.model` is always present as the fallback option even
  when the vendor cannot enumerate models. `sendAgentChatMessage` accepts an
  optional model id, validates it against the current-provider catalog (or
  the configured fallback), and records it in turn `kaibaChat.model` before
  dispatch. Reply generation reads that snapshot and supplies it as
  `AgentInvocationRequest.model`; later app-setting or config changes do not
  alter queued or retried turns. Provider remains server-configured. Model
  ids are data passed as a discrete process argument, never interpolated
  into a command string. Idempotent replay returns the original turn and
  cannot mutate its model.
- **AI11 — Agent-turn attachments reuse file storage without becoming
  ambient subject context.** `sendAgentChatMessage` accepts zero to four
  inline attachment values (base64 content, declared media type, original
  filename). The GraphQL/service boundary estimates base64 size before
  decoding, rejects malformed encodings, then enforces a 1 MiB decoded
  aggregate, filename validation, a UTF-8 textual media allowlist, and
  content decoding. Validation of all attachments completes before a turn
  is created. The core append operation stores each file through the
  existing SHA-256-tracked, file-ID-addressed file store and associates it
  with the generated turn note in the same dispatch boundary; rollback removes newly stored
  content or leaves it eligible for existing orphan reclamation. Reply
  dispatch must not observe the pending turn before its file associations
  exist.

  Reply prompt construction resolves only files attached to turns in the
  active conversation. Its file-content budget is exactly 1 MiB (1,048,576)
  of UTF-8 bytes and excludes framing. A separate 4 KiB allowance covers the
  fixed delimiters, normalized filename/media-type headers, and omission
  markers; accepted filenames are capped at 255 UTF-8 bytes, so four
  current-turn headers fit that allowance. Prompt construction adds whole,
  delimited sections in this order: current-turn attachments by stored
  position, then prior turns newest-to-oldest and their attachments by stored
  position. Current-turn validation guarantees all current file content fits
  the 1 MiB content budget, including an aggregate exactly at the limit. A
  prior file whose content would exceed the remaining content budget is
  omitted and represented by a stable filename/media-type omission marker;
  no file is partially truncated. If prior-file headers or omission markers
  would exhaust the framing allowance, remaining prior files are omitted
  without adding further markers. Sections label normalized filename and
  media type, treat contents as untrusted reference data, and never follow
  paths or URLs found inside a file. A retry uses persisted attachment
  positions and the model snapshot, producing the same ordering. Subject note
  and notebook files are not implicitly disclosed. Memo-only comments remain
  text-only because comments have no file relation; adding a comment-file
  schema is outside this change.

## Chat Composer Security and Validation Boundary

- Authentication, subject/conversation ownership, read-only enforcement,
  idempotency, and file validation are server-authoritative; client checks
  exist only for immediate feedback.
- A supplied `conversationNotebookId` must be an agent conversation for the
  supplied subject. Attachment file records cannot be borrowed by id from
  another note, notebook, client, or request.
- Original filenames are display metadata, never storage paths. The server
  rejects empty names, path-like names (any `/` or `\\`, including absolute
  paths and traversal components), control characters, and names longer than
  255 UTF-8 bytes before creating a turn; it does not silently strip or
  truncate them. Accepted names are preserved for display only.
- After removing parameters such as `charset`, the normalized media type must
  be one of `text/plain`, `text/markdown`, `text/csv`,
  `text/tab-separated-values`, `application/json`, `application/xml`,
  `application/yaml`, or `application/x-yaml`, and decoded bytes must be valid
  UTF-8. Empty or generic browser MIME values may use a recognized extension
  as a candidate type, but content validation remains mandatory. `text/html`,
  SVG, scripts, executables, archives, and other active or binary types are
  rejected even if a filename claims an allowed extension.
- Prompt inclusion has the independent 1 MiB UTF-8 file-content cap and 4 KiB
  framing allowance defined by AI11, deterministic whole-file ordering, and
  explicit delimiters. Attachment text cannot change the system prompt or
  introduce agent-gateway arguments.
- The inline aggregate remains at 1 MiB so base64 plus the GraphQL envelope
  fits the existing 2 MiB HTTP request limit. The global parser limit is not
  increased.

## GraphQL Surface Additions

Each field follows the full AppGraphQL touchpoint checklist (SDL,
projector line, field allowlists, root switch, selection types/fields,
service method, DTO, inputs, diagnostics, contract tests — updated in
the same change).

- Query `noteConversations(noteId, limit)` — conversations whose
  subject is the note.
- Query `agentModels` — authenticated catalog for the configured provider,
  including configured fallback and discovery availability; no credentials,
  command paths, or environment values are returned.
- Mutation `sendAgentChatMessage(input)` — creates the conversation on
  first message, validates and persists optional `model` and bounded textual
  `attachments`, appends a pending turn, returns
  `{conversationNotebookId, turnNoteId, agentStatus}` where
  `agentStatus` is `pending` or `agent-unavailable`. Optional `mode` is
  `memo` (default; answer in the conversation only) or `edit` (the reply
  rewrites the subject note). `edit` is validated before any conversation is
  created: it requires a note subject whose own read-only flag and whose
  notebook's flag are both clear, mirroring the `updateNoteBody` gate;
  `appendPendingAgentChatTurn` re-enforces the same rule inside its
  transaction. The mode is snapshotted immutably on the turn meta JSON
  (`kaibaChat.mode`, absent for memo) exactly like `model`, so a
  conversation can switch modes per turn and retries replay the original
  mode.
- Edit-mode replies carry no tool channel: the agent returns the complete
  replacement body between `<kaiba-note-body>` sentinel lines plus optional
  commentary, and the server applies it through `updateNoteBody` (the same
  guarded write path as `kaiba edit`), which keeps the feature portable
  across provider adapters and re-checks read-only state at apply time. A
  reply without usable sentinels (clarifying question, refusal, blank body)
  is persisted as a plain answer and the note is untouched. Edit turns skip
  chunk streaming — the raw body would render as markup mid-flight — and
  publish only the stream finish event.
- Mutation `requestTagExtraction(input)` — manual tag extraction for a
  note or notebook; returns `queued` or `agent-unavailable`.
- Mutation `requestNotebookTranslation(input)` — creates the pending
  translation notebook and queues the run; returns
  `{translationNotebookId, status}` where `status` is `queued` or
  `agent-unavailable` (nothing is created when unavailable). Translated
  notes arrive through the change feed as the dispatcher appends them.
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
7. Failure modes: an unsupported client-selected model is rejected before
   turn creation; a catalog-approved or configured model later rejected by
   the runtime yields a `failed` turn with a message; removing the agent
   binary yields `agent-unavailable` in UI and CLI.
8. Model contract: catalog fallback works when enumeration is unavailable;
   selection persists in app setting `web.agentModel`; queued/retried turns
   invoke their snapshotted model; unsupported model ids are rejected before
   turn creation.
9. Attachment contract: accepted UTF-8 files round-trip through turn file
   associations and reach prompt context; malformed base64, spoofed/binary
   media, invalid UTF-8, empty filenames, path-like filenames, filenames with
   control characters, filenames over 255 UTF-8 bytes, more than four files,
   and aggregate payloads over 1 MiB are rejected without dispatch. Boundary tests
   verify that exactly 1,048,576 content bytes across four maximum-length
   filenames fit with framing kept within 4 KiB, while one additional content
   byte is rejected before turn creation.
10. Stream capacity: register turn-scoped pollers for more concurrent active
    turns than the hub's retention target, publish chunks and terminal states
    for every turn, and verify every already-waiting poll returns its buffered
    chunks and terminal status before its stream becomes eviction-eligible.
    Verify an unrelated turn does not wake a waiter, cancellation releases its
    delivery obligation without satisfying first-delivery grace, and a client
    between sequential polls receives the retained terminal snapshot within the
    35-second window. Using a controllable clock, verify a terminal stream with no
    poller becomes eligible at the deadline, temporary excess retention is allowed
    while obligations or grace remain, and cleanup converges to the target by
    removing only the oldest eligible terminal streams.
