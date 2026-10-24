import { For, Show, createEffect, createSignal, type JSX } from 'solid-js'
import { errorMessage, useApp } from '../state/appStore'
import type { NoteGraphNeighbor, NoteLink } from '../notes/types'
import { NoteDestinationLink } from './NoteDestinationLink'
import { connectionGroup, savedLinkDescription, suggestedConnectionDescription } from '../notes/linkDescriptions'
import type { NoteId } from '../notes/ids'

// Links tab: the open note's linked documents, grouped by link kind. The graph
// query is bounded to one hop so the list is the note's own links rather than a
// traversal of the whole store.

export function LinkedDocsTab(): JSX.Element {
  const app = useApp()
  const [groups, setGroups] = createSignal<Array<{ kind: string; neighbors: NoteGraphNeighbor[] }>>([])
  const [links, setLinks] = createSignal<NoteLink[]>([])
  const [loading, setLoading] = createSignal(false)
  const [error, setError] = createSignal('')
  let generation = 0

  createEffect(() => {
    const noteId = app.state.noteId
    // Re-read whenever the note's own notebook reports a change, so a link added
    // elsewhere shows up without a manual refresh.
    if (app.state.notebookId) void app.state.notebookRevisions[app.state.notebookId]
    if (!noteId) {
      generation += 1
      setGroups([]); setLinks([])
      return
    }
    void load(noteId)
  })

  const load = async (noteId: NoteId) => {
    const current = ++generation
    setLoading(true)
    setGroups([]); setLinks([])
    setError('')
    try {
      const [neighbors, savedLinks] = await Promise.all([app.client.noteGraphNeighbors(noteId), app.client.noteLinks(noteId)])
      if (current !== generation) return
      setLinks(savedLinks)
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
          <p class="pane-empty">No saved links or suggested connections.</p>
        </Show>
        <For each={groups()}>{(group) =>
          <section class="link-group">
            <h3>{connectionGroup(group.kind).title}</h3>
            <p class="connection-explanation">{connectionGroup(group.kind).explanation}</p>
            <ul class="link-list">
              <For each={group.neighbors}>{(neighbor) =>
                <li>
                  <NoteDestinationLink note={neighbor.note} relationship={group.kind === 'explicit-link'
                    ? savedLinkDescription(neighbor, links()) : suggestedConnectionDescription(neighbor, app.state.note)} />
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
