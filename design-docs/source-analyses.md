# Reusable source analyses

## Purpose and scope

Let readers apply a consistent analysis to selected notes and revisit the
results later. Built-in and saved custom templates use kaiba's existing agent
conversations, source context, and provider settings.

| Capability | Kaiba evidence | Decision |
| --- | --- | --- |
| Reusable content transformations | Agent chat exists; no template or batch analysis UI | Implement built-in and saved custom analysis templates, explicit source selection, one durable conversation per source |
| Source context control | `noteChatContext` already scopes document-note chat to one note | Reuse this boundary; submit selected notes independently |
| Durable insights | Chat turns already persist requests, replies, status and source relationships | Present result links into those conversations, available after reload through source discussions/history |
| Document ingestion | Existing document import, page OCR and reader work in this worktree | Preserve; do not duplicate |
| Full-text/vector search | Existing search/indexing functionality | Preserve |
| Multiple providers | Existing user credentials and model/provider preferences | Reuse current preferences and server defaults |

## User experience

Document notebooks expose an Analyses panel. Opening it loads every source page
through the existing paginated API; no partial list is silently treated as the
whole notebook. The user selects sources, selects a built-in template or edits
a custom instruction, and applies it. Custom named templates use the existing
server-persisted web settings and can be removed. These settings are store-wide,
not private per-user preferences. Saves enforce a 60 KiB settings budget, leaving
room below the existing server's 64 KiB limit. Built-ins remain immutable.

Each source receives a fresh note-scoped conversation, with the template name
and instructions persisted in the user turn. Results preserve source text and
use the selected provider/model. Instructions request citations using source
note numbers and distinguish missing evidence from conclusions; citations are
model-generated, not mechanically verified. Existing agent tools and permissions
still apply: source selection scopes initial context, not the agent's tool access.

Submission status must distinguish an accepted request from a finished reply.
Each accepted row links to its durable conversation, where existing streaming,
failure reporting and retry controls apply. Individual submission failures do
not erase successful rows. No automatic replay of ambiguous network failures:
the server may have accepted the first request. Leaving the notebook cancels further
submissions, but already accepted work remains on the server.

## Boundaries and verification

The feature uses existing storage and provider interfaces without a database
migration or new deployment requirements. Templates are preferences, not credentials. Validate
template parsing/persistence, full pagination, source identity and model capture,
partial failures, cancellation, and result navigation. Run `mise run web:check`
and `mise run tauri:check` for the client changes.
