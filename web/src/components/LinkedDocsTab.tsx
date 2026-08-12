import { For, Show, createEffect, createSignal, type JSX } from 'solid-js'
import { errorMessage, useApp } from '../state/appStore'
import type { NoteGraphNeighbor } from '../notes/types'
import { noteDisplayTitle } from '../notes/noteText'

// Links tab: the open note's linked documents, grouped by link kind. The graph
// query is bounded to one hop so the list is the note's own links rather than a
// traversal of the whole store.

export function LinkedDocsTab(): JSX.Element {
  const app = useApp()
  const [groups, setGroups] = createSignal<Array<{ kind: string; neighbors: NoteGraphNeighbor[] }>>([])
  const [loading, setLoading] = createSignal(false)
  const [error, setError] = createSignal('')
  let generation = 0

  createEffect(() => {
    const noteId = app.state.noteId
    // Re-read whenever the note's own notebook reports a change, so a link added
    // elsewhere shows up without a manual refresh.
    if (app.state.notebookId) void app.state.notebookRevisions[app.state.notebookId]
    if (!noteId) {
      setGroups([])
      return
    }
    void load(noteId)
  })

  const load = async (noteId: string) => {
    const current = ++generation
    setLoading(true)
    setError('')
    try {
      const neighbors = await app.client.noteGraphNeighbors(noteId)
      if (current !== generation) return
      setGroups(groupByKind(neighbors.filter((neighbor) => neighbor.note.noteId !== noteId)))
    } catch (loadError) {
      if (current !== generation) return
      setGroups([])
      setError(errorMessage(loadError))
    } finally {
      if (current === generation) setLoading(false)
    }
  }

  return (
    <div class="pane-section">
      <Show when={app.state.noteId} fallback={<p class="pane-empty">Open a note to see its links.</p>}>
        <Show when={loading()}><div class="loading-state"><span class="loader" />Loading links…</div></Show>
        <Show when={error()}><p class="note-inline-error" role="alert">{error()}</p></Show>
        <Show when={!loading() && !error() && groups().length === 0}>
          <p class="pane-empty">No linked documents.</p>
        </Show>
        <For each={groups()}>{(group) =>
          <section class="link-group">
            <h3>{group.kind}</h3>
            <ul class="link-list">
              <For each={group.neighbors}>{(neighbor) =>
                <li>
                  <button type="button" onClick={() => app.openNote(neighbor.note.noteId, neighbor.note.notebookId)}>
                    <strong>{noteDisplayTitle(neighbor.note)}</strong>
                    <span class="link-meta">#{neighbor.note.noteNumber} · {neighbor.hopCount} hop</span>
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

function groupByKind(neighbors: NoteGraphNeighbor[]): Array<{ kind: string; neighbors: NoteGraphNeighbor[] }> {
  const byKind = new Map<string, NoteGraphNeighbor[]>()
  for (const neighbor of neighbors) {
    const kind = neighbor.edgeKind || 'related'
    byKind.set(kind, [...(byKind.get(kind) ?? []), neighbor])
  }
  return [...byKind.entries()]
    .map(([kind, values]) => ({
      kind,
      neighbors: [...values].sort((left, right) => right.weight - left.weight),
    }))
    .sort((left, right) => left.kind.localeCompare(right.kind))
}
