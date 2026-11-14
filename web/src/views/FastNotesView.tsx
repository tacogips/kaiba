import { For, Show, createMemo, createResource, createSignal, onCleanup, type JSX } from 'solid-js'
import { useApp, errorMessage } from '../state/appStore'
import { MarkdownBody } from '../components/Markdown'
import { NoteEditor } from '../components/NoteEditor'
import { PageTagsEditor } from '../components/PageTagsEditor'
import { WorkspaceIcon } from '../components/WorkspaceIcon'
import { noteDisplayTitle } from '../notes/noteText'
import { notebookPreview } from '../notes/notebookList'
import { formatTimestamp } from '../notes/format'
import type { Note } from '../notes/types'
import './fast-notes.css'

const pageSize = 50

export function FastNotesView(): JSX.Element {
  const app = useApp()
  const route = () => app.state.route.kind === 'fast' ? app.state.route : undefined
  const query = () => route()?.query ?? ''
  const layout = () => route()?.layout ?? 'list'
  const selected = () => route()?.noteId
  const note = () => app.state.note?.noteId === selected() ? app.state.note : undefined
  const [extra, setExtra] = createSignal<Note[]>([])
  const [hasMore, setHasMore] = createSignal(false)
  const [moreBusy, setMoreBusy] = createSignal(false)
  const [moreError, setMoreError] = createSignal('')
  const draft = app.writingDrafts.get('fast-note-capture')
  let requestGeneration = 0
  let searchTimer: ReturnType<typeof setTimeout> | undefined
  onCleanup(() => clearTimeout(searchTimer))
  const [first, { refetch }] = createResource(
    () => app.state.auth === 'authenticated' ? { query: query(), revision: app.state.catalogRevision } : undefined,
    async ({ query }) => {
      const generation = ++requestGeneration
      setExtra([]); setMoreError(''); setMoreBusy(false)
      const result = await app.client.fastNotes(query, 0, pageSize)
      if (generation === requestGeneration) setHasMore(result.length === pageSize)
      return result
    },
  )
  const notes = createMemo(() => first.error ? [] : [...(first() ?? []), ...extra()])
  const loadMore = async () => {
    if (moreBusy() || first.loading || !hasMore()) return
    const generation = requestGeneration
    setMoreBusy(true); setMoreError('')
    try {
      const result = await app.client.fastNotes(query(), notes().length, pageSize)
      if (generation !== requestGeneration) return
      setExtra((previous) => [...previous, ...result.filter((row) => !notes().some((old) => old.noteId === row.noteId))])
      setHasMore(result.length === pageSize)
    } catch (error) { if (generation === requestGeneration) setMoreError(errorMessage(error)) }
    finally { if (generation === requestGeneration) setMoreBusy(false) }
  }
  const capture = async (event: Event) => {
    event.preventDefault()
    if (draft.busy() || !draft.text().trim()) return
    const source = draft.text()
    draft.setBusy(true); draft.setError('')
    try {
      const result = await app.client.captureNote(source)
      draft.setText('')
      await app.refreshCatalog()
      if (app.state.route.kind === 'fast') app.openFastNote(result.noteId)
    } catch (error) { draft.setError(`Could not save: ${errorMessage(error)}`) }
    finally { draft.setBusy(false) }
  }
  const changeQuery = (value: string) => {
    clearTimeout(searchTimer)
    searchTimer = setTimeout(() => app.openFastNotes(value, layout()), 250)
  }
  return <main class="reader fast-notes-view" id="main-content" tabindex="-1">
    <Show when={selected()} fallback={<>
      <header class="fast-notes-head">
        <div><span class="eyebrow">FAST NOTE</span><h1>Notes</h1><p>Newest created first</p></div>
        <div class="fast-layout" role="group" aria-label="Note layout">
          <button type="button" title="List view" aria-label="List view" aria-pressed={layout() === 'list'} onClick={() => app.openFastNotes(query(), 'list')}><WorkspaceIcon name="list" /></button>
          <button type="button" title="Card view" aria-label="Card view" aria-pressed={layout() === 'cards'} onClick={() => app.openFastNotes(query(), 'cards')}><WorkspaceIcon name="cards" /></button>
        </div>
      </header>
      <div class="fast-notes-content">
        <form class="fast-capture" aria-label="Quick note" onSubmit={(event) => void capture(event)}>
          <textarea aria-label="Write a quick note" placeholder="Write a quick note…" rows={3} value={draft.text()} disabled={draft.busy()}
            onInput={(event) => draft.setText(event.currentTarget.value)} onKeyDown={(event) => {
              if ((event.metaKey || event.ctrlKey) && event.key === 'Enter') { event.preventDefault(); void capture(event) }
            }} />
          <div><span>Markdown · ⌘/Ctrl Enter to save</span><button type="submit" title="Save quick note" aria-label="Save quick note" disabled={draft.busy() || !draft.text().trim()}><WorkspaceIcon name="check" /></button></div>
          <Show when={draft.error()}><p role="alert">{draft.error()}</p></Show>
        </form>
        <label class="fast-search"><WorkspaceIcon name="search" /><span class="sr-only">Search fast notes</span>
          <input type="search" aria-label="Search fast notes" placeholder="Search notes…" value={query()} onInput={(event) => changeQuery(event.currentTarget.value)} />
        </label>
        <Show when={first.loading}><p role="status" class="fast-feed-message">Loading notes…</p></Show>
        <Show when={first.error}><p role="alert" class="fast-feed-message">Could not load notes: {errorMessage(first.error)} <button type="button" onClick={() => void refetch()}>Retry</button></p></Show>
        <Show when={!first.error && !first.loading && notes().length === 0}><p class="fast-feed-message">{query() ? 'No notes match your search.' : 'No notes yet. Write your first quick note above.'}</p></Show>
        <div class="fast-feed" classList={{ 'fast-feed-cards': layout() === 'cards' }} aria-label={layout() === 'cards' ? 'Notes as cards' : 'Notes as list'}>
          <For each={notes()}>{(row) => <button type="button" class="fast-note-card" onClick={() => app.openFastNote(row.noteId)}>
            <div class="fast-note-meta"><time datetime={row.createdAt}>{formatTimestamp(row.createdAt)}</time><span>{app.state.notebooks.find((book) => book.notebookId === row.notebookId)?.title ?? 'Note'}</span></div>
            <h2>{noteDisplayTitle(row)}</h2><p>{notebookPreview(row.bodyMarkdown, layout() === 'cards' ? 240 : 160)}</p>
            <Show when={row.tags?.some((entry) => !entry.tag.isSystem)}><div class="fast-note-tags"><For each={row.tags?.filter((entry) => !entry.tag.isSystem).slice(0, 4)}>{(entry) => <span>{entry.tag.name}</span>}</For></div></Show>
          </button>}</For>
        </div>
        <Show when={moreError()}><p role="alert">{moreError()}</p></Show>
        <Show when={hasMore() && !first.error}><button type="button" class="fast-load-more" disabled={moreBusy() || first.loading} onClick={() => void loadMore()}>{moreBusy() ? 'Loading…' : 'Load more notes'}</button></Show>
      </div>
    </>}>
      <header class="fast-note-head">
        <button type="button" class="workspace-icon" aria-label="Back to notes" title="Back to notes" onClick={() => app.openFastNotes()}><WorkspaceIcon name="list" /></button>
        <div><span class="eyebrow">FAST NOTE</span><h1>{note() ? noteDisplayTitle(note()!) : 'Note'}</h1></div>
      </header>
      <Show when={app.state.noteLoading}><p role="status" class="fast-feed-message">Loading note…</p></Show>
      <Show when={!app.state.noteLoading && !note()}><p role="alert" class="fast-feed-message">Could not load this note. <button type="button" onClick={() => void app.refreshNote()}>Retry</button></p></Show>
      <Show when={note()} keyed>{(current) => <article class="fast-note-body">
        <div class="fast-note-meta"><time datetime={current.createdAt}>{formatTimestamp(current.createdAt)}</time><span>{app.notebook()?.title}</span></div>
        <PageTagsEditor />
        <MarkdownBody markdown={current.bodyMarkdown} />
        <NoteEditor note={current} />
      </article>}</Show>
    </Show>
  </main>
}
