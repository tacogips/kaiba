import type { NoteId, NotebookId } from '../notes/ids'
import { For, Show, createEffect, createMemo, createSignal, onCleanup, type JSX } from 'solid-js'
import { formatTimestamp } from '../notes/format'
import { NoteTransportError } from '../notes/client'
import { MarkdownBody } from './Markdown'
import { errorMessage, useApp, type AppStore } from '../state/appStore'
import {
  newIdempotencyKey,
  turnStatusLabel,
  type ChatTurn,
} from '../notes/chatState'
import {
  conversationTurns,
  memoTimeline,
  noteTitlesById,
  pendingStreamTurn,
  type MemoTimelineEntry,
} from '../notes/memoTimeline'
import type { AgentChatAttachmentInput, AgentConversation, AgentModel, NoteComment } from '../notes/types'
import {
  agentComposerExtensionsEnabled,
  buildAgentChatComposerRequest,
  canEnableNoteEdit,
  composerAttachmentMediaType,
  composerSubmitKind,
  memoOnlyControlAttributes,
  memoOnlyToggleResult,
  handleComposerKeyDown,
  normalizeSelectedAgentModel,
  noteEditControlAttributes,
  noteEditToggleResult,
  removeComposerAttachment,
  resetComposerForNewChat,
  validateComposerFiles,
} from '../notes/memoComposer'

// The unified memo pane: plain memos and agent chat are one timeline for the
// selected note, or for the whole notebook when no note is selected. The
// composer offers "Send" (the default agent answers, streaming) and
// "Memo only" (persist without the agent).

/** The memo pane addresses either a note or a whole notebook; the id type
 * follows the kind, so a notebook id can never reach a note-scoped call. */
export type MemoSubject =
  | { kind: 'note'; id: NoteId }
  | { kind: 'notebook'; id: NotebookId }

export interface MemoTabProps {
  /** An explicit store keeps the pane embeddable and enables integration tests
   * without changing the production context path. */
  app?: AppStore
  /** Overrides the selection-derived subject. `null` means "no subject yet"
   * (the timeline stays empty but the composer renders when `ensureSubject`
   * can create one on first submit) — the tag pane binds its memo notebook
   * this way. */
  subject?: MemoSubject | null
  /** Called on submit when no subject exists yet; the returned subject is
   * used for that submission (the tag pane creates its memo notebook here). */
  ensureSubject?: () => Promise<MemoSubject>
  /** Composer placeholder for the agent mode; defaults to the document
   * wording. */
  composerPlaceholder?: string
  /** Empty-timeline wording override. */
  emptyMessage?: string
}

/** Immediate discovery attempts before a transport failure is reported; a
 * schema rejection is conclusive on the first try. The budget is small on
 * purpose: real outages outlast any immediate retry, so recovery comes from
 * re-running on `catalogRevision` rather than from more attempts here. */
const catalogDiscoveryAttempts = 3

/** Shown when discovery cannot reach the catalog. The banner is retired by
 * `load()`'s unconditional `setError('')`, which re-runs on the same
 * `catalogRevision` bump that re-runs discovery — so no separate clear is
 * needed here, and adding one would be a line no test can pin. */
const catalogUnreachableMessage =
  'Could not load the agent model catalog. Model, attachment and note edit options stay unavailable until it loads.'

