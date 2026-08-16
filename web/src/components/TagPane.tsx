import { For, Show, createEffect, createMemo, createSignal, onCleanup, untrack, type JSX } from 'solid-js'
import { formatTimestamp } from '../notes/format'
import { MarkdownBody } from './Markdown'
import { MemoTab, type MemoSubject } from './MemoTab'
import { TabPanel, Tabs, type TabDescriptor } from './Tabs'
import { errorMessage, useApp } from '../state/appStore'
import { noteDisplayTitle } from '../notes/noteText'
import { loadTagOccurrences, transitionTagOccurrences } from '../notes/tagOccurrences'
import type { Note, TagComment, TagDetail } from '../notes/types'

// The right pane's tag mode (design-docs/specs/tag-detail-pane.md): the
// cross-notebook analogue of the per-note panes for one tag. Memo binds the
// tag's memo notebook (created lazily on first submit), History aggregates
// every memo of notes/notebooks carrying the tag, and Links lists every note
// carrying the tag grouped by notebook. Occurrence clicks push the return
// stack so Back restores the reader.

type TagPaneTab = 'memo' | 'history' | 'links'

const tagCommentsPageLimit = 50

export function TagPane(props: { tagId: string }): JSX.Element {
  const app = useApp()
  const [tab, setTab] = createSignal<TagPaneTab>('memo')
  const [detail, setDetail] = createSignal<TagDetail>()
  const [memoNotebookId, setMemoNotebookId] = createSignal<string>()
  const [error, setError] = createSignal('')
  let generation = 0
  let loadedTagId = ''

  const tabs: readonly TabDescriptor<TagPaneTab>[] = [
    { value: 'memo', label: 'Memo' },
    { value: 'history', label: 'History' },
    { value: 'links', label: 'Links' },
  ]

  createEffect(() => {
    const tagId = props.tagId
    void app.state.catalogRevision
    const requested = ++generation
    // Switching tags while the pane is open must never leave the previous
    // tag's identity (or its memo notebook, which the composer would write
    // into) visible while the new detail loads. Revision-driven refreshes of
    // the same tag keep the current state to avoid flicker.
    if (tagId !== loadedTagId) {
      loadedTagId = tagId
      setDetail(undefined)
      setMemoNotebookId(undefined)
    }
    setError('')
    void app.client.tagDetail(tagId)
      .then((loaded) => {
        if (requested !== generation) return
        setDetail(loaded)
        setMemoNotebookId(loaded.memoNotebookId ?? undefined)
      })
      .catch((loadError: unknown) => {
        if (requested !== generation) return
        setDetail(undefined)
        setError(errorMessage(loadError))
      })
  })

  const memoSubject = createMemo<MemoSubject | null>(() => {
    const id = memoNotebookId()
    return id ? { kind: 'notebook', id } : null
  })

  const ensureSubject = async (): Promise<MemoSubject> => {
    const tagId = props.tagId
    const notebook = await app.client.ensureTagMemoNotebook(tagId)
    // A tag switched mid-flight keeps its own notebook out of the new tag's
    // pane; the submission that triggered the ensure still completes.
    if (tagId === props.tagId) setMemoNotebookId(notebook.notebookId)
    return { kind: 'notebook', id: notebook.notebookId }
  }

  const tagLabel = createMemo(() => detail()?.tag.name ?? '…')

  return (
    <>
      <div class="pane-head tag-pane-head">
        <button
          type="button"
          class="pane-fold"
          aria-label="Collapse the details pane"
          aria-expanded={true}
          onClick={app.toggleRightPane}
        >›</button>
        <div class="tag-pane-title">
          <span class="tag-pane-name">#{tagLabel()}</span>
          <Show when={detail()}>{(loaded) => (
            <span class="tag-pane-meta">
              <Show when={loaded().tagClass}>{(tagClass) => <em>{tagClass().label}</em>}</Show>
              {` ${loaded().noteCount} note${loaded().noteCount === 1 ? '' : 's'}`}
              {` · ${loaded().notebookCount} notebook${loaded().notebookCount === 1 ? '' : 's'}`}
            </span>
          )}</Show>
        </div>
        <button
          type="button"
          class="tag-pane-close"
          aria-label="Close tag details"
          title="Close tag details"
          onClick={app.closeTagPane}
        >×</button>
      </div>
      <div class="tag-pane-tabs">
        <Tabs label="Tag details" tabs={tabs} active={tab()} idPrefix="tag" onSelect={setTab} />
      </div>
      <div class="pane-body">
        <Show when={error()}><p class="note-inline-error" role="alert">{error()}</p></Show>
        <TabPanel idPrefix="tag" value="memo" active={tab()}>
          <MemoTab
            subject={memoSubject()}
            ensureSubject={ensureSubject}
            composerPlaceholder={`Ask about ${tagLabel()}`}
            emptyMessage="No memos about this tag yet."
          />
        </TabPanel>
        <TabPanel idPrefix="tag" value="history" active={tab()}>
          <TagHistoryTab tagId={props.tagId} />
        </TabPanel>
        <TabPanel idPrefix="tag" value="links" active={tab()}>
          <TagLinksTab tagId={props.tagId} tagName={detail()?.tag.name} />
        </TabPanel>
      </div>
    </>
  )
}

