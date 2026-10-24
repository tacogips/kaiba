import { For, Show, createEffect, createSignal, onCleanup, type JSX } from 'solid-js'
import { errorMessage, useApp } from '../state/appStore'
import type { Note, NoteLink } from '../notes/types'
import { NoteDestinationLink } from './NoteDestinationLink'
import type { NoteId } from '../notes/ids'

interface BacklinkSource { noteId: NoteId; links: NoteLink[] }
interface BacklinkEntry extends BacklinkSource { note: Note }
const pageSize = 50
const readConcurrency = 8

/** Only explicit incoming edges: outgoing links and inferred similarity have
 * their own meanings and must not appear as backlinks. */
export function LinkedDocsTab(): JSX.Element {
  const app = useApp()
  const [sources, setSources] = createSignal<BacklinkSource[]>([])
  const [entries, setEntries] = createSignal<BacklinkEntry[]>([])
  const [cursor, setCursor] = createSignal(0)
  const [loading, setLoading] = createSignal(false)
  const [error, setError] = createSignal('')
  let generation = 0
  onCleanup(() => { generation += 1 })

  const readPage = async (all: BacklinkSource[], offset: number, current: number) => {
    const page = all.slice(offset, offset + pageSize)
    const loaded: BacklinkEntry[] = []
    let failed = false
    for (let index = 0; index < page.length; index += readConcurrency) {
      const batch = page.slice(index, index + readConcurrency)
      const results = await Promise.allSettled(batch.map((source) => app.client.note(source.noteId)))
      if (current !== generation) return
      results.forEach((result, position) => {
        if (result.status === 'fulfilled') loaded.push({ ...batch[position]!, note: result.value })
        else failed = true
      })
    }
    if (current !== generation) return
    setEntries((previous) => [...previous, ...loaded])
    setCursor(offset + page.length)
    if (failed) setError('Some referring notes could not be loaded. Retry to refresh the list.')
  }
  const load = async (noteId: NoteId) => {
    const current = ++generation
    setLoading(true); setError(''); setEntries([]); setSources([]); setCursor(0)
    try {
      const links = await app.client.noteLinks(noteId)
      if (current !== generation) return
      const grouped = new Map<NoteId, NoteLink[]>()
      for (const link of links) {
        if (link.toNoteId !== noteId || link.fromNoteId === noteId) continue
        grouped.set(link.fromNoteId, [...(grouped.get(link.fromNoteId) ?? []), link])
      }
      const all = [...grouped].map(([noteId, links]) => ({ noteId, links }))
      all.sort((left, right) => latestDate(right.links).localeCompare(latestDate(left.links)) || left.noteId.localeCompare(right.noteId))
      setSources(all)
      await readPage(all, 0, current)
    } catch (failure) { if (current === generation) setError(errorMessage(failure)) }
    finally { if (current === generation) setLoading(false) }
  }
  createEffect(() => {
    const noteId = app.state.noteId
    void app.state.catalogRevision
    if (app.state.notebookId) void app.state.notebookRevisions[app.state.notebookId]
    if (noteId) void load(noteId)
    else { generation += 1; setSources([]); setEntries([]); setCursor(0); setLoading(false); setError('') }
  })
  const more = async () => {
    if (loading()) return
    const current = generation
    setLoading(true); setError('')
    try { await readPage(sources(), cursor(), current) }
    catch (failure) { if (current === generation) setError(errorMessage(failure)) }
    finally { if (current === generation) setLoading(false) }
  }
  return <div class="pane-section" aria-label="Backlinks">
    <Show when={app.state.noteId} fallback={<p class="pane-empty">Select a note or page to see which notes link to it.</p>}>
      <p class="connection-explanation">Notes that link to this note. Open a source or preview it without leaving this page.</p>
      <Show when={sources().length > 0}><p class="pane-note">{sources().length} referring {sources().length === 1 ? 'note' : 'notes'}</p></Show>
      <Show when={error()}><p class="note-inline-error" role="alert">{error()} <button type="button" class="secondary" onClick={() => void load(app.state.noteId!)}>Retry</button></p></Show>
      <Show when={!loading() && !error() && sources().length === 0}><p class="pane-empty">No notes link to this note yet.</p></Show>
      <ul class="link-list"><For each={entries()}>{(entry) => <li>
        <NoteDestinationLink note={entry.note} relationship={entry.links.map((link) =>
          `Links to this note · ${link.linkKind.replace(/[-_]+/g, ' ')} · ${link.provenance === 'human' ? 'Added manually' : `Added by ${link.provenance}`}`).join('; ')} />
      </li>}</For></ul>
      <Show when={loading()}><p class="loading-state" role="status">Loading backlinks…</p></Show>
      <Show when={cursor() < sources().length}><button type="button" class="secondary" disabled={loading()} onClick={() => void more()}>Load more backlinks</button></Show>
    </Show>
  </div>
}

function latestDate(links: NoteLink[]): string { return links.reduce((date, link) => link.createdAt > date ? link.createdAt : date, '') }