export function MemoTab(props: MemoTabProps = {}): JSX.Element {
  const app = props.app ?? useApp()
  const [memos, setMemos] = createSignal<NoteComment[]>([])
  const [conversations, setConversations] = createSignal<AgentConversation[]>([])
  const [turnsByConversation, setTurnsByConversation] =
    createSignal<Array<{ conversationId: NotebookId; turns: ChatTurn[] }>>([])
  const [loading, setLoading] = createSignal(false)
  const [busy, setBusy] = createSignal(false)
  const [draft, setDraft] = createSignal('')
  const [memoOnly, setMemoOnly] = createSignal(false)
  const [noteEdit, setNoteEdit] = createSignal(false)
  const [attachments, setAttachments] = createSignal<File[]>([])
  const [models, setModels] = createSignal<AgentModel[]>([])
  // Whether the server answered `agentModels` at all. An older server has no
  // such field, so the query rejects and every composer extension rests.
  const [catalogAvailable, setCatalogAvailable] = createSignal(false)
  // Discovery re-runs on this counter so a transport blip gets another chance
  // instead of condemning a capable server for the whole session.
  const [catalogAttempt, setCatalogAttempt] = createSignal(0)
  const [newConversation, setNewConversation] = createSignal(false)
  const [newConversationBoundary, setNewConversationBoundary] = createSignal(false)
  const [activeConversationId, setActiveConversationId] = createSignal<NotebookId>()
  const [configuredModel, setConfiguredModel] = createSignal<string | null>()
  const [error, setError] = createSignal('')
  const [streamTurnId, setStreamTurnId] = createSignal<NoteId>()
  const [streamText, setStreamText] = createSignal('')
  let generation = 0
  let catalogGeneration = 0
  let streamGeneration = 0

  const subject = createMemo<MemoSubject | undefined>(() => {
    if (props.subject !== undefined) return props.subject ?? undefined
    if (app.state.noteId) return { kind: 'note', id: app.state.noteId }
    if (app.state.notebookId) return { kind: 'notebook', id: app.state.notebookId }
    return undefined
  })
  const entries = createMemo<MemoTimelineEntry[]>(() =>
    memoTimeline(memos(), turnsByConversation()))
  const entriesBeforeBoundary = createMemo(() => {
    if (!newConversationBoundary()) return entries()
    const activeId = activeConversationId()
    if (!activeId) return entries()
    return entries().filter((entry) => entry.kind !== 'turn' || entry.conversationId !== activeId)
  })
  const entriesAfterBoundary = createMemo(() => {
    if (!newConversationBoundary()) return []
    const activeId = activeConversationId()
    if (!activeId) return []
    return entries().filter((entry) => entry.kind === 'turn' && entry.conversationId === activeId)
  })
  const noteTitles = createMemo(() => noteTitlesById(app.notes()))
  const unavailable = createMemo(() => entries().some(
    (entry) => entry.kind === 'turn' && entry.turn.status === 'unavailable'))
  // A memo over the id list (joined) stays referentially stable across reloads
  // that find the same conversations, so the reload effect below re-runs on
  // conversation-set changes without looping on every load's fresh array.
  const conversationIds = createMemo(() =>
    conversations().map((conversation) => conversation.notebookId).join('\n'))
  const extensionControlsEnabled = createMemo(() =>
    agentComposerExtensionsEnabled(catalogAvailable(), memoOnly(), busy()))
  // Mirrors the server's updateNoteBody gate: the note's own flag and its
  // notebook's flag must both be clear (imported documents lock the notebook).
  const noteEditAvailable = createMemo(() =>
    canEnableNoteEdit(subject(), app.state.note, app.notebook()))

  // A note that stops being editable (navigation, locking) drops the toggle
  // rather than letting the next submit fail server-side.
  createEffect(() => {
    if (noteEdit() && !noteEditAvailable()) setNoteEdit(false)
  })

  createEffect(() => {
    const attempt = catalogAttempt()
    // Re-run discovery when the app's own catalog reload succeeds. The store
    // increments `catalogRevision` only on success, so it is a genuine
    // server-is-reachable-again signal rather than a timer — and it is the same
    // trigger the reload effect below already uses. Without it the immediate
    // attempt budget, which any real outage outlives, would be the only chance
    // the session ever gets.
    void app.state.catalogRevision
    // Runs can overlap once discovery is re-runnable: `catalogRevision` is
    // bumped by a debounced refresh, so a slow request can settle after a newer
    // one. Same guard idiom as `load()` below.
    const requested = ++catalogGeneration
    void app.client.agentModels().then((catalog) => {
      if (requested !== catalogGeneration) return
      // The query answering is the capability signal, not `discoveryAvailable`:
      // a vendor that cannot enumerate models still accepts the extension
      // fields, and the configured model stays the fallback.
      setCatalogAvailable(true)
      setModels(catalog.models)
      setConfiguredModel(catalog.configuredModel)
      // The budget is per outage, not per session: a success earns the next
      // outage a fresh set of immediate attempts.
      setCatalogAttempt(0)
    }).catch((discoveryError: unknown) => {
      if (requested !== catalogGeneration) return
      setCatalogAvailable(false)
      // Only a schema-level rejection proves the server predates the composer
      // extensions. A network or HTTP failure says nothing about capability, so
      // treating it as an older server would rest every control for the rest of
      // the session against a server that understands them perfectly well.
      if (discoveryError instanceof NoteTransportError && discoveryError.kind !== 'graphql') {
        // Deliberately NOT clearing `models` here. A retryable blip must leave
        // the catalog intact, or the normalization effect below re-derives the
        // selection from an empty list and silently overwrites — and persists —
        // the model the user chose.
        if (attempt + 1 < catalogDiscoveryAttempts) {
          setCatalogAttempt(attempt + 1)
          return
        }
        setError(catalogUnreachableMessage)
        return
      }
      // Older server: the catalog is genuinely gone, so clear it.
      setModels([])
      // Older server. The controls rest by design, and anything staged before
      // discovery settled is dropped rather than silently withheld on send —
      // with an explanation, so files never vanish unannounced.
      if (attachments().length > 0) {
        setError('This server does not accept attachments, so the staged files were removed.')
      }
      setAttachments([])
    })
  })

  // Settings hydrate independently of model discovery. Keep this reactive so a
  // stale persisted selection is normalized even when hydration completes later.
  createEffect(() => {
    const normalized = normalizeSelectedAgentModel(
      app.state.settings.agentModel, models(), configuredModel()
    )
    if (normalized && normalized !== app.state.settings.agentModel) {
      app.updateSettings({ agentModel: normalized })
    }
  })

  // An explicit post-New-chat conversation is scoped to the current subject.
  // Changing notes/notebooks must never carry that id into another subject.
  let activeConversationSubject = ''
  createEffect(() => {
    const current = subject()
    const nextSubject = current ? `${current.kind}:${current.id}` : ''
    if (nextSubject === activeConversationSubject) return
    activeConversationSubject = nextSubject
    setActiveConversationId(undefined)
    setNewConversation(false)
    setNewConversationBoundary(false)
    setNoteEdit(false)
  })

  createEffect(() => {
    const current = subject()
    // Reload on any change the events feed reports for the subject notebook or
    // any loaded conversation notebook.
    if (current?.kind === 'notebook') void app.state.notebookRevisions[current.id]
    if (app.state.notebookId) void app.state.notebookRevisions[app.state.notebookId]
    for (const conversationId of conversationIds().split('\n')) {
      if (conversationId) void app.state.notebookRevisions[conversationId]
    }
    void app.state.catalogRevision
    if (!current) {
      generation += 1
      setMemos([])
      setConversations([])
      setTurnsByConversation([])
      return
    }
    void load(current)
  })

  // A pending turn (from this client or another) streams its reply in.
  createEffect(() => {
    const pending = pendingStreamTurn(entries())
    if (pending) {
      startStream(pending.noteId)
      return
    }
    // Nothing pending anymore: the persisted reply supersedes the stream text.
    if (streamTurnId()) stopStream()
  })

  onCleanup(() => { streamGeneration += 1 })

  const load = async (current: MemoSubject) => {
    const requested = ++generation
    setLoading(true)
    setError('')
    try {
      const [loadedMemos, loadedConversations] = await Promise.all([
        current.kind === 'note'
          ? app.client.noteComments(current.id)
          : app.client.notebookComments(current.id),
        current.kind === 'note'
          ? app.client.noteConversations(current.id)
          : app.client.notebookConversations(current.id),
      ])
      if (requested !== generation) return
      setMemos(loadedMemos)
      setConversations(loadedConversations)
      const turns = await Promise.all(loadedConversations.map(async (conversation) => ({
        conversationId: conversation.notebookId,
        turns: conversationTurns(await app.client.notes(conversation.notebookId, 0)),
      })))
      if (requested !== generation) return
      setTurnsByConversation(turns)
    } catch (loadError) {
      if (requested !== generation) return
      setError(errorMessage(loadError))
    } finally {
      if (requested === generation) setLoading(false)
    }
  }

  const reload = async () => {
    const current = subject()
    if (current) await load(current)
  }

  const stopStream = () => {
    streamGeneration += 1
    setStreamTurnId(undefined)
    setStreamText('')
  }

  /** Long-polls the agent reply chunk stream for one turn, rendering the reply
   * incrementally until the server reports the turn finished. */
  const startStream = (turnNoteId: NoteId) => {
    if (streamTurnId() === turnNoteId) return
    const current = ++streamGeneration
    setStreamTurnId(turnNoteId)
    setStreamText('')
    void (async () => {
      let cursor = 0
      let failures = 0
      while (current === streamGeneration) {
        let poll
        try {
          poll = await app.client.pollAgentReplyStream(turnNoteId, cursor)
          failures = 0
        } catch (pollError) {
          // Backed-off retries, then give up: a turn whose stream endpoint
          // keeps failing must not poll every two seconds forever.
          failures += 1
          if (failures >= 5) {
            if (current === streamGeneration) {
              setError(errorMessage(pollError))
              stopStream()
            }
            return
          }
          await delay(2_000 * failures)
          continue
        }
        if (current !== streamGeneration) return
        if (poll.chunks.length > 0) setStreamText((text) => text + poll.chunks.join(''))
        cursor = poll.cursor
        if (poll.done) {
          await reload()
          if (current === streamGeneration) {
            setStreamTurnId(undefined)
            setStreamText('')
          }
          return
        }
      }
    })()
  }

  /** Sends a composer message, or — with `retry` — resends a failed turn
   * verbatim into its own conversation without touching the composer's draft,
   * staged attachments, or note-edit toggle. */
  const send = async (
    userMarkdown: string,
    retry?: { conversationId: NotebookId; noteEdit: boolean },
  ) => {
    const body = userMarkdown.trim()
    if (!body || busy()) return
    // Guard the EFFECTIVE request, not one call site. Both paths can carry an
    // extension the capability gate cannot withdraw at the control: retry takes
    // noteEdit from the persisted turn rather than the toggle, and a direct send
    // carries whatever the toggle latched before availability flipped true ->
    // false (nothing resets it) plus any chip the transport branch deliberately
    // kept. Withholding those fields silently would let the server answer an
    // edit request as a plain memo — the masquerade web-chatbook-ui.md:254-257
    // forbids — or drop a file the user can still see staged. Refuse instead,
    // which preserves both the toggle and the chips for when the catalog returns.
    // Read availability ONCE and reuse that single value for both the guards
    // and the builder below. The builder runs after two awaits, and discovery
    // (which re-runs on every `catalogRevision` bump and is not gated on
    // `busy()`) can flip availability true -> false inside that window. Re-reading
    // it there would let a request the guard already admitted go out with its
    // extension fields quietly withheld — the same masquerade the guard exists to
    // prevent. Captured, the request is atomically either fully extended or
    // refused; if the server does turn out to be old mid-send it rejects the
    // extension field loudly, which is the intended failure mode.
    const extensionsAvailable = catalogAvailable()
    const effectiveNoteEdit = retry ? retry.noteEdit : noteEdit()
    const effectiveAttachments = retry ? 0 : attachments().length
    if (!extensionsAvailable && effectiveNoteEdit) {
      setError('Note edit mode is unavailable until the agent model catalog loads, so this note edit was not sent.')
      return
    }
    if (!extensionsAvailable && effectiveAttachments > 0) {
      setError('Attachments are unavailable until the agent model catalog loads, so this message was not sent. The staged files were kept.')
      return
    }
    let current = subject()
    if (!current && !props.ensureSubject) return
    setBusy(true)
    setError('')
    try {
      current = current ?? await props.ensureSubject?.()
      if (!current) return
      const attachmentInputs = retry ? [] : await Promise.all(attachments().map(fileToAttachment))
      const result = await app.client.sendAgentChatMessage(buildAgentChatComposerRequest({
        subject: current,
        conversations: retry ? [] : conversations(),
        activeConversationId: retry ? retry.conversationId : activeConversationId(),
        newConversation: retry ? false : newConversation(),
        userMarkdown: body,
        idempotencyKey: newIdempotencyKey(),
        selectedModel: app.state.settings.agentModel,
        // Both reuse the values the guard admitted. `noteEdit()` can be cleared
        // by the read-only effect above during the same await window.
        noteEdit: effectiveNoteEdit,
        extensionsAvailable,
        attachments: attachmentInputs,
      }))
      if (!retry) {
        setDraft('')
        setAttachments([])
        setNewConversation(false)
        if (result.conversationNotebookId) setActiveConversationId(result.conversationNotebookId)
      }
      await reload()
      if (result.turnNoteId && result.agentStatus === 'pending') startStream(result.turnNoteId)
    } catch (sendError) {
      // The draft stays in the composer so a rejected message is not lost.
      setError(errorMessage(sendError))
    } finally {
      setBusy(false)
    }
  }

  const addMemoOnly = async () => {
    const body = draft().trim()
    if (!body || busy()) return
    let current = subject()
    if (!current && !props.ensureSubject) return
    setBusy(true)
    setError('')
    try {
      current = current ?? await props.ensureSubject?.()
      if (!current) return
      if (current.kind === 'note') await app.client.addNoteComment(current.id, body)
      else await app.client.addNotebookComment(current.id, body)
      setDraft('')
      await reload()
    } catch (addError) {
      setError(errorMessage(addError))
    } finally {
      setBusy(false)
    }
  }

  const submit = () => {
    if (composerSubmitKind(memoOnly()) === 'memo') void addMemoOnly()
    else void send(draft())
  }

  const startNewChat = () => {
    const reset = resetComposerForNewChat<File>()
    stopStream()
    setNewConversation(reset.newConversation)
    setNewConversationBoundary(true)
    setActiveConversationId(undefined)
    setDraft(reset.draft)
    setAttachments(reset.attachments)
    setError(reset.error)
  }

  const stageFiles = async (files: FileList | null) => {
    if (!files) return
    const next = [...attachments(), ...Array.from(files)]
    const validation = await validateComposerFiles(next)
    if (!validation.accepted) {
      setError(validation.message)
      return
    }
    setAttachments(next)
  }

  const memoAttribution = (memo: NoteComment): string | undefined => {
    if (subject()?.kind !== 'notebook') return undefined
    if (!memo.noteId) return 'Notebook memo'
    return noteTitles().get(memo.noteId) ?? memo.noteId
  }

  const renderTimelineEntry = (entry: MemoTimelineEntry): JSX.Element => {
    if (entry.kind === 'memo') {
      return (
        <article class="memo">
          <header>
            <strong>{entry.memo.author}</strong>
            <span>
              <Show when={memoAttribution(entry.memo)}>{(attribution) =>
                <button
                  type="button"
                  class="memo-note-ref"
                  disabled={!entry.memo.noteId}
                  onClick={() => {
                    if (entry.memo.noteId) app.openNote(entry.memo.noteId)
                  }}
                >{attribution()}</button>}
              </Show>
              {formatTimestamp(entry.memo.createdAt)}
            </span>
          </header>
          <MarkdownBody markdown={entry.memo.bodyMarkdown} anchorIds={false} />
        </article>
      )
    }
    const turn = entry.turn
    const streamingHere = () => streamTurnId() === turn.noteId && streamText().length > 0
    return (
      <article class="chat-turn">
        <div class="chat-message chat-user">
          <span class="chat-role">You</span>
          <MarkdownBody markdown={turn.userMarkdown} anchorIds={false} />
        </div>
        <div class="chat-message chat-agent">
          <span class="chat-role">
            Agent
            <Show when={turn.mode === 'edit'}>
              <em class="chat-badge mode-edit">Note edit</em>
            </Show>
            <Show when={turn.status !== 'answered'}>
              <em class={`chat-badge status-${turn.status}`}>
                {streamingHere() ? 'Streaming' : turnStatusLabel(turn.status)}
              </em>
            </Show>
          </span>
          <Show
            when={turn.assistantMarkdown}
            fallback={
              <Show
                when={streamingHere()}
                fallback={
                  <Show
                    when={turn.status === 'pending'}
                    fallback={<p class="pane-empty">{turn.error ?? 'No reply yet.'}</p>}
                  >
                    <div class="loading-state"><span class="loader" />Waiting for the agent…</div>
                  </Show>
                }
              >
                <MarkdownBody markdown={streamText()} anchorIds={false} />
              </Show>
            }
          >{(markdown) => <MarkdownBody markdown={markdown()} anchorIds={false} />}</Show>
          <Show when={turn.status === 'failed' || turn.status === 'unavailable'}>
            <button
              type="button"
              class="secondary"
              disabled={busy() || (turn.mode === 'edit' && !catalogAvailable())}
              onClick={() => void send(turn.userMarkdown, {
                conversationId: entry.conversationId,
                noteEdit: turn.mode === 'edit',
              })}
            >Retry</button>
          </Show>
        </div>
      </article>
    )
  }

  return (
    <div class="pane-section chat">
      <Show
        when={Boolean(subject()) || Boolean(props.ensureSubject)}
        fallback={<p class="pane-empty">Open a notebook or note to read and write memos.</p>}
      >
        <button type="button" class="new-chat-button" aria-label="New chat" title="New chat" onClick={startNewChat}>＋</button>
        <Show when={loading() && entries().length === 0}>
          <div class="loading-state"><span class="loader" />Loading memos…</div>
        </Show>
        <Show when={unavailable()}>
          <p class="chat-banner" role="status">
            Agent runtime not configured. Sent messages are saved and answered once an agent is available.
          </p>
        </Show>
        <Show when={error()}><p class="note-inline-error" role="alert">{error()}</p></Show>

        <div class="chat-transcript" aria-label="Memo timeline" aria-busy={Boolean(streamTurnId())}>
          <Show when={!loading() && entries().length === 0 && !error()}>
            <p class="pane-empty">
              {props.emptyMessage
                ?? (subject()?.kind === 'note'
                  ? 'No memos on this note yet.'
                  : 'No memos in this notebook yet.')}
            </p>
          </Show>
          <For each={entriesBeforeBoundary()}>{renderTimelineEntry}</For>
          <Show when={newConversationBoundary()}>
            <div class="new-conversation-boundary" role="status" aria-live="polite" tabIndex={-1}>
              New conversation
            </div>
          </Show>
          <For each={entriesAfterBoundary()}>{renderTimelineEntry}</For>
        </div>

        <MemoComposerControls
          memoOnly={memoOnly()}
          noteEdit={noteEdit()}
          canNoteEdit={noteEditAvailable()}
          busy={busy()}
          placeholder={props.composerPlaceholder}
          draft={draft()}
          attachments={attachments()}
          models={models()}
          selectedModel={app.state.settings.agentModel}
          extensionsEnabled={extensionControlsEnabled()}
          catalogAvailable={catalogAvailable()}
          onStageFiles={stageFiles}
          onToggleMemoOnly={() => {
            const outcome = memoOnlyToggleResult(memoOnly(), attachments().length, noteEdit())
            setMemoOnly(outcome.selected)
            if (outcome.error) setError(outcome.error)
          }}
          onToggleNoteEdit={() => {
            const outcome = noteEditToggleResult(noteEdit(), {
              canEdit: noteEditAvailable(),
              memoOnly: memoOnly(),
            })
            setNoteEdit(outcome.selected)
            if (outcome.error) setError(outcome.error)
          }}
          onDraftChange={setDraft}
          onRemoveAttachment={(index) => setAttachments((files) => removeComposerAttachment(files, index))}
          onModelChange={(model) => app.updateSettings({ agentModel: model || undefined })}
          onSubmit={submit}
        />
      </Show>
    </div>
  )
}

