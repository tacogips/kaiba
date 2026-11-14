import { Show, createResource, createSignal, onCleanup, type JSX } from 'solid-js'
import type { NoteId } from '../notes/ids'
import { useApp } from '../state/appStore'
import { PageOCRAction } from './PageOCRAction'
import { WorkspaceIcon } from './WorkspaceIcon'
import '../reader-controls.css'

export function DocumentPageTextView(props: { noteId: NoteId; onOpenAnalysis?: () => void }): JSX.Element {
  const app = useApp()
  const [error, setError] = createSignal('')
  let generation = 0
  onCleanup(() => { generation += 1 })
  const [page, { refetch }] = createResource(() => ({ id: props.noteId,
    taskRevision: app.ocrTasks.revision(props.noteId),
    notebookRevision: app.state.notebookId ? app.state.notebookRevisions[app.state.notebookId] : 0,
  }), async ({ id }) => {
    const current = ++generation
    setError('')
    try { return await app.client.documentPageText(id) }
    catch (failure) { if (current === generation) setError(failure instanceof Error ? failure.message : 'Page text could not be loaded'); return undefined }
  })
  return <section class="pdf-text-stage" aria-label="Page text">
    <Show when={page.loading}><p role="status">Loading page text…</p></Show>
    <Show when={error()}><p role="alert">{error()} <button type="button" class="secondary reader-control" aria-label="Retry text" title="Retry" onClick={() => void refetch()}><WorkspaceIcon name="refresh" /></button></p></Show>
    <Show when={!page.loading && !error() && page()}>{(value) =>
      <><Show when={value().text} fallback={<div class="document-page-text-empty">
        <p>{value().textStatus === 'complete' ? 'No text was detected on this page.' : 'No searchable text on this page yet.'}</p>
        <Show when={props.onOpenAnalysis}><button type="button" class="secondary reader-control" aria-label="Open Analysis" title="Open Analysis" onClick={props.onOpenAnalysis}><WorkspaceIcon name="settings" /></button></Show>
      </div>}><pre>{value().text}</pre></Show>
      <PageOCRAction noteId={props.noteId} pageNumber={value().pageNumber} complete={value().textStatus === 'complete'} /></>
    }</Show>
  </section>
}
