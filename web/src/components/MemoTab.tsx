import type { NoteId, NotebookId } from '../notes/ids'
import { notebookPageLimit } from '../notes/client'
import { For, Show, createEffect, createMemo, createSignal, onCleanup, type JSX, type Setter } from 'solid-js'
import { formatTimestamp } from '../notes/format'
import { MarkdownBody } from './Markdown'
import { noteDisplayTitle } from '../notes/noteText'
import { errorMessage, useApp, type AppStore } from '../state/appStore'
import { createWritingDrafts } from '../state/writingDrafts'
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
  /** Stable identity for a subject whose backing notebook is created lazily. */
  draftKey?: string
  /** Continue this notebook's own conversation instead of a subject's memos. */
  conversationNotebookId?: NotebookId
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

/** Shown when the model catalog query fails. It is a transport error, not a
 * capability signal: the controls stay usable and the server validates the
 * send. The banner is retired by the next successful discovery. */
const catalogUnreachableMessage = 'Could not load the agent model catalog.'

export function MemoTab(props: MemoTabProps = {}): JSX.Element {
  const app = props.app ?? useApp()
  const [expanded, setExpanded] = createSignal(false)
  const [memos, setMemos] = createSignal<NoteComment[]>([])
  const [conversations, setConversations] = createSignal<AgentConversation[]>([])
  const [turnsByConversation, setTurnsByConversation] =
    createSignal<Array<{ conversationId: NotebookId; turns: ChatTurn[] }>>([])
  const [loading, setLoading] = createSignal(false)
  const [noteEdit, setNoteEdit] = createSignal(false)
  const [models, setModels] = createSignal<AgentModel[]>([])
  const [newConversation, setNewConversation] = createSignal(false)
  const [newConversationBoundary, setNewConversationBoundary] = createSignal(false)
  const [activeConversationId, setActiveConversationId] = createSignal<NotebookId>()
  const [configuredModel, setConfiguredModel] = createSignal<string | null>()
  // Kept apart from `error` so a timeline reload cannot wipe the report
  // before the user sees it; only a successful discovery retires it.
  const [catalogError, setCatalogError] = createSignal('')
  const [error, setError] = createSignal('')
  const [streamTurnId, setStreamTurnId] = createSignal<NoteId>()
  const [streamText, setStreamText] = createSignal('')
  let generation = 0
  let catalogGeneration = 0
  let streamGeneration = 0

  const subject = createMemo<MemoSubject | undefined>(() => {
    if (props.conversationNotebookId) return { kind: 'notebook', id: props.conversationNotebookId }
    if (props.subject !== undefined) return props.subject ?? undefined
    if (app.state.noteId) return { kind: 'note', id: app.state.noteId }
    if (app.state.notebookId) return { kind: 'notebook', id: app.state.notebookId }
    return undefined
  })
  const draftStore = app.writingDrafts ?? createWritingDrafts()
  const draftRecord = createMemo(() => {
    const current = subject()
    return draftStore.get(props.draftKey ?? (current
      ? `discussion:${current.kind}:${current.id}` : 'discussion:unselected'))
  })
  const draft = () => draftRecord().text()
  const setDraft = (text: string) => draftRecord().setText(text)
  const attachments = () => draftRecord().files()
  const setAttachments: Setter<File[]> = (value) => draftRecord().setFiles(value)
  const memoOnly = () => draftRecord().memoOnly()
  const setMemoOnly = (value: boolean) => draftRecord().setMemoOnly(value)
  const busy = () => draftRecord().busy()
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
    agentComposerExtensionsEnabled(memoOnly(), busy()))
  // Mirrors the server's updateNoteBody gate: the note's own flag and its
  // notebook's flag must both be clear (imported documents lock the notebook).
  const noteEditAvailable = createMemo(() =>
    canEnableNoteEdit(subject(), app.state.note, app.notebook()))

  // A note that stops being editable (navigation, locking) drops the toggle
  // rather than letting the next submit fail server-side.
  createEffect(() => {
    if (noteEdit() && !noteEditAvailable()) setNoteEdit(false)
  })

  // Model discovery populates the picker. It re-runs when the app's own
  // catalog reload succeeds (`catalogRevision` is bumped only on success), so a
  // failed request gets another chance once the server is reachable again.
  createEffect(() => {
    void app.state.catalogRevision
    // Runs can overlap: `catalogRevision` is bumped by a debounced refresh, so
    // a slow request can settle after a newer one. Same guard idiom as `load()`.
    const requested = ++catalogGeneration
    void app.client.agentModels().then((catalog) => {
      if (requested !== catalogGeneration) return
      setModels(catalog.models)
      setConfiguredModel(catalog.configuredModel)
      setCatalogError('')
    }).catch(() => {
      if (requested !== catalogGeneration) return
      // Report the failure and keep whatever catalog is already known. Clearing
      // `models` would make the normalization effect below re-derive the
      // selection from an empty list and silently overwrite the persisted
      // model the user chose. Staged attachments are untouched as well.
      setCatalogError(catalogUnreachableMessage)
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
      if (props.conversationNotebookId) {
        const conversationId = props.conversationNotebookId
        const [notes, comments] = await Promise.all([
          loadConversationNotes(conversationId), app.client.notebookComments(conversationId),
        ])
        const turns = conversationTurns(notes)
        if (requested !== generation) return
        setMemos(comments)
        setConversations([])
        setTurnsByConversation([{ conversationId, turns }])
        return
      }
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
        turns: conversationTurns(await loadConversationNotes(conversation.notebookId)).filter((turn) => !turn.memoOnly),
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

  const loadConversationNotes = async (id: NotebookId) => {
    const notes = await app.client.notes(id, 0)
    let pageSize = notes.length
    while (pageSize === notebookPageLimit) {
      const page = await app.client.notes(id, notes.length)
      notes.push(...page)
      pageSize = page.length
    }
    return notes
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
      let awaitingDurableReply = false
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
        if (poll.resync && !awaitingDurableReply) {
          // Payload eviction means this browser has an incomplete reply. Do
          // not present a stitched prefix and suffix as model output; durable
          // conversation state becomes authoritative when the turn finishes.
          awaitingDurableReply = true
          setStreamText('')
          await reload()
          if (current !== streamGeneration) return
        }
        if (!awaitingDurableReply && poll.chunks.length > 0) {
          setStreamText((text) => text + poll.chunks.join(''))
        }
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
    // Every reactive value the request builder needs is captured here, before
    // the awaits below, so the request that goes out is the one the user
    // submitted. Effects that are not gated on `busy()` can fire inside the
    // await window: the read-only effect clears `noteEdit()` when the note
    // stops being editable, and a successful re-discovery can re-normalize the
    // persisted model. The two non-captures are `idempotencyKey` (minted fresh
    // at the call on purpose) and `subject` (which may only exist once
    // `ensureSubject` resolves); neither reads reactive state.
    const effectiveNoteEdit = retry ? retry.noteEdit : noteEdit()
    // Captured, so a mid-send mutation of `attachments()` cannot change what
    // this request uploads. The chip-remove button is gated on `busy()` for the
    // matching reason: a withdrawal this capture cannot honour must not be
    // accepted, or the composer would confirm a removal the wire ignored.
    const stagedAttachments = retry ? [] : attachments()
    const effectiveModel = app.state.settings.agentModel
    const directConversationId = props.conversationNotebookId
    // The New chat button is gated on `busy()` so a click during the await
    // window cannot reroute an already-submitted message; the captures settle
    // the request itself in one direction.
    const effectiveConversations = retry ? [] : conversations()
    const effectiveConversationId = retry ? retry.conversationId : activeConversationId()
    const effectiveNewConversation = retry ? false : newConversation()
    const submittedDraft = draftRecord()
    let current = subject()
    if (!current && !props.ensureSubject) return
    submittedDraft.setBusy(true)
    setError('')
    try {
      current = current ?? await props.ensureSubject?.()
      if (!current) return
      const attachmentInputs = await Promise.all(stagedAttachments.map(fileToAttachment))
      // Nothing below reads a signal or a store field: every reactive value is
      // one of the captures above.
      const request = buildAgentChatComposerRequest({
        subject: current,
        conversations: effectiveConversations,
        activeConversationId: effectiveConversationId,
        newConversation: effectiveNewConversation,
        userMarkdown: body,
        idempotencyKey: newIdempotencyKey(),
        selectedModel: effectiveModel,
        noteEdit: effectiveNoteEdit,
        attachments: attachmentInputs,
      })
      if (directConversationId) {
        delete request.subjectNoteId
        delete request.subjectNotebookId
        request.conversationNotebookId = directConversationId
      }
      const result = await app.client.sendAgentChatMessage(request)
      if (!retry) {
        submittedDraft.setText('')
        submittedDraft.setFiles([])
        if (draftRecord() !== submittedDraft) return
        setNewConversation(false)
        if (result.conversationNotebookId) setActiveConversationId(result.conversationNotebookId)
      }
      if (draftRecord() !== submittedDraft) return
      await reload()
      if (result.turnNoteId && result.agentStatus === 'pending') startStream(result.turnNoteId)
    } catch (sendError) {
      // The draft stays in the composer so a rejected message is not lost.
      if (draftRecord() === submittedDraft) setError(errorMessage(sendError))
    } finally {
      submittedDraft.setBusy(false)
    }
  }

  const addMemoOnly = async () => {
    const body = draft().trim()
    if (!body || busy()) return
    let current = subject()
    const submittedDraft = draftRecord()
    if (!current && !props.ensureSubject) return
    submittedDraft.setBusy(true)
    setError('')
    try {
      current = current ?? await props.ensureSubject?.()
      if (!current) return
      if (current.kind === 'note') await app.client.addNoteComment(current.id, body)
      else await app.client.addNotebookComment(current.id, body)
      submittedDraft.setText('')
      if (draftRecord() !== submittedDraft) return
      await reload()
    } catch (addError) {
      if (draftRecord() === submittedDraft) setError(errorMessage(addError))
    } finally {
      submittedDraft.setBusy(false)
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
    const stagedDraft = draftRecord()
    const next = [...attachments(), ...Array.from(files)]
    const validation = await validateComposerFiles(next)
    if (!validation.accepted) {
      setError(validation.message)
      return
    }
    stagedDraft.setFiles(next)
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
          <button type="button" class="secondary" disabled={busy()} onClick={() => {
            const openingDraft = draftRecord()
            openingDraft.setBusy(true)
            void app.client.openMemoNotebook(entry.memo.commentId).then((notebook) => {
              setExpanded(false)
              app.openNotebookWithReturn(notebook.notebookId)
            }).catch((failure) => setError(errorMessage(failure))).finally(() => openingDraft.setBusy(false))
          }}>Open as notebook</button>
        </article>
      )
    }
    const turn = entry.turn
    const streamingHere = () => streamTurnId() === turn.noteId && streamText().length > 0
    return (
      <article class="chat-turn">
        <Show when={!props.conversationNotebookId}>
          <button type="button" class="secondary" onClick={() => {
            setExpanded(false)
            app.openNotebookWithReturn(entry.conversationId)
          }}>Open as notebook</button>
        </Show>
        <button type="button" class="secondary" onClick={() => {
          app.openNote(turn.noteId, entry.conversationId)
        }}>Branch from here</button>
        <div class="chat-message chat-user">
          <span class="chat-role">You</span>
          <MarkdownBody markdown={turn.userMarkdown} anchorIds={false} />
        </div>
        <Show when={!turn.memoOnly}><div class="chat-message chat-agent">
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
              disabled={busy()}
              onClick={() => void send(turn.userMarkdown, {
                conversationId: entry.conversationId,
                noteEdit: turn.mode === 'edit',
              })}
            >Retry</button>
          </Show>
        </div></Show>
      </article>
    )
  }

  return (
    <div class="pane-section chat" classList={{ 'chat-expanded': expanded() }}>
      <Show
        when={Boolean(subject()) || Boolean(props.ensureSubject)}
        fallback={<div class="learning-welcome"><h2>Make it make sense</h2><p>Open a notebook to ask questions, check your understanding, or save a thought.</p><p>Your discussion stays with the material you are studying.</p></div>}
      >
        <div class="learning-context">
          <span class="eyebrow">{subject()?.kind === 'note' ? 'Learning from this note' : 'Learning from this notebook'}</span>
          <strong>{props.subject !== undefined ? 'Selected topic' : app.state.note ? noteDisplayTitle(app.state.note) : app.notebook()?.title ?? 'Notebook'}</strong>
        </div>
        <button type="button" class="secondary" aria-expanded={expanded()}
          onClick={() => setExpanded(!expanded())}>
          {expanded() ? 'Close chat view' : 'Expand chat view'}
        </button>
        <Show when={!props.conversationNotebookId}>
          <button type="button" class="secondary" aria-label="New chat" title="Start a separate discussion about the same material" disabled={busy()} onClick={startNewChat}>New discussion</button>
        </Show>
        <Show when={loading() && entries().length === 0}>
          <div class="loading-state"><span class="loader" />Loading memos…</div>
        </Show>
        <Show when={unavailable()}>
          <p class="chat-banner" role="status">
            Agent runtime not configured. Sent messages are saved and answered once an agent is available.
          </p>
        </Show>
        <Show when={catalogError()}><p class="note-inline-error" role="alert">{catalogError()}</p></Show>
        <Show when={error()}><p class="note-inline-error" role="alert">{error()}</p></Show>

        <div class="chat-transcript" aria-label="Memo timeline" aria-busy={Boolean(streamTurnId())}>
          <Show when={!loading() && entries().length === 0 && !error()}>
            <div class="learning-starters"><p class="pane-empty">
              {props.emptyMessage
                ?? (subject()?.kind === 'note'
                  ? 'Explore this note in your own way.'
                  : 'Turn your notes into understanding.')}
            </p>
              <div class="learning-actions">
                <For each={[
                  { label: 'Explain simply', prompt: 'Explain the key ideas in this material in simple terms, with a concrete example. Point to the notes you use.' },
                  { label: 'Quiz me', prompt: 'Help me test my understanding of this material. Ask one question at a time, wait for my answer, then give feedback. Point to the relevant notes.' },
                  { label: 'Connect ideas', prompt: 'What are the most useful connections between the ideas in these notes? Distinguish what the notes say from your interpretation.' },
                ]}>{(starter) => <button type="button" class="secondary" disabled={busy()} onClick={() => {
                  setDraft(starter.prompt)
                  setMemoOnly(false)
                  setNoteEdit(false)
                }}>{starter.label}</button>}</For>
              </div>
            </div>
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
      >+</button>
      <button type="button" class={`composer-icon composer-mode ${props.memoOnly ? 'selected' : ''}`} aria-pressed={memoOnlyAttributes().ariaPressed} aria-label={memoOnlyAttributes().ariaLabel} title={memoOnlyAttributes().title} disabled={props.busy} onClick={props.onToggleMemoOnly}>{props.memoOnly ? 'Memo only' : 'Ask AI'}</button>
      <button
        type="button"
        class={`composer-icon composer-mode ${props.noteEdit ? 'selected' : ''}`}
        aria-pressed={noteEditAttributes().ariaPressed}
        aria-label={noteEditAttributes().ariaLabel}
        title={props.canNoteEdit || props.noteEdit ? noteEditAttributes().title : 'Note edit mode requires a writable note'}
        aria-disabled={!props.canNoteEdit && !props.noteEdit}
        disabled={props.busy || (!props.canNoteEdit && !props.noteEdit)}
        onClick={props.onToggleNoteEdit}
      >Edit note</button>
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
            <button type="button" title={`Remove ${file.name}`} disabled={props.busy} onClick={() => props.onRemoveAttachment(index)}>{file.name} ×</button>
          )}</div>
        </Show>
      </div>
      <select class="composer-model" aria-label="Agent model" title="Agent model" disabled={!props.extensionsEnabled} value={props.selectedModel ?? ''} onInput={(event) => props.onModelChange(event.currentTarget.value)}>
        <For each={props.models}>{(model) => <option value={model.modelId}>{model.displayName ?? model.modelId}</option>}</For>
      </select>
      <button type="button" class="composer-submit" aria-label={props.memoOnly ? 'Save memo' : 'Send message'} disabled={props.busy || !props.draft.trim()} onClick={props.onSubmit}>{props.busy ? 'Saving…' : props.memoOnly ? 'Save memo' : 'Send'}</button>
      <p class="composer-help">{props.memoOnly ? 'Saved with your material. AI will not reply.' : props.noteEdit ? 'AI can change this note. Describe the changes you want.' : 'Ask a question about the selected material. Enter to send; Shift+Enter for a new line.'}</p>
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