export interface MemoComposerControlsProps {
  memoOnly: boolean
  noteEdit: boolean
  /** Whether the current subject is a writable note (both read-only flags
   * clear); the toggle renders disabled otherwise. */
  canNoteEdit: boolean
  busy: boolean
  /** Agent-mode placeholder override (memo-only keeps its own wording). */
  placeholder?: string
  draft: string
  attachments: readonly File[]
  models: readonly AgentModel[]
  selectedModel?: string
  extensionsEnabled: boolean
  /** Whether the server answered the composer-extension catalog. Required so
   * every call site states its answer instead of inheriting a default that
   * would fail open against an older server. */
  catalogAvailable: boolean
  onStageFiles(files: FileList | null): void | Promise<void>
  onToggleMemoOnly(): void
  onToggleNoteEdit(): void
  onDraftChange(value: string): void
  onRemoveAttachment(index: number): void
  onModelChange(model: string): void
  onSubmit(): void
}

/** The actual composer subtree is isolated so static accessibility rendering
 * and event decisions are covered independently of async timeline loading. */
export function MemoComposerControls(props: MemoComposerControlsProps): JSX.Element {
  const memoOnlyAttributes = () => memoOnlyControlAttributes(props.memoOnly)
  const noteEditAttributes = () => noteEditControlAttributes(props.noteEdit)
  let attachmentPicker: HTMLInputElement | undefined
  return (
    <div class="memo-composer">
      <input
        class="sr-only"
        type="file"
        multiple
        ref={(element) => { attachmentPicker = element }}
        disabled={!props.extensionsEnabled}
        onChange={(event) => void props.onStageFiles(event.currentTarget.files)}
      />
      <button
        type="button"
        class="composer-icon"
        title="Attach text files"
        aria-label="Attach text files"
        aria-disabled={!props.extensionsEnabled}
        disabled={!props.extensionsEnabled}
        onClick={() => attachmentPicker?.click()}
      >＋</button>
      <button type="button" class={`composer-icon ${props.memoOnly ? 'selected' : ''}`} aria-pressed={memoOnlyAttributes().ariaPressed} aria-label={memoOnlyAttributes().ariaLabel} title={memoOnlyAttributes().title} disabled={props.busy} onClick={props.onToggleMemoOnly}>▣</button>
      <button
        type="button"
        class={`composer-icon ${props.noteEdit ? 'selected' : ''}`}
        aria-pressed={noteEditAttributes().ariaPressed}
        aria-label={noteEditAttributes().ariaLabel}
        title={props.canNoteEdit || props.noteEdit ? noteEditAttributes().title : 'Note edit mode requires a writable note'}
        aria-disabled={(!props.catalogAvailable && !props.noteEdit) || (!props.canNoteEdit && !props.noteEdit)}
        disabled={props.busy || (!props.catalogAvailable && !props.noteEdit) || (!props.canNoteEdit && !props.noteEdit)}
        onClick={props.onToggleNoteEdit}
      >✎</button>
      <div class="composer-main">
        <textarea
          aria-label="New memo or agent message"
          rows={2}
          placeholder={props.memoOnly
            ? 'Write a memo'
            : props.noteEdit
              ? 'Describe the change to make to this note'
              : props.placeholder ?? 'Ask about this document'}
          value={props.draft}
          disabled={props.busy}
          onInput={(event) => props.onDraftChange(event.currentTarget.value)}
          onKeyDown={(event) => {
            handleComposerKeyDown(event, { busy: props.busy, hasDraft: Boolean(props.draft.trim()) }, props.onSubmit)
          }}
        />
        <Show when={props.attachments.length > 0}>
          <div class="attachment-chips">{props.attachments.map((file, index) =>
            <button type="button" title={`Remove ${file.name}`} onClick={() => props.onRemoveAttachment(index)}>{file.name} ×</button>
          )}</div>
        </Show>
      </div>
      <select class="composer-model" aria-label="Agent model" title="Agent model" disabled={!props.extensionsEnabled} value={props.selectedModel ?? ''} onInput={(event) => props.onModelChange(event.currentTarget.value)}>
        <For each={props.models}>{(model) => <option value={model.modelId}>{model.displayName ?? model.modelId}</option>}</For>
      </select>
      <button type="button" class="composer-submit" aria-label={props.memoOnly ? 'Save memo' : 'Send message'} disabled={props.busy || !props.draft.trim()} onClick={props.onSubmit}>↑</button>
    </div>
  )
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds))
}

async function fileToAttachment(file: File): Promise<AgentChatAttachmentInput> {
  const bytes = new Uint8Array(await file.arrayBuffer())
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return {
    contentBase64: btoa(binary),
    mediaType: composerAttachmentMediaType(file) ?? '',
    originalFilename: file.name,
  }
}
