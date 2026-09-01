# Personal AI Agent with In-Process Kaiba Tools

**Status**: Completed
**Design Reference**: `design-docs/specs/user-agent-tools.md`

## Purpose

Let a user run kaiba's chat agent on their own API key, with the model able
to search, read, create, edit, tag, link, and undo notes through typed tools
executed inside the server process under that user's ownership scope.

## Deliverables

- [x] `user_agent_credentials` table and `NoteService+UserAgentCredentials`
- [x] `KaibaUserAgentConfiguration` (`ai.userAgent`)
- [x] Tool seam (`AgentToolExecuting`), `KaibaAgentToolbox`
- [x] Provider clients (Anthropic Messages, OpenAI Chat Completions) over an
      injectable HTTP streamer
- [x] `UserAgentToolLoopRunner` (`AgentStreamingInvoking`)
- [x] Dispatcher routing and server wiring
- [x] GraphQL query/mutations, CLI `kaiba ai credential`, web Config card
- [x] Tests for every layer; `mise run check` green

## Tasks

### TASK-001: Persistence and configuration

**Parallelizable**: Yes

**Completion Criteria**:

- [x] Table statement added to `NoteStoreSchema.schemaStatements`
- [x] `UserAgentCredential`, `UserAgentCredentialSummary`, `UserAgentProvider`
- [x] Scoped set/summary/clear/setEnabled with the UA1 access rules
- [x] `ai.userAgent` decoded with defaults

### TASK-002: Tool seam and toolbox

**Parallelizable**: Yes

**Completion Criteria**:

- [x] `AgentToolDefinition`, `AgentToolCall`, `AgentToolResult`,
      `AgentToolExecuting`
- [x] `KaibaAgentToolbox` with the UA4 tool set, conversation-notebook guard,
      48 KiB result bound

### TASK-003: Provider clients and tool loop

**Parallelizable**: Yes

**Completion Criteria**:

- [x] `ToolLoopModelClient` protocol, SSE line parser, URLSession streamer
- [x] Anthropic and OpenAI-compatible clients (requests, streaming parse,
      error mapping)
- [x] `UserAgentToolLoopRunner` with round budget, activity lines, stop
      reasons, chunk backpressure

### TASK-004: Routing and surfaces

**Parallelizable**: No (depends on 001-003)

**Completion Criteria**:

- [x] `KaibaAutoActionDispatcher` optional gateway invoker + per-turn runtime
- [x] `KaibaServerRuntime` creates the dispatcher when either runtime exists
- [x] GraphQL contract, executor, service; `agentModels` reflects the user
- [x] `kaiba ai credential`, `kaiba ai status` line
- [x] Web `UserAgentSettings` card and client methods

### TASK-005: Verification

**Parallelizable**: No

**Completion Criteria**:

- [x] Swift tests for credentials, toolbox, clients, runner, routing, GraphQL
- [x] Web tests for the settings card and client
- [x] `mise run check` passes; SwiftLint clean for new files

## Progress Log

- 2026-09-01: Plan created.
- 2026-09-01: TASK-001 through TASK-004 implemented. New files:
  `Sources/AppCore/{UserAgentCredential,NoteService+UserAgentCredentials,AgentTools,KaibaAgentToolbox,KaibaAgentToolSchema,ToolLoopModelClient,AnthropicMessagesToolLoopClient,OpenAIChatCompletionsToolLoopClient,UserAgentToolLoopRunner,UserAgentRuntime}.swift`,
  `Sources/AppCLI/AICredentialCommand.swift`,
  `web/src/components/UserAgentSettings.tsx`. Suites
  `UserAgentCredentialTests`, `KaibaAgentToolboxTests`,
  `UserAgentToolLoopRunnerTests`, `AnthropicMessagesToolLoopClientTests`,
  `OpenAIChatCompletionsToolLoopClientTests`, `UserAgentDispatchRoutingTests`,
  `UserAgentCredentialGraphQLTests`, and
  `UserAgentSettings.integration.tsx` pass. Full gate pending.
- 2026-09-01: Review pass. Fixed: the runner forwarded every provider text
  delta as one relay chunk, so a reply of more than 256 deltas failed on the
  relay's chunk budget (now coalesced into 1 KiB chunks with a prompt flush
  for the first 64, and a flush per round); `link_notes` could attach a link
  to the agent's own transcript (now guarded on both endpoints); the note
  body bound (64 KiB) exceeded the tool result bound (48 KiB), so a large
  `get_note` result was cut mid-JSON (body bound is now 32 KiB); in-stream
  provider errors were reported as "HTTP 200" (now `providerError`);
  `canAnswerChat` built a full runtime holding the key just to test
  availability (now `UserAgentRuntimeFactory.isAvailable(for:)`). Tests added
  for each.
- 2026-09-01: `mise run check` green (750 Swift tests, lint, web:check, tauri:check); `kaiba ai status` verified by hand.
- 2026-09-01: Second review pass. Note-edit turns no longer receive tools or tool guidance (`AgentInvocationRequest.allowsTools`, set false by `generateAgentChatReply` in edit mode); Anthropic requests carry prompt-cache breakpoints on the system prompt and the last message so tool rounds reuse the cached prefix; a custom Anthropic base URL ending in `/v1` is no longer doubled to `/v1/v1/messages`; blank user turns are sent as `(empty message)` instead of empty text the API rejects. Tests added for each; spec UA2/UA3 updated.
- 2026-09-01: Decided the open items (user-qa Q7-Q9): Anthropic `max_tokens` rejections are retried once with the quoted cap; plan marked Completed.
