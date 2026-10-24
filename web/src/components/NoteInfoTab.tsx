import { For, Show, createResource, createSignal, type JSX } from 'solid-js'
import './form-controls.css'
import { formatTimestamp } from '../notes/format'
import { errorMessage, useApp } from '../state/appStore'

export function NoteInfoTab(): JSX.Element {
  const app = useApp()
  const [fileError, setFileError] = createSignal('')
  const [files] = createResource(() => app.state.notebookId, async (id) => {
    setFileError('')
    try { return await app.client.notebookFiles(id) }
    catch (failure) { setFileError(errorMessage(failure)); return [] }
  })
  return <div class="pane-section" aria-label="Document information">
    <Show when={app.notebook()}>{(notebook) => <dl class="info-grid">
      <div><dt>Document</dt><dd>{notebook().title}</dd></div>
      <div><dt>Access</dt><dd>{notebook().readOnly ? 'Read-only' : 'Editable'}</dd></div>
      <div><dt>Created</dt><dd>{formatTimestamp(notebook().createdAt)}</dd></div>
      <div><dt>Updated</dt><dd>{formatTimestamp(notebook().updatedAt)}</dd></div>
      <Show when={app.state.note}>{(note) => <div><dt>Current page</dt><dd>{note().noteNumber}</dd></div>}</Show>
    </dl>}</Show>
    <For each={files() ?? []}>{(attachment) => <dl class="info-grid" aria-label="Original file">
      <div><dt>File name</dt><dd>{attachment.file.originalFilename ?? 'Original document'}</dd></div>
      <div><dt>Format</dt><dd>{attachment.file.mediaType}</dd></div>
      <div><dt>Size</dt><dd>{attachment.file.byteSize.toLocaleString()} bytes</dd></div>
    </dl>}</For>
    <Show when={fileError()}><p role="alert">{fileError()}</p></Show>
  </div>
}
