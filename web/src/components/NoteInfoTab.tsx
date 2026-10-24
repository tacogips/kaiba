import { For, Show, createEffect, createResource, createSignal, on, type JSX } from 'solid-js'
import './form-controls.css'
import { WorkspaceIcon } from './WorkspaceIcon'
import { formatTimestamp } from '../notes/format'
import { errorMessage, useApp } from '../state/appStore'

export function NoteInfoTab(): JSX.Element {
  const app = useApp()
  const [reindexBusy, setReindexBusy] = createSignal(false)
  const [reindexMessage, setReindexMessage] = createSignal('')
  const [reindexError, setReindexError] = createSignal('')
  const [fileError, setFileError] = createSignal('')
  const [files] = createResource(() => app.state.notebookId, async (id) => {
    setFileError('')
    try { return await app.client.notebookFiles(id) }
    catch (failure) { setFileError(errorMessage(failure)); return [] }
  })
  createEffect(on(() => app.state.notebookId, () => { setReindexMessage(''); setReindexError(''); setFileError('') }))
  const reindex = async () => {
    const id = app.state.notebookId
    if (!id || reindexBusy()) return
    setReindexBusy(true); setReindexMessage(''); setReindexError('')
    try {
      const result = await app.client.rebuildNotebookSearchIndex(id)
      if (app.state.notebookId === id) setReindexMessage(result.diagnostics.join(' ') || 'Search index rebuild queued.')
    } catch (error) { if (app.state.notebookId === id) setReindexError(errorMessage(error)) }
    finally { setReindexBusy(false) }
  }
  return <div class="pane-section" aria-label="Document information">
    <Show when={app.notebook()}>{(notebook) => <dl class="info-grid">
      <div><dt>Document</dt><dd>{notebook().title}</dd></div>
      <div><dt>Access</dt><dd>{notebook().readOnly ? 'Read-only' : 'Editable'}</dd></div>
      <div><dt>Created</dt><dd>{formatTimestamp(notebook().createdAt)}</dd></div>
      <div><dt>Updated</dt><dd>{formatTimestamp(notebook().updatedAt)}</dd></div>
      <Show when={app.state.note}>{(note) => <div><dt>Current page</dt><dd>{note().noteNumber}</dd></div>}</Show>
    </dl>}</Show>
    <Show when={app.state.notebookId}>
      <section class="notebook-search-reindex" aria-label="Search index">
        <button type="button" class="secondary form-action-button" title="Rebuild search for this notebook and its AI conversations" disabled={reindexBusy()} onClick={() => void reindex()}>
          <WorkspaceIcon name="refresh" />{reindexBusy() ? 'Rebuilding…' : 'Rebuild search index'}
        </button>
        <p class="connection-explanation">Includes this notebook’s pages and AI conversations.</p>
        <Show when={reindexMessage()}><p role="status">{reindexMessage()}</p></Show>
        <Show when={reindexError()}><p role="alert">{reindexError()}</p></Show>
      </section>
    </Show>
    <For each={app.state.notebookId ? files() ?? [] : []}>{(attachment) => <dl class="info-grid" aria-label="Original file">
      <div><dt>File name</dt><dd>{attachment.file.originalFilename ?? 'Original document'}</dd></div>
      <div><dt>Format</dt><dd>{attachment.file.mediaType}</dd></div>
      <div><dt>Size</dt><dd>{attachment.file.byteSize.toLocaleString()} bytes</dd></div>
    </dl>}</For>
    <Show when={app.state.notebookId && fileError()}><p role="alert">{fileError()}</p></Show>
  </div>
}
