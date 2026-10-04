import { For, Show, createEffect, createSignal, type JSX } from 'solid-js'
import { noteDisplayTitle } from '../notes/noteText'
import type { EngineNoteHit } from '../notes/types'
import type { NoteId } from '../notes/ids'
import { useApp, type AppStore } from '../state/appStore'

export function RelatedNotesSection(props: { app?: AppStore } = {}): JSX.Element {
  const app = props.app ?? useApp()
  const [hits, setHits] = createSignal<EngineNoteHit[]>([])
  const [loading, setLoading] = createSignal(false)
  const [error, setError] = createSignal(false)
  let generation = 0

  createEffect(() => {
    const enabled = app.state.searchEngineEnabled
    const noteId = app.state.noteId
    if (app.state.notebookId) void app.state.notebookRevisions[app.state.notebookId]
    if (!enabled || !noteId) {
      generation += 1
      setHits([])
      setLoading(false)
      setError(false)
      return
    }
    void load(noteId)
  })

  const load = async (noteId: NoteId) => {
    const current = ++generation
    setLoading(true)
    setError(false)
    try {
      const related = await app.client.relatedNotes(noteId, 8)
      if (current !== generation) return
      setHits(related)
    } catch {
      if (current !== generation) return
      setHits([])
      setError(true)
    } finally {
      if (current === generation) setLoading(false)
    }
  }

  return (
    <Show when={app.state.searchEngineEnabled && app.state.noteId}>
      <section class="link-group" aria-label="Related notes">
        <h3>Related notes</h3>
        <Show when={loading()}><div class="loading-state"><span class="loader" />Loading related notes…</div></Show>
        <Show when={error()}><p class="pane-empty">Related notes unavailable</p></Show>
        <Show when={!loading() && !error() && hits().length === 0}>
          <p class="pane-empty">No related notes</p>
        </Show>
        <Show when={!loading() && !error() && hits().length > 0}>
          <ul class="link-list">
            <For each={hits()}>{(hit) =>
              <li>
                <button type="button" onClick={() => app.openNote(hit.note.noteId, hit.note.notebookId)}>
                  <strong>{noteDisplayTitle(hit.note)}</strong>
                </button>
              </li>}
            </For>
          </ul>
        </Show>
      </section>
    </Show>
  )
}