/** Every memo written on notes/notebooks carrying the tag, across all
 * notebooks, newest first, with jump-to attribution. */
function TagHistoryTab(props: { tagId: string }): JSX.Element {
  const app = useApp()
  const [comments, setComments] = createSignal<TagComment[]>([])
  const [loading, setLoading] = createSignal(false)
  const [exhausted, setExhausted] = createSignal(true)
  const [error, setError] = createSignal('')
  let generation = 0
  let loadedTagId = ''

  createEffect(() => {
    const tagId = props.tagId
    void revisionPulse(app.state.notebookRevisions, app.state.catalogRevision)
    // A revision-driven refresh of the same tag reloads the pages already on
    // screen; only a tag switch snaps back to the first page.
    const target = tagId === loadedTagId ? untrack(comments).length : 0
    loadedTagId = tagId
    void reload(tagId, target)
  })

  onCleanup(() => { generation += 1 })

  /** Replaces the list with up to `target` entries re-fetched page by page
   * (at least one page), preserving "Load older memos" progress. */
  const reload = async (tagId: string, target: number) => {
    const requested = ++generation
    const pages = Math.max(1, Math.ceil(target / tagCommentsPageLimit))
    setLoading(true)
    setError('')
    try {
      let all: TagComment[] = []
      let sawShortPage = false
      for (let page = 0; page < pages; page += 1) {
        const chunk = await app.client.tagComments(tagId, page * tagCommentsPageLimit, tagCommentsPageLimit)
        if (requested !== generation) return
        all = all.concat(chunk)
        if (chunk.length < tagCommentsPageLimit) {
          sawShortPage = true
          break
        }
      }
      setComments(all)
      setExhausted(sawShortPage)
    } catch (loadError) {
      if (requested !== generation) return
      setComments([])
      setError(errorMessage(loadError))
    } finally {
      if (requested === generation) setLoading(false)
    }
  }

  const loadOlder = async () => {
    const requested = ++generation
    const offset = comments().length
    setLoading(true)
    try {
      const page = await app.client.tagComments(props.tagId, offset, tagCommentsPageLimit)
      if (requested !== generation) return
      setComments((current) => [...current, ...page])
      setExhausted(page.length < tagCommentsPageLimit)
    } catch (loadError) {
      if (requested !== generation) return
      setError(errorMessage(loadError))
    } finally {
      if (requested === generation) setLoading(false)
    }
  }

  const attribution = (entry: TagComment): string => {
    if (entry.comment.noteId) return entry.noteTitle ?? entry.comment.noteId
    return entry.notebookTitle ?? entry.comment.notebookId ?? 'Notebook memo'
  }

  const jump = (entry: TagComment) => {
    if (entry.comment.noteId) app.openNoteWithReturn(entry.comment.noteId)
    else if (entry.comment.notebookId) app.openNotebookWithReturn(entry.comment.notebookId)
  }

  return (
    <div class="pane-section">
      <Show when={loading() && comments().length === 0}>
        <div class="loading-state"><span class="loader" />Loading memo history…</div>
      </Show>
      <Show when={error()}><p class="note-inline-error" role="alert">{error()}</p></Show>
      <Show when={!loading() && !error() && comments().length === 0}>
        <p class="pane-empty">No memos reference this tag yet.</p>
      </Show>
      <For each={comments()}>{(entry) => (
        <article class="memo">
          <header>
            <strong>{entry.comment.author}</strong>
            <span>
              <button type="button" class="memo-note-ref" onClick={() => jump(entry)}>
                {attribution(entry)}
              </button>
              {formatTimestamp(entry.comment.createdAt)}
            </span>
          </header>
          <MarkdownBody markdown={entry.comment.bodyMarkdown} anchorIds={false} />
        </article>
      )}</For>
      <Show when={!exhausted()}>
        <button
          type="button"
          class="secondary"
          disabled={loading()}
          onClick={() => void loadOlder()}
        >{loading() ? 'Loading…' : 'Load older memos'}</button>
      </Show>
    </div>
  )
}

