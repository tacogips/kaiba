import { Show, createSignal, type JSX } from 'solid-js'
import { useApp } from '../state/appStore'
import type { Notebook } from '../notes/types'
import { WorkspaceIcon } from './WorkspaceIcon'
import '../reader-controls.css'

export function NotebookTitleEditor(props: { notebook: Notebook }): JSX.Element {
  const app = useApp()
  const [editing, setEditing] = createSignal(false)
  const [draft, setDraft] = createSignal('')
  const [busy, setBusy] = createSignal(false)
  const [error, setError] = createSignal('')
  const save = async (event: Event) => {
    event.preventDefault()
    if (!draft().trim() || busy()) return
    setBusy(true)
    setError('')
    try {
      await app.client.renameNotebook(props.notebook.notebookId, draft().trim())
      await app.refreshCatalog()
      setEditing(false)
    } catch (failure) { setError(failure instanceof Error ? failure.message : 'Title could not be saved') }
    finally { setBusy(false) }
  }
  return <div class="document-title-editor">
    <h1 title={props.notebook.title}>{props.notebook.title}</h1>
    <button type="button" class="secondary reader-control" aria-label="Rename document" title="Rename document" aria-expanded={editing()} onClick={() => {
      setDraft(props.notebook.title); setError(''); setEditing(true)
    }}><WorkspaceIcon name="edit" /></button>
    <Show when={editing()}>
      <form class="reader-title-form" role="dialog" aria-label="Rename document" onSubmit={(event) => void save(event)}
        onKeyDown={(event) => { if (event.key === 'Escape' && !busy()) { event.preventDefault(); setEditing(false) } }}>
        <label><span class="sr-only">Document title</span><input aria-label="Document title" value={draft()} maxlength={1000}
          ref={(input) => queueMicrotask(() => { input.focus(); input.select() })}
          disabled={busy()} onInput={(event) => setDraft(event.currentTarget.value)} /></label>
        <button type="submit" class="secondary reader-control" aria-label={busy() ? 'Saving title' : 'Save title'} title="Save" aria-busy={busy()}
          disabled={busy() || !draft().trim()}><WorkspaceIcon name="check" /></button>
        <button type="button" class="secondary reader-control" aria-label="Cancel title edit" title="Cancel" disabled={busy()}
          onClick={() => setEditing(false)}><WorkspaceIcon name="close" /></button>
        <Show when={error()}><p role="alert">{error()}</p></Show>
      </form>
    </Show>
  </div>
}
