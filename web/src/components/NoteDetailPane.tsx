import { For, Show, createEffect, createMemo, createSignal } from 'solid-js'
import { MarkdownBody } from './Markdown'
import { NoteGraphQLClient, notebookPageLimit } from '../notes/client'
import { noteFileURL, type NoteDetail, type NoteLinkProposal, type NoteWorkspaceClient } from '../notes/workspace'
import type { NoteSearchResult } from '../notes/types'
import {
  adjacentNoteId,
  allowedLinkKind,
  applyRewrite,
  attachmentLabel,
  attachmentView,
  counterpartNoteId,
  emptyReaderWindow,
  isImageAttachment,
  linkLabel,
  linkStableId,
  needsEarlierPage,
  needsLaterPage,
  noteDisplayTitle,
  noteTagNames,
  earlierPageRequest,
  laterPageOffset,
  appendReaderPage,
  clampImageZoom,
  imageZoomLevels,
  noteExportFilename,
  openLinkProposals,
  prependReaderPage,
  readerPageSize,
  readerPositionLabel,
  replaceReaderNote,
  rewriteResultIsFresh,
  selectedText,
  selectionIsValid,
  selectionQuestionComment,
  workspaceErrorMessage,
  type ReaderWindow,
  type SelectionRange,
} from './NoteDetailLogic'

type AssistantMode = 'rewrite' | 'question'

interface RewriteDraft {
  rewrittenMarkdown: string
  summary: string | null
  submittedDraft: string
  submittedRange?: SelectionRange
  submittedSelectedText?: string
}

/** Note reader, editor and metadata pane for the RielaApp-hosted workspace,
 * porting RielaNoteDetailView + RielaNoteMetadataPane: book-like paging through
 * a notebook's notes, body editing, comments, links, files and the two
 * assistant flows (rewrite and selection question). */
