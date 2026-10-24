import { Show, createResource, createSignal, type JSX } from 'solid-js'
import type { NoteId } from '../notes/ids'
import { useApp } from '../state/appStore'
import { WorkspaceIcon } from './WorkspaceIcon'
import '../reader-controls.css'

export function DocumentPageTextView(props: { noteId: NoteId; onOpenAnalysis?: () => void }): JSX.Element {
  const app = useApp()
  const [error, setError] = createSignal('')
  const [page, { refetch }] = createResource(() => props.noteId, async (id) => {
    setError('')
    try { return await app.client.documentPageText(id) }
    catch (failure) { setError(failure instanceof Error ? failure.message : 'Page text could not be loaded'); return undefined }
  })
  return <section class="pdf-text-stage" aria-label="Page text">
    <Show when={page.loading}><p role="status">Loading page text…</p></Show>
    <Show when={error()}><p role="alert">{error()} <button type="button" class="secondary reader-control" aria-label="Retry text" title="Retry" onClick={() => void refetch()}><WorkspaceIcon name="refresh" /></button></p></Show>
    <Show when={!page.loading && !error() && page()}>{(value) =>
      <Show when={value().text} fallback={<p>No searchable text on this page yet.
        <button type="button" class="secondary reader-control" aria-label="Open Analysis" title="Open Analysis" onClick={props.onOpenAnalysis}><WorkspaceIcon name="ai" /></button>
      </p>}><pre>{value().text}</pre></Show>
    }</Show>
  </section>
}
