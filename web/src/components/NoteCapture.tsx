import { Show, createSignal, type JSX } from 'solid-js'
import type { NotebookId } from '../notes/ids'
import { errorMessage, routeHref, useApp } from '../state/appStore'
import { WorkspaceIcon } from './WorkspaceIcon'

export function NoteCapture(props: { notebookId: NotebookId; empty: boolean }): JSX.Element {
  const app = useApp()
  const { text: draft, setText: setDraft, busy, setBusy, error, setError } =
    app.writingDrafts.get(`note:${props.notebookId}`)
  const [open, setOpen] = createSignal(Boolean(draft()))
  let textarea: HTMLTextAreaElement | undefined

  const save = async (event: Event) => {
    event.preventDefault()
    if (busy() || !draft().trim()) return
    const notebookId = props.notebookId
    const startedRoute = routeHref(app.state.route)
    setBusy(true)
    setError('')
    try {
      const note = await app.client.createNote(notebookId, draft())
      setDraft('')
      setOpen(false)
      await app.refreshCatalog()
      if (routeHref(app.state.route) === startedRoute) {
        app.openNote(note.noteId, note.notebookId)
      }
      app.setMessage('Saved.')
    } catch (error) {
      setError(`Could not save your note: ${errorMessage(error)}`)
    } finally {
      setBusy(false)
    }
  }

  return <section class="note-capture" aria-label="Write a note">
    <Show when={open() || props.empty} fallback={<button type="button" class="secondary" aria-label={draft() ? 'Resume draft' : 'Add a note'} title={draft() ? 'Resume draft' : 'Add a note'} onClick={() => {
      setOpen(true)
      queueMicrotask(() => textarea?.focus())
    }}><WorkspaceIcon name="add" /></button>}>
      <form onSubmit={(event) => void save(event)}>
        <label><span class="sr-only">Write a note</span>
          <textarea ref={textarea} rows={6} value={draft()} disabled={busy()}
            onInput={(event) => setDraft(event.currentTarget.value)} />
        </label>
        <div class="learning-actions">
          <button type="submit" aria-label="Save note" title="Save note" disabled={busy() || !draft().trim()}><WorkspaceIcon name="save" /></button>
          <Show when={!props.empty}><button type="button" class="secondary" aria-label="Close draft" title="Close draft" disabled={busy()} onClick={() => setOpen(false)}><WorkspaceIcon name="close" /></button></Show>
        </div>
        <Show when={error()}><p role="alert" class="note-inline-error">{error()}</p></Show>
      </form>
    </Show>
  </section>
}