export function NoteDetailPane(props: {
  notebookId: string
  notebookTitle: string
  notebookReadOnly?: boolean
  noteId?: string
  client: NoteGraphQLClient
  workspace: NoteWorkspaceClient
  onOpenNote?: (noteId: string, notebookId: string) => void
  onNotebookChanged?: () => void
  onAskAgent?: (payload: { noteId: string; title: string; bodyMarkdown: string }) => void
  onDirtyChange?: (dirty: boolean) => void
}) {
  const [detail, setDetail] = createSignal<NoteDetail>()
  const [reader, setReader] = createSignal<ReaderWindow>(emptyReaderWindow)
  const [loading, setLoading] = createSignal(false)
  const [error, setError] = createSignal('')
  const [message, setMessage] = createSignal('')
  const [editing, setEditing] = createSignal(false)
  const [draft, setDraft] = createSignal('')
  const [selection, setSelection] = createSignal<SelectionRange>()
  const [saving, setSaving] = createSignal(false)
  const [editError, setEditError] = createSignal('')
  const [commentDraft, setCommentDraft] = createSignal('')
  const [commentBusy, setCommentBusy] = createSignal(false)
  const [commentError, setCommentError] = createSignal('')
  const [assistantMode, setAssistantMode] = createSignal<AssistantMode>('rewrite')
  const [instruction, setInstruction] = createSignal('')
  const [assistantBusy, setAssistantBusy] = createSignal(false)
  const [assistantError, setAssistantError] = createSignal('')
  const [rewriteDraft, setRewriteDraft] = createSignal<RewriteDraft>()
  const [answerMarkdown, setAnswerMarkdown] = createSignal('')
  const [proposals, setProposals] = createSignal<NoteLinkProposal[]>([])
  const [proposalsBusy, setProposalsBusy] = createSignal(false)
  const [proposalsOpen, setProposalsOpen] = createSignal(false)
  const [linkQuery, setLinkQuery] = createSignal('')
  const [linkResults, setLinkResults] = createSignal<NoteSearchResult[]>([])
  const [linkSearchOpen, setLinkSearchOpen] = createSignal(false)
  const [linkKind, setLinkKind] = createSignal('related')
  const [linkBusy, setLinkBusy] = createSignal(false)
  const [tagDraft, setTagDraft] = createSignal('')
  const [tagBusy, setTagBusy] = createSignal(false)
  const [copied, setCopied] = createSignal(false)
  const [imageZoom, setImageZoom] = createSignal(1)
  let editorField: HTMLTextAreaElement | undefined
  let copiedTimer: ReturnType<typeof setTimeout> | undefined
  // Every load and selection-scoped write carries the generation it started in;
  // a result from a superseded note is dropped instead of overwriting state.
  let generation = 0

  const note = () => detail()?.note
  const attachments = createMemo(() =>
    (detail()?.files ?? []).map(attachmentView).filter((file) => file !== undefined))
  const tagNames = createMemo(() => noteTagNames(detail()?.note))
  const position = createMemo(() => {
    const current = note()
    return current ? readerPositionLabel(reader(), current.noteId) : undefined
  })
  const armedSelection = createMemo(() =>
    selectionIsValid(selection(), draft()) ? selection() : undefined)
  const canPrevious = createMemo(() => {
    const current = note()
    if (!current || editing()) return false
    return Boolean(adjacentNoteId(reader(), current.noteId, -1)) || reader().hasEarlier
  })
  const canNext = createMemo(() => {
    const current = note()
    if (!current || editing()) return false
    return Boolean(adjacentNoteId(reader(), current.noteId, 1)) || reader().hasMore
  })

  createEffect(() => {
    const notebookId = props.notebookId
    const requestedNoteId = props.noteId
    void load(notebookId, requestedNoteId)
  })

  // Mirror the native unsaved-edit guard: the host view consults this before
  // switching notebooks or closing the pane while an edit is in flight.
  createEffect(() => {
    const dirty = editing() && draft() !== (note()?.bodyMarkdown ?? '')
    props.onDirtyChange?.(dirty)
  })

  const resetNoteState = () => {
    setEditing(false)
    setDraft('')
    setSelection(undefined)
    setEditError('')
    setCommentDraft('')
    setCommentError('')
    setInstruction('')
    setAssistantMode('rewrite')
    setAssistantError('')
    setRewriteDraft(undefined)
    setAnswerMarkdown('')
    setProposals([])
    setProposalsOpen(false)
    setLinkSearchOpen(false)
    setLinkResults([])
    setLinkQuery('')
    setTagDraft('')
  }

  const load = async (notebookId: string, requestedNoteId?: string) => {
    const current = ++generation
    resetNoteState()
    setLoading(true)
    setError('')
    setMessage('')
    try {
      const loaded = requestedNoteId
        ? await props.workspace.noteDetail(requestedNoteId)
        : await props.workspace.firstNote(notebookId)
      if (current !== generation) return
      setDetail(loaded ?? undefined)
      setReader(emptyReaderWindow)
      if (!loaded) return
      const window = await props.workspace.notesWindow(loaded.note.noteId, readerPageSize)
      if (current !== generation) return
      setReader({
        notes: window.notes,
        startOffset: window.startOffset,
        hasEarlier: window.hasEarlierNotes,
        hasMore: window.hasMoreNotes,
      })
    } catch (loadError) {
      if (current !== generation) return
      setError(workspaceErrorMessage(loadError))
    } finally {
      if (current === generation) setLoading(false)
    }
  }

  /** Navigation is routed through the workspace so the requested note stays the
   * single source of truth (and a note in another notebook selects it too);
   * without a handler the pane falls back to loading in place. */
  const openNote = (noteId: string, notebookId?: string) => {
    if (props.onOpenNote) {
      props.onOpenNote(noteId, notebookId ?? props.notebookId)
      return
    }
    void load(notebookId ?? props.notebookId, noteId)
  }

  const loadAdjacentPage = async (direction: 1 | -1): Promise<boolean> => {
    const current = generation
    const window = reader()
    try {
      if (direction > 0) {
        if (!window.hasMore) return false
        const page = await props.client.notes(props.notebookId, laterPageOffset(window))
        if (current !== generation) return false
        setReader((value) => appendReaderPage(value, page, notebookPageLimit))
        return true
      }
      const request = earlierPageRequest(window, notebookPageLimit)
      if (!window.hasEarlier || !request) return false
      const page = await props.client.notes(props.notebookId, request.offset)
      if (current !== generation) return false
      setReader((value) => prependReaderPage(value, page.slice(0, request.limit), request.offset))
      return true
    } catch (pageError) {
      if (current === generation) setMessage(`Could not load more notes: ${workspaceErrorMessage(pageError)}`)
      return false
    }
  }

  const step = async (delta: 1 | -1) => {
    const current = note()
    if (!current || editing()) return
    const direct = adjacentNoteId(reader(), current.noteId, delta)
    if (direct) {
      openNote(direct)
      return
    }
    // No neighbour is loaded: only reach for another page when this really is
    // the window edge and the notebook still has notes on that side.
    const atEdge = delta > 0
      ? needsLaterPage(reader(), current.noteId, 1)
      : needsEarlierPage(reader(), current.noteId, 1)
    if (!atEdge || !(await loadAdjacentPage(delta))) return
    const target = adjacentNoteId(reader(), current.noteId, delta)
    if (target) openNote(target)
  }

  const startEditing = () => {
    const current = note()
    if (!current || current.readOnly || props.notebookReadOnly) return
    setDraft(current.bodyMarkdown)
    setSelection(undefined)
    setEditError('')
    setRewriteDraft(undefined)
    setAnswerMarkdown('')
    setAssistantError('')
    setEditing(true)
  }

  const cancelEditing = () => {
    setEditing(false)
    setDraft('')
    setSelection(undefined)
    setEditError('')
    setRewriteDraft(undefined)
    setAssistantError('')
  }

  const applyDetail = (updated: NoteDetail) => {
    setDetail(updated)
    setReader((value) => replaceReaderNote(value, updated.note))
  }

  const saveBody = async (bodyMarkdown: string, closeEditor: boolean) => {
    const current = note()
    if (!current) return
    const started = generation
    setSaving(true)
    setEditError('')
    try {
      const updated = await props.workspace.updateNoteBody(current.noteId, bodyMarkdown)
      if (started !== generation) return
      applyDetail(updated)
      setDraft(updated.note.bodyMarkdown)
      if (closeEditor) cancelEditing()
      setMessage('Saved the note body.')
    } catch (saveError) {
      // Keep the editor open with the draft intact so the edit is never lost.
      if (started === generation) setEditError(workspaceErrorMessage(saveError))
    } finally {
      if (started === generation) setSaving(false)
    }
  }

  const toggleReadOnly = async () => {
    const current = note()
    const currentDetail = detail()
    if (!current || !currentDetail) return
    const started = generation
    try {
      const updated = await props.client.setNoteReadOnly(current.noteId, !current.readOnly)
      if (started !== generation) return
      applyDetail({ ...currentDetail, note: updated })
      if (updated.readOnly) cancelEditing()
      setMessage(updated.readOnly ? 'Note is now read-only.' : 'Note is now editable.')
    } catch (toggleError) {
      if (started === generation) setMessage(workspaceErrorMessage(toggleError))
    }
  }

  const addComment = async () => {
    const current = note()
    const body = commentDraft()
    if (!current || !body.trim()) return
    const started = generation
    setCommentBusy(true)
    setCommentError('')
    try {
      const updated = await props.workspace.addComment(current.noteId, body)
      if (started !== generation) return
      applyDetail(updated)
      setCommentDraft('')
    } catch (addError) {
      // Keep the draft comment so a failed add is not lost.
      if (started === generation) setCommentError(workspaceErrorMessage(addError))
    } finally {
      if (started === generation) setCommentBusy(false)
    }
  }

  const promoteComment = async (commentId: string) => {
    const current = note()
    if (!current) return
    const started = generation
    setCommentError('')
    try {
      const updated = await props.workspace.promoteComment(current.noteId, commentId)
      if (started !== generation) return
      applyDetail(updated)
      setMessage('Promoted the comment into a linked notebook.')
      props.onNotebookChanged?.()
    } catch (promoteError) {
      if (started === generation) setCommentError(workspaceErrorMessage(promoteError))
    }
  }

  const submitAssistant = async () => {
    if (assistantMode() === 'question') await askSelectionQuestion()
    else await requestRewrite()
  }

  const requestRewrite = async () => {
    const current = note()
    const text = instruction().trim()
    if (!current || !text || assistantBusy()) return
    const started = generation
    const submittedDraft = draft()
    const range = armedSelection()
    const selected = selectedText(submittedDraft, range)
    setAssistantBusy(true)
    setAssistantError('')
    setRewriteDraft(undefined)
    try {
      const result = await props.workspace.rewrite(current.noteId, {
        instruction: text,
        bodyMarkdown: submittedDraft,
        ...(selected ? { selectedText: selected, selectionStart: range?.start, selectionEnd: range?.end } : {}),
      })
      if (started !== generation) return
      setRewriteDraft({
        rewrittenMarkdown: result.rewrittenMarkdown,
        summary: result.summary,
        submittedDraft,
        submittedRange: range,
        submittedSelectedText: selected,
      })
    } catch (rewriteError) {
      if (started === generation) setAssistantError(workspaceErrorMessage(rewriteError))
    } finally {
      if (started === generation) setAssistantBusy(false)
    }
  }

  const applyRewriteDraft = async () => {
    const pending = rewriteDraft()
    if (!pending) return
    if (!rewriteResultIsFresh({
      currentDraft: draft(),
      submittedDraft: pending.submittedDraft,
      submittedRange: pending.submittedRange,
      submittedSelectedText: pending.submittedSelectedText,
    })) {
      setAssistantError('The draft changed while the edit agent was running. Retry with the latest draft.')
      setRewriteDraft(undefined)
      return
    }
    const applied = applyRewrite(draft(), pending.submittedRange, pending.rewrittenMarkdown)
    setDraft(applied.body)
    setSelection(applied.range)
    setRewriteDraft(undefined)
    setInstruction('')
    await saveBody(applied.body, false)
  }

  const askSelectionQuestion = async () => {
    const current = note()
    const question = instruction().trim()
    const range = armedSelection()
    const selected = selectedText(draft(), range)
    if (!current || !question || assistantBusy()) return
    if (!selected || !range) {
      setAssistantError('Select the text to ask about first.')
      return
    }
    const started = generation
    setAssistantBusy(true)
    setAssistantError('')
    setAnswerMarkdown('')
    try {
      const answer = await props.workspace.selectionQuestion(current.noteId, {
        question,
        bodyMarkdown: draft(),
        selectedText: selected,
        selectionStart: range.start,
        selectionEnd: range.end,
      })
      if (started !== generation) return
      // Native persists the answer as an agent-authored comment; mirroring that
      // keeps the Q&A with the note instead of only on screen.
      const updated = await props.workspace.addComment(
        current.noteId,
        selectionQuestionComment({ selectedText: selected, question, answerMarkdown: answer.answerMarkdown }),
        'note-agent',
      )
      if (started !== generation) return
      applyDetail(updated)
      setAnswerMarkdown(answer.answerMarkdown)
      setInstruction('')
      setMessage('Saved the answer as a comment.')
    } catch (questionError) {
      if (started === generation) setAssistantError(workspaceErrorMessage(questionError))
    } finally {
      if (started === generation) setAssistantBusy(false)
    }
  }

  const requestProposals = async () => {
    const current = note()
    if (!current || proposalsBusy()) return
    const started = generation
    setProposalsOpen(true)
    setProposalsBusy(true)
    setMessage('')
    try {
      const values = await props.workspace.linkProposals(current.noteId)
      if (started !== generation) return
      setProposals(openLinkProposals(values, detail()?.links ?? [], current.noteId))
    } catch (proposalError) {
      if (started !== generation) return
      setProposals([])
      setMessage(workspaceErrorMessage(proposalError))
    } finally {
      if (started === generation) setProposalsBusy(false)
    }
  }

  const linkTo = async (targetNoteId: string, kind: string) => {
    const current = note()
    if (!current || linkBusy()) return
    const started = generation
    setLinkBusy(true)
    try {
      const updated = await props.workspace.linkNote(current.noteId, targetNoteId, allowedLinkKind(kind))
      if (started !== generation) return
      applyDetail(updated)
      setProposals((values) => openLinkProposals(values, updated.links, current.noteId))
      setMessage('Linked the note.')
    } catch (linkError) {
      if (started === generation) setMessage(workspaceErrorMessage(linkError))
    } finally {
      if (started === generation) setLinkBusy(false)
    }
  }

  const searchLinkTargets = async () => {
    const query = linkQuery().trim()
    if (!query) return
    const started = generation
    setLinkBusy(true)
    try {
      const values = await props.client.searchNotes({ query, limit: 10 })
      if (started !== generation) return
      setLinkResults(values.filter((value) => value.note.noteId !== note()?.noteId))
    } catch (searchError) {
      if (started === generation) setMessage(workspaceErrorMessage(searchError))
    } finally {
      if (started === generation) setLinkBusy(false)
    }
  }

  const applyNoteTag = async () => {
    const current = note()
    const name = tagDraft().trim()
    if (!current || !name || tagBusy()) return
    const started = generation
    setTagBusy(true)
    try {
      await props.client.applyNoteTag(current.noteId, name)
      const updated = await props.workspace.noteDetail(current.noteId)
      if (started !== generation) return
      applyDetail(updated)
      setTagDraft('')
    } catch (tagError) {
      // Keep the typed tag so a failed add is not lost.
      if (started === generation) setMessage(workspaceErrorMessage(tagError))
    } finally {
      if (started === generation) setTagBusy(false)
    }
  }

  const removeNoteTag = async (name: string) => {
    const current = note()
    if (!current || tagBusy()) return
    const started = generation
    setTagBusy(true)
    try {
      await props.client.removeNoteTag(current.noteId, name)
      const updated = await props.workspace.noteDetail(current.noteId)
      if (started !== generation) return
      applyDetail(updated)
    } catch (tagError) {
      if (started === generation) setMessage(workspaceErrorMessage(tagError))
    } finally {
      if (started === generation) setTagBusy(false)
    }
  }

  const captureSelection = (element: HTMLTextAreaElement) => {
    setSelection({ start: element.selectionStart, end: element.selectionEnd })
  }

  const copyMarkdown = async () => {
    const current = note()
    if (!current) return
    try {
      await navigator.clipboard.writeText(current.bodyMarkdown)
      setCopied(true)
      if (copiedTimer) clearTimeout(copiedTimer)
      copiedTimer = setTimeout(() => setCopied(false), 1500)
    } catch {
      setMessage('Could not copy to the clipboard.')
    }
  }

  const downloadMarkdown = () => {
    const current = note()
    if (!current) return
    const blob = new Blob([current.bodyMarkdown], { type: 'text/markdown;charset=utf-8' })
    const url = URL.createObjectURL(blob)
    const anchor = document.createElement('a')
    anchor.href = url
    anchor.download = noteExportFilename(noteDisplayTitle(current))
    anchor.click()
    URL.revokeObjectURL(url)
  }

  return <section class="note-reader" aria-label={`Notes in ${props.notebookTitle}`}>
    <Show when={loading() && !detail()}>
      <div class="loading-state"><span class="loader" />Loading note…</div>
    </Show>
    <Show when={error()}>
      <div class="error-banner" role="alert">{error()}
        <button class="secondary" onClick={() => void load(props.notebookId, props.noteId)}>Retry</button>
      </div>
    </Show>
    <Show when={message()}>
      <div class="notes-message" role="status" aria-live="polite">{message()}
        <button aria-label="Dismiss note message" onClick={() => setMessage('')}>×</button>
      </div>
    </Show>
    <Show when={!loading() && !error() && !detail()}>
      <p class="note-reader-empty">This notebook has no notes yet.</p>
    </Show>

    <Show when={note()}>{(current) => <>
      <header class="note-reader-header">
        <div class="note-reader-title">
          <h3>{noteDisplayTitle(current())}</h3>
          <Show when={current().readOnly}><span class="note-readonly-badge">Read-only</span></Show>
        </div>
        <div class="note-reader-meta">
          <span>#{current().noteNumber}</span>
          <span>Updated {formatTimestamp(current().updatedAt)}</span>
          <span>Created {formatTimestamp(current().createdAt)}</span>
        </div>
        <div class="note-reader-pager">
          <button class="secondary" aria-label="Previous note" disabled={!canPrevious()} onClick={() => void step(-1)}>‹</button>
          <span class="note-reader-position">{position() ?? ''}</span>
          <button class="secondary" aria-label="Next note" disabled={!canNext()} onClick={() => void step(1)}>›</button>
          <Show when={!editing()}>
            <button disabled={current().readOnly || props.notebookReadOnly} onClick={startEditing}>Edit</button>
          </Show>
          <button class="secondary" aria-pressed={current().readOnly} onClick={() => void toggleReadOnly()}>
            {current().readOnly ? 'Unlock' : 'Lock'}
          </button>
          <button class="secondary" aria-label="Copy markdown" onClick={() => void copyMarkdown()}>
            {copied() ? '✓ Copied' : 'Copy'}
          </button>
          <button class="secondary" aria-label="Download markdown" onClick={downloadMarkdown}>Download</button>
          <Show when={props.onAskAgent}>
            <button class="secondary" aria-label="Ask the note agent about this note" onClick={() =>
              props.onAskAgent?.({
                noteId: current().noteId,
                title: noteDisplayTitle(current()),
                bodyMarkdown: current().bodyMarkdown,
              })}>Ask Agent</button>
          </Show>
        </div>
      </header>

      <Show when={editing()} fallback={
        <article class="note-reader-body"><MarkdownBody markdown={current().bodyMarkdown} /></article>
      }>
        <div class="note-editor">
          <label>
            <span class="sr-only">Note body markdown</span>
            <textarea
              ref={editorField}
              class="note-body-editor"
              aria-label="Note body markdown"
              rows={16}
              value={draft()}
              disabled={saving()}
              onInput={(event) => { setDraft(event.currentTarget.value); captureSelection(event.currentTarget) }}
              onSelect={(event) => captureSelection(event.currentTarget)}
              onKeyUp={(event) => captureSelection(event.currentTarget)}
              onMouseUp={(event) => captureSelection(event.currentTarget)}
            />
          </label>
          <Show when={editError()}><p class="note-inline-error" role="alert">{editError()}</p></Show>
          <div class="note-editor-actions">
            <Show when={armedSelection()}>{(range) =>
              <span class="note-selection-badge">Selection {range().end - range().start} chars
                <button aria-label="Clear armed selection" onClick={() => {
                  setSelection(undefined)
                  editorField?.setSelectionRange(range().start, range().start)
                }}>×</button>
              </span>}
            </Show>
            <button class="secondary" disabled={saving()} onClick={cancelEditing}>Cancel</button>
            <button disabled={saving()} onClick={() => void saveBody(draft(), true)}>{saving() ? 'Saving…' : 'Save'}</button>
          </div>

          <section class="note-assistant" aria-label="Assistant">
            <div class="note-assistant-mode" role="tablist" aria-label="Assistant mode">
              <button role="tab" aria-selected={assistantMode() === 'rewrite'} classList={{ active: assistantMode() === 'rewrite' }} onClick={() => setAssistantMode('rewrite')}>Ask for changes</button>
              <button role="tab" aria-selected={assistantMode() === 'question'} classList={{ active: assistantMode() === 'question' }} onClick={() => setAssistantMode('question')}>Ask about selection</button>
            </div>
            <label>
              <span class="sr-only">{assistantMode() === 'question' ? 'Question about the selection' : 'Rewrite instruction'}</span>
              <input
                aria-label={assistantMode() === 'question' ? 'Question about the selection' : 'Rewrite instruction'}
                placeholder={assistantMode() === 'question' ? 'Ask about selection' : 'Ask for changes'}
                value={instruction()}
                disabled={assistantBusy()}
                onInput={(event) => setInstruction(event.currentTarget.value)}
                onKeyDown={(event) => { if (event.key === 'Enter') void submitAssistant() }}
              />
            </label>
            <button disabled={assistantBusy() || !instruction().trim()} onClick={() => void submitAssistant()}>
              {assistantBusy() ? 'Working…' : 'Send'}
            </button>
            <Show when={assistantError()}><p class="note-inline-error" role="alert">{assistantError()}</p></Show>
            <Show when={rewriteDraft()}>{(pending) =>
              <div class="note-rewrite-draft">
                <Show when={pending().summary}><p class="note-rewrite-summary">{pending().summary}</p></Show>
                <MarkdownBody markdown={pending().rewrittenMarkdown} />
                <div class="note-editor-actions">
                  <button class="secondary" onClick={() => setRewriteDraft(undefined)}>Discard</button>
                  <button disabled={saving()} onClick={() => void applyRewriteDraft()}>Apply</button>
                </div>
              </div>}
            </Show>
            <Show when={answerMarkdown()}>
              <div class="note-answer">
                <span class="eyebrow">ANSWER · SAVED AS COMMENT</span>
                <MarkdownBody markdown={answerMarkdown()} />
              </div>
            </Show>
          </section>
        </div>
      </Show>

      <section class="note-meta-section" aria-label="Note tags">
        <h3>Tags ({tagNames().length})</h3>
        <div class="detail-chips">
          <For each={tagNames()}>{(name) =>
            <span class="folder-chip">{name}
              <button aria-label={`Remove tag ${name}`} disabled={tagBusy()} onClick={() => void removeNoteTag(name)}>×</button>
            </span>}
          </For>
        </div>
        <div class="note-inline-form">
          <label><span class="sr-only">Note tag</span>
            <input aria-label="Note tag" placeholder="Tag" value={tagDraft()} disabled={tagBusy()}
              onInput={(event) => setTagDraft(event.currentTarget.value)}
              onKeyDown={(event) => { if (event.key === 'Enter') void applyNoteTag() }} />
          </label>
          <button class="secondary" disabled={tagBusy() || !tagDraft().trim()} onClick={() => void applyNoteTag()}>Add tag</button>
        </div>
      </section>

      <section class="note-meta-section" aria-label="Note links">
        <h3>Links ({detail()?.links.length ?? 0})</h3>
        <Show when={(detail()?.links.length ?? 0) === 0}><p class="note-meta-empty">No links.</p></Show>
        <ul class="note-link-list">
          <For each={detail()?.links ?? []}>{(link) => {
            const targetId = counterpartNoteId(link, current().noteId)
            const target = () => detail()?.linkedNotes[targetId]
            return <li>
              <button onClick={() => openNote(targetId, target()?.notebookId)}>
                {linkLabel(link, current().noteId, detail()?.linkedNotes ?? {})}
              </button>
              <span class="sr-only">{linkStableId(link)}</span>
            </li>
          }}</For>
        </ul>
        <div class="note-inline-form">
          <button class="secondary" disabled={linkBusy()} onClick={() => setLinkSearchOpen(!linkSearchOpen())}>
            {linkSearchOpen() ? 'Hide link search' : 'Add link'}
          </button>
          <button class="secondary" disabled={proposalsBusy()} onClick={() => void requestProposals()}>
            {proposalsBusy() ? 'Proposing…' : 'Propose links'}
          </button>
        </div>
        <Show when={linkSearchOpen()}>
          <div class="note-link-search">
            <div class="note-inline-form">
              <label><span class="sr-only">Search notes to link</span>
                <input aria-label="Search notes to link" placeholder="Search full note text" value={linkQuery()}
                  onInput={(event) => setLinkQuery(event.currentTarget.value)}
                  onKeyDown={(event) => { if (event.key === 'Enter') void searchLinkTargets() }} />
              </label>
              <label><span class="sr-only">Link kind</span>
                <select aria-label="Link kind" value={linkKind()} onChange={(event) => setLinkKind(event.currentTarget.value)}>
                  <option value="related">related</option>
                  <option value="source-citation">source-citation</option>
                </select>
              </label>
              <button class="secondary" disabled={linkBusy() || !linkQuery().trim()} onClick={() => void searchLinkTargets()}>Search</button>
            </div>
            <ul class="note-link-results">
              <For each={linkResults()}>{(result) =>
                <li>
                  <div>
                    <strong>{noteDisplayTitle(result.note)}</strong>
                    <Show when={result.snippet.trim()}><span class="note-search-snippet">{result.snippet}</span></Show>
                  </div>
                  <button disabled={linkBusy()} onClick={() => void linkTo(result.note.noteId, linkKind())}>Link</button>
                </li>}
              </For>
            </ul>
          </div>
        </Show>
        <Show when={proposalsOpen()}>
          <div class="note-proposals">
            <Show when={!proposalsBusy() && proposals().length === 0}>
              <p class="note-meta-empty">No new link proposals.</p>
            </Show>
            <For each={proposals()}>{(proposal) =>
              <div class="note-proposal">
                <div>
                  <strong>{noteDisplayTitle(proposal.targetNote)}</strong>
                  <span class="note-proposal-reason">{allowedLinkKind(proposal.linkKind)} · {proposal.reason}</span>
                </div>
                <button disabled={linkBusy()} onClick={() => void linkTo(proposal.targetNote.noteId, proposal.linkKind)}>Accept</button>
              </div>}
            </For>
          </div>
        </Show>
      </section>

      <section class="note-meta-section" aria-label="Note comments">
        <h3>Comments ({detail()?.comments.length ?? 0})</h3>
        <Show when={(detail()?.comments.length ?? 0) === 0}><p class="note-meta-empty">No comments.</p></Show>
        <For each={detail()?.comments ?? []}>{(comment) =>
          <article class="note-comment">
            <header>
              <strong>{comment.author ?? 'anonymous'}</strong>
              <span>{formatTimestamp(comment.createdAt)}</span>
              <button class="secondary" aria-label="Create notebook from this comment" onClick={() => void promoteComment(comment.commentId)}>Promote</button>
            </header>
            <MarkdownBody markdown={comment.bodyMarkdown} />
          </article>}
        </For>
        <Show when={commentError()}><p class="note-inline-error" role="alert">{commentError()}</p></Show>
        <label><span class="sr-only">New comment markdown</span>
          <textarea aria-label="New comment markdown" rows={3} value={commentDraft()} disabled={commentBusy()}
            onInput={(event) => setCommentDraft(event.currentTarget.value)} />
        </label>
        <button class="secondary" disabled={commentBusy() || !commentDraft().trim()} onClick={() => void addComment()}>
          {commentBusy() ? 'Adding…' : 'Add comment'}
        </button>
      </section>

      <section class="note-meta-section" aria-label="Note files">
        <h3>Files ({attachments().length})</h3>
        <Show when={attachments().length === 0}><p class="note-meta-empty">No files.</p></Show>
        <Show when={attachments().some(isImageAttachment)}>
          <div class="note-image-zoom" role="group" aria-label="Image zoom">
            <button class="secondary" aria-label="Zoom out"
              disabled={imageZoom() <= imageZoomLevels.min}
              onClick={() => setImageZoom((value) => clampImageZoom(value - imageZoomLevels.step))}>−</button>
            <span class="note-image-zoom-level">{Math.round(imageZoom() * 100)}%</span>
            <button class="secondary" aria-label="Zoom in"
              disabled={imageZoom() >= imageZoomLevels.max}
              onClick={() => setImageZoom((value) => clampImageZoom(value + imageZoomLevels.step))}>+</button>
            <button class="secondary" aria-label="Actual size" onClick={() => setImageZoom(1)}>100%</button>
          </div>
        </Show>
        <div class="note-files">
          <For each={attachments()}>{(file) =>
            <Show
              when={isImageAttachment(file)}
              fallback={<a class="note-file-link" href={noteFileURL(file.fileId)} download={attachmentLabel(file)}>
                {attachmentLabel(file)} ({formatBytes(file.byteSize)})
              </a>}
            >
              <figure class="note-file-image">
                <img
                  src={noteFileURL(file.fileId)}
                  alt={attachmentLabel(file)}
                  loading="lazy"
                  style={{ width: `${imageZoom() * 100}%` }}
                />
                <figcaption>{attachmentLabel(file)}</figcaption>
              </figure>
            </Show>}
          </For>
        </div>
      </section>
    </>}</Show>
  </section>
}

function formatBytes(value: number): string {
  if (value < 1024) return `${value} B`
  if (value < 1024 * 1024) return `${Math.round(value / 1024)} KB`
  return `${(value / (1024 * 1024)).toFixed(1)} MB`
}

function formatTimestamp(value: string): string {
  const date = new Date(value)
  return Number.isNaN(date.getTime())
    ? value
    : new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(date)
}
