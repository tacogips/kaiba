import { For, Show, createEffect, createMemo, createSignal, type JSX } from 'solid-js'
import { MarkdownBody } from './Markdown'
import { errorMessage, useApp } from '../state/appStore'
import {
  agentUnavailable,
  chatTurns,
  hasPendingTurn,
  isUnansweredTurn,
  newIdempotencyKey,
  sendStatusMessage,
  turnStatusLabel,
  type AgentSendStatus,
  type ChatTurn,
} from '../notes/chatState'
import type { AgentConversation } from '../notes/types'

// Chat tab: the conversations about the open note, the selected conversation's
// transcript, and a composer. The reply is asynchronous — the user turn is
// persisted immediately and the events feed delivers the agent's answer, so the
// composer keeps working even when no agent runtime is configured.

export function AgentChatTab(): JSX.Element {
  const app = useApp()
  const [conversations, setConversations] = createSignal<AgentConversation[]>([])
  const [turns, setTurns] = createSignal<ChatTurn[]>([])
  const [draft, setDraft] = createSignal('')
  const [sending, setSending] = createSignal(false)
  const [sendStatus, setSendStatus] = createSignal<AgentSendStatus>()
  const [error, setError] = createSignal('')
  let conversationGeneration = 0
  let turnGeneration = 0

  const activeConversationId = createMemo(() =>
    app.conversationId() ?? conversations()[0]?.notebookId)
  const waiting = createMemo(() => hasPendingTurn(turns()))
  const unavailable = createMemo(() =>
    agentUnavailable(sendStatus()) || turns().some((turn) => turn.status === 'unavailable'))

  createEffect(() => {
    const noteId = app.state.noteId
    // A conversation started from another client shows up on the next catalog
    // reload, which the events feed schedules.
    void app.state.catalogRevision
    if (!noteId) {
      setConversations([])
      setTurns([])
      return
    }
    void loadConversations(noteId)
  })

  createEffect(() => {
    const conversationId = activeConversationId()
    if (!conversationId) {
      setTurns([])
      return
    }
    // Re-reads when the events feed reports a change to this conversation, which
    // is how a pending turn becomes an answered one.
    void app.state.notebookRevisions[conversationId]
    void loadTurns(conversationId)
  })

  const loadConversations = async (noteId: string) => {
    const current = ++conversationGeneration
    setError('')
    try {
      const values = await app.client.noteConversations(noteId)
      if (current !== conversationGeneration) return
      setConversations(values)
    } catch (loadError) {
      if (current !== conversationGeneration) return
      setConversations([])
      setError(errorMessage(loadError))
    }
  }

  const loadTurns = async (conversationNotebookId: string) => {
    const current = ++turnGeneration
    try {
      const notes = await app.client.notes(conversationNotebookId, 0)
      if (current !== turnGeneration) return
      setTurns(chatTurns(notes))
    } catch (loadError) {
      if (current !== turnGeneration) return
      setTurns([])
      setError(errorMessage(loadError))
    }
  }

  const send = async (userMarkdown: string) => {
    const subjectNoteId = app.state.noteId
    const body = userMarkdown.trim()
    if (!subjectNoteId || !body || sending()) return
    setSending(true)
    setError('')
    try {
      const conversationId = activeConversationId()
      const result = await app.client.sendAgentChatMessage({
        subjectNoteId,
        ...(conversationId ? { conversationNotebookId: conversationId } : {}),
        userMarkdown: body,
        idempotencyKey: newIdempotencyKey(),
      })
      setSendStatus(result.agentStatus as AgentSendStatus)
      setDraft('')
      const notebookId = result.conversationNotebookId
      if (notebookId && notebookId !== conversationId) app.openConversation(notebookId)
      await loadConversations(subjectNoteId)
      if (notebookId) await loadTurns(notebookId)
    } catch (sendError) {
      // The draft stays in the composer so a rejected message is not lost.
      setError(errorMessage(sendError))
    } finally {
      setSending(false)
    }
  }

  return (
    <div class="pane-section chat">
      <Show when={app.state.noteId} fallback={<p class="pane-empty">Open a note to chat about it.</p>}>
        <Show when={conversations().length > 0}>
          <label class="chat-picker">
            <span>Conversation</span>
            <select
              value={activeConversationId() ?? ''}
              onChange={(event) => app.openConversation(event.currentTarget.value || undefined)}
            >
              <For each={conversations()}>{(conversation) =>
                <option value={conversation.notebookId}>
                  {conversation.title} ({conversation.turnCount})
                </option>}
              </For>
            </select>
          </label>
          <button type="button" class="secondary" onClick={() => app.openConversation(undefined)}>
            New conversation
          </button>
        </Show>

        <Show when={unavailable()}>
          <p class="chat-banner" role="status">
            Agent runtime not configured. Messages are saved and answered once an agent is available.
          </p>
        </Show>
        <Show when={error()}><p class="note-inline-error" role="alert">{error()}</p></Show>

        <div class="chat-transcript" aria-label="Conversation transcript" aria-busy={waiting()}>
          <Show when={turns().length === 0}>
            <p class="pane-empty">No messages yet. Ask the agent about this note.</p>
          </Show>
          <For each={turns()}>{(turn) =>
            <article class="chat-turn">
              <div class="chat-message chat-user">
                <span class="chat-role">You</span>
                <MarkdownBody markdown={turn.userMarkdown} />
              </div>
              <div class="chat-message chat-agent">
                <span class="chat-role">
                  Agent
                  <Show when={turn.status !== 'answered'}>
                    <em class={`chat-badge status-${turn.status}`}>{turnStatusLabel(turn.status)}</em>
                  </Show>
                </span>
                <Show
                  when={turn.assistantMarkdown}
                  fallback={
                    <Show
                      when={turn.status === 'pending'}
                      fallback={<p class="pane-empty">{turn.error ?? 'No reply yet.'}</p>}
                    >
                      <div class="loading-state"><span class="loader" />Waiting for the agent…</div>
                    </Show>
                  }
                >{(markdown) => <MarkdownBody markdown={markdown()} />}</Show>
                <Show when={turn.status === 'failed' || (turn.status === 'unavailable' && isUnansweredTurn(turn))}>
                  <button
                    type="button"
                    class="secondary"
                    disabled={sending()}
                    onClick={() => void send(turn.userMarkdown)}
                  >Retry</button>
                </Show>
              </div>
            </article>}
          </For>
        </div>

        <Show when={sendStatus() && sendStatusMessage(sendStatus() as AgentSendStatus)}>{(message) =>
          <p class="pane-note" role="status">{message()}</p>}
        </Show>
        <label>
          <span class="sr-only">Message for the agent</span>
          <textarea
            aria-label="Message for the agent"
            rows={3}
            placeholder="Ask about this note"
            value={draft()}
            disabled={sending()}
            onInput={(event) => setDraft(event.currentTarget.value)}
            onKeyDown={(event) => {
              if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) void send(draft())
            }}
          />
        </label>
        <button type="button" disabled={sending() || draft().trim().length === 0} onClick={() => void send(draft())}>
          {sending() ? 'Sending…' : 'Send'}
        </button>
      </Show>
    </div>
  )
}
