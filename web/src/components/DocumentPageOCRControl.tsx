import { Show, createSignal, type JSX } from 'solid-js'
import { WorkspaceIcon } from './WorkspaceIcon'
import './form-controls.css'
import { documentPageMetadata } from '../notes/documentPages'
import { useApp } from '../state/appStore'

export function DocumentPageOCRControl(): JSX.Element {
  const app = useApp()
  const page = () => app.state.note?.noteId === app.state.noteId ? documentPageMetadata(app.state.note) : undefined
  const [busy, setBusy] = createSignal(false)
  const [error, setError] = createSignal<{ noteId: string; message: string }>()
  const recognize = async () => {
    const note = app.state.note
    if (!note || busy()) return
    setBusy(true)
    setError(undefined)
    try {
      await app.client.recognizeDocumentPage(note.noteId)
      await app.loadNotes(note.notebookId)
      await app.refreshNote()
    } catch (failure) {
      setError({ noteId: note.noteId, message: failure instanceof Error ? failure.message : 'OCR failed. Try again.' })
    } finally { setBusy(false) }
  }
  return <Show when={page()}>{(metadata) => <section class="page-ocr-control" aria-label="Page search text">
    <strong>Page {metadata().pageNumber}</strong>
    <Show when={metadata().textStatus === 'pending'} fallback={<span>Searchable</span>}>
      <p>Text on this page is not searchable yet.</p>
      <button type="button" class="secondary form-action-button" aria-label="Make page searchable" title="Make page searchable" aria-busy={busy()} disabled={busy() || app.state.note?.readOnly} onClick={() => void recognize()}>
        <WorkspaceIcon name="ai" />{busy() ? 'Recognizing…' : 'Recognize'}
      </button>
    </Show>
    <Show when={error()?.noteId === app.state.noteId}><p role="alert">{error()?.message}</p></Show>
  </section>}</Show>
}