/** Every note carrying the tag (descendants included) across all notebooks,
 * grouped by notebook. */
function TagLinksTab(props: { tagId: string; tagName?: string }): JSX.Element {
  const app = useApp()
  const [occurrences, setOccurrences] = createSignal<Note[]>([])
  const [loading, setLoading] = createSignal(false)
  const [error, setError] = createSignal('')
  let generation = 0
  let loadedTagId = ''
  let refreshTimer: ReturnType<typeof setTimeout> | undefined

  createEffect(() => {
    const tagId = props.tagId
    const tagName = props.tagName
    void revisionPulse(app.state.notebookRevisions, app.state.catalogRevision)
    const isSameTag = tagId === loadedTagId
    if (!isSameTag) {
      setOccurrences(transitionTagOccurrences(loadedTagId, tagId, untrack(occurrences)))
      loadedTagId = tagId
    }
    setError('')
    if (!tagName) {
      setOccurrences([])
      setLoading(false)
      return
    }
    if (refreshTimer !== undefined) clearTimeout(refreshTimer)
    if (!isSameTag) {
      void load(tagName, ++generation)
      return
    }
    // Revision pulses arrive in bursts (each agent turn bumps a notebook);
    // coalesce same-tag refreshes so the full occurrence walk runs once.
    refreshTimer = setTimeout(() => { void load(tagName, ++generation) }, 400)
  })

  onCleanup(() => {
    generation += 1
    if (refreshTimer !== undefined) clearTimeout(refreshTimer)
  })

  const load = async (tagName: string, requested: number) => {
    setLoading(true)
    try {
      const notes = await loadTagOccurrences(
        tagName,
        (name, offset, limit) => app.client.notesByTag(name, offset, limit),
        () => requested === generation,
      )
      if (requested !== generation) return
      setOccurrences(notes ?? [])
    } catch (loadError) {
      if (requested !== generation) return
      setOccurrences([])
      setError(errorMessage(loadError))
    } finally {
      if (requested === generation) setLoading(false)
    }
  }

  const groups = createMemo(() => {
    const titles = new Map(app.state.notebooks.map((notebook) => [notebook.notebookId, notebook.title]))
    const byNotebook = new Map<string, Note[]>()
    for (const note of occurrences()) {
      byNotebook.set(note.notebookId, [...(byNotebook.get(note.notebookId) ?? []), note])
    }
    return [...byNotebook.entries()].map(([notebookId, notes]) => ({
      notebookId,
      title: titles.get(notebookId) ?? notebookId,
      notes,
    }))
  })

  return (
    <div class="pane-section">
      <Show when={loading() && occurrences().length === 0}>
        <div class="loading-state"><span class="loader" />Loading tagged notes…</div>
      </Show>
      <Show when={error()}><p class="note-inline-error" role="alert">{error()}</p></Show>
      <Show when={!loading() && !error() && groups().length === 0}>
        <p class="pane-empty">No notes carry this tag yet.</p>
      </Show>
      <For each={groups()}>{(group) => (
        <section class="link-group">
          <h3>{group.title}</h3>
          <ul class="link-list">
            <For each={group.notes}>{(note) => (
              <li>
                <button type="button" onClick={() => app.openNoteWithReturn(note.noteId, note.notebookId)}>
                  <strong>{noteDisplayTitle(note)}</strong>
                  <span class="link-meta">p.{note.noteNumber}</span>
                </button>
              </li>
            )}</For>
          </ul>
        </section>
      )}</For>
    </div>
  )
}

/** Reads every notebook revision plus the catalog revision so a tracking
 * effect re-runs on any store change the events feed reports — the tag panes
 * aggregate across all notebooks, so no single revision key covers them. */
function revisionPulse(revisions: Record<string, number>, catalogRevision: number): number {
  let total = catalogRevision
  for (const key of Object.keys(revisions)) total += revisions[key] ?? 0
  return total
}
