# Personal AI Agent with In-Process Tools: Decisions Taken During Implementation

Recorded 2026-09-01 while implementing `design-docs/specs/user-agent-tools.md`.
The request was: let a user's own API key drive the agent, and pass kaiba's
API to the agent as tools inside the server process. The points below were
decided by the implementer; each can be revisited.

## Question 1

Where does the user's API key live, and is it encrypted?

## Answer 1 (implementer decision)

In the note store (`user_agent_credentials`), stored as given. The store
already holds the JWT signing secret in `app_settings`, and kaiba has no key
material outside the store, so an in-store encryption key would not protect
against database theft. Protection is at the API surface: no read path,
DTO, CLI output, or error ever returns the key; only its last four
characters (`keyHint`) are exposed.

## Question 2

One credential per user or one per provider?

## Answer 2 (implementer decision)

One per user. It keeps every surface free of a provider selector; switching
providers means saving a new key.

## Question 3

May a user point the server at a custom provider endpoint?

## Answer 3 (implementer decision)

Only when the operator sets `ai.userAgent.allowCustomBaseURL: true`, because
a custom `baseURL` makes the server open outbound connections to a
user-chosen host. `openai-compatible` (local models, proxies) therefore
requires that flag.

## Question 4

Which model does a personal-agent turn use when the composer has a model
selector?

## Answer 4 (implementer decision)

Always the credential's `defaultModel`. For a credentialed user,
`agentModels` reports exactly that model, so the selector shows it and turn
validation passes; a gateway model id recorded on a turn is never sent to
the user's provider.

## Question 5

Which kaiba operations are tools?

## Answer 5 (implementer decision)

Notes, notebooks, comments, tags, links, delete, and undo, through typed
tools over `NoteService`. Files, libraries, users, API clients, auth,
import, storage, auto-action configuration, and store maintenance are not
exposed; the agent also cannot write into its own conversation notebook.

## Question 6

Should the Claude-specific `fallbacks` (server-side refusal fallback) beta be
enabled for Anthropic requests?

## Answer 6 (implementer decision)

Not yet. The runtime is provider-neutral and the model is user-chosen;
`stop_reason: refusal` is handled as a terminal turn with a fixed message.
Enabling the beta per model is a follow-up if wanted.

## Question 7

Anthropic requires `max_tokens`; the runtime asks for 16,000, which some
models reject. Should the cap be a setting, a per-credential field, or a
per-model table?

## Answer 7 (decided 2026-09-01 during review)

None of those. The provider's rejection (HTTP 400) names `max_tokens` and
quotes the model's cap, so the client retries once with the quoted cap
(4,096 when none is quoted). The 400 arrives before any output is streamed,
so the retry is invisible; the model stays user-chosen with no extra surface
to maintain. A setting can be added later if a user wants a lower budget for
cost reasons.

## Question 8

Should note-edit turns (the composer's edit mode) receive the tools?

## Answer 8 (decided 2026-09-01 during review)

No. An edit reply is the replacement body the server applies through
`updateNoteBody`; with tools the model could also rewrite the note (or
anything else) behind that reply, double-applying the edit.
`AgentInvocationRequest.allowsTools` is false for edit turns and the runner
sends neither tools nor tool guidance. The gateway runtime ignores the flag.

## Question 9

Should Anthropic requests use prompt caching?

## Answer 9 (decided 2026-09-01 during review)

Yes, with two breakpoints: the system prompt (caching tool declarations and
instructions for the conversation) and the last message (so each tool round
reuses the previous round's prefix). Without it every round of a
multi-round loop re-read the entire history at full input price. OpenAI
compatible endpoints cache automatically and need nothing.
