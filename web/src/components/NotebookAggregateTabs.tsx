import { noteId as asNoteId } from '../notes/ids'
import type { NoteId, TagClassId, TagId } from '../notes/ids'
import { For, Show, createEffect, createMemo, createSignal, type JSX } from 'solid-js'
import { errorMessage, useApp } from '../state/appStore'
import type { NoteGraphNeighbor, NoteTag } from '../notes/types'
import { noteDisplayTitle } from '../notes/noteText'

// Right-pane content while no note is selected: notebook-wide aggregates.
// Tags: every tag across the notebook's notes (deduped) plus the notebook's
// own tags. Links: one-hop links of every note, grouped by source note.

export function NotebookTagsTab(): JSX.Element {
  const app = useApp()

  const aggregated = createMemo(() => {
    const notebook = app.notebook()
    const counts = new Map<TagId, { tag: NoteTag; noteCount: number }>()
    for (const assignment of notebook?.tags ?? []) {
      counts.set(assignment.tag.tagId, { tag: assignment.tag, noteCount: 0 })
    }
    for (const note of app.notes()) {
      for (const assignment of note.tags ?? []) {
        const existing = counts.get(assignment.tag.tagId)
        if (existing) existing.noteCount += 1
        else counts.set(assignment.tag.tagId, { tag: assignment.tag, noteCount: 1 })
      }
    }
    const byClass = new Map<TagClassId | null, Array<{ tag: NoteTag; noteCount: number }>>()
    for (const entry of counts.values()) {
      const classId = entry.tag.classId
      byClass.set(classId, [...(byClass.get(classId) ?? []), entry])
    }
    return [...byClass.entries()]
      .map(([classId, tags]) => ({
        classId,
        tags: tags.sort((left, right) => left.tag.name.localeCompare(right.tag.name)),
      }))
      .sort((left, right) => (left.classId ?? '').localeCompare(right.classId ?? ''))
  })

  return (
    <div class="pane-section">
      <Show
        when={app.state.notebookId}
        fallback={<p class="pane-empty">Open a notebook to see its tags.</p>}
      >
        <Show when={aggregated().length === 0}>
          <p class="pane-empty">No tags in this notebook.</p>
        </Show>
        <div class="info-tags">
          <For each={aggregated()}>{(group) =>
            <section class="info-tag-group">
              <h3>{group.classId ?? 'untyped'}</h3>
              <For each={group.tags}>{(entry) =>
                <div class="info-tag-class">
                  <button
                    type="button"
                    class="tag-chip-open"
                    title={`Open tag details: ${entry.tag.name}`}
                    onClick={() => app.openTagPane(entry.tag.tagId)}
                  >#{entry.tag.name}</button>
                  <Show when={entry.noteCount > 0}>
                    <span class="tree-count">{entry.noteCount}</span>
                  </Show>
                </div>}
              </For>
            </section>}
          </For>
        </div>
      </Show>
    </div>
  )
}

/** Seeds per graph request; the traversal accepts a bounded seed set and caps
 * its result limit at 20, so notebook-wide links are gathered chunk by chunk. */
const linkSeedChunkSize = 10
const maximumLinkChunks = 8

export function NotebookLinksTab(): JSX.Element {
  const app = useApp()
  const [neighbors, setNeighbors] = createSignal<NoteGraphNeighbor[]>([])
  const [loading, setLoading] = createSignal(false)
  const [truncated, setTruncated] = createSignal(false)
  const [error, setError] = createSignal('')
  let generation = 0

  const noteIds = createMemo(() => app.notes().map((note) => note.noteId).join('\n'))

  createEffect(() => {
    const notebookId = app.state.notebookId
    const ids = noteIds().split('\n').filter((id) => id.length > 0).map(asNoteId)
    if (notebookId) void app.state.notebookRevisions[notebookId]
    if (!notebookId || ids.length === 0) {
      generation += 1
      setNeighbors([])
      return
    }
    void load(ids)
  })

  const load = async (ids: NoteId[]) => {
    const requested = ++generation
    setLoading(true)
    setError('')
    try {
      const chunks: NoteId[][] = []
      for (let index = 0; index < ids.length; index += linkSeedChunkSize) {
        chunks.push(ids.slice(index, index + linkSeedChunkSize))
      }
      setTruncated(chunks.length > maximumLinkChunks)
      const results = await Promise.all(chunks.slice(0, maximumLinkChunks).map((chunk) =>
        app.client.noteGraphNeighborsMany(chunk)))
      if (requested !== generation) return
      setNeighbors(dedupeNeighbors(results.flat()))
    } catch (loadError) {
      if (requested !== generation) return
      setNeighbors([])
      setError(errorMessage(loadError))
    } finally {
      if (requested === generation) setLoading(false)
    }
  }

  const groups = createMemo(() => {
    const titles = new Map(app.notes().map((note) => [note.noteId, noteDisplayTitle(note)]))
    const bySeed = new Map<NoteId, NoteGraphNeighbor[]>()
    for (const neighbor of neighbors()) {
      bySeed.set(neighbor.seedNoteId, [...(bySeed.get(neighbor.seedNoteId) ?? []), neighbor])
    }
    return [...bySeed.entries()].map(([seedNoteId, values]) => ({
      seedNoteId,
      seedTitle: titles.get(seedNoteId) ?? seedNoteId,
      neighbors: values.sort((left, right) => right.weight - left.weight),
    }))
  })

  return (
    <div class="pane-section">
      <Show
        when={app.state.notebookId}
        fallback={<p class="pane-empty">Open a notebook to see its links.</p>}
      >
        <Show when={loading() && neighbors().length === 0}>
          <div class="loading-state"><span class="loader" />Loading links…</div>
        </Show>
        <Show when={error()}><p class="note-inline-error" role="alert">{error()}</p></Show>
        <Show when={!loading() && !error() && groups().length === 0}>
          <p class="pane-empty">No links between this notebook's notes and other documents.</p>
        </Show>
        <Show when={truncated()}>
          <p class="pane-note">Showing links for the first {linkSeedChunkSize * maximumLinkChunks} notes.</p>
        </Show>
        <For each={groups()}>{(group) =>
          <section class="link-group">
            <h3>{group.seedTitle}</h3>
            <ul class="link-list">
              <For each={group.neighbors}>{(neighbor) =>
                <li>
                  <button type="button" onClick={() => app.openNote(neighbor.note.noteId, neighbor.note.notebookId)}>
                    <strong>{noteDisplayTitle(neighbor.note)}</strong>
                    <span class="link-meta">{neighbor.edgeKind} · #{neighbor.note.noteNumber}</span>
                  </button>
                </li>}
              </For>
            </ul>
          </section>}
        </For>
      </Show>
    </div>
  )
}

function dedupeNeighbors(values: NoteGraphNeighbor[]): NoteGraphNeighbor[] {
  const seen = new Set<string>()
  const unique: NoteGraphNeighbor[] = []
  for (const neighbor of values) {
    const key = `${neighbor.seedNoteId}\u0000${neighbor.note.noteId}\u0000${neighbor.edgeKind}`
    if (seen.has(key)) continue
    seen.add(key)
    unique.push(neighbor)
  }
  return unique
}
