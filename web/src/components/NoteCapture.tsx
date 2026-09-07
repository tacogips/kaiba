import { Show, createSignal, type JSX } from 'solid-js'
import type { NotebookId } from '../notes/ids'
import { errorMessage, routeHref, useApp } from '../state/appStore'

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
      if (routeHref(app.state.route) === startedRoute && app.state.pane.centerTab === 'notebook') {
        app.openNote(note.noteId, note.notebookId)
      }
      app.setMessage('Note saved. Ask AI to explore it in the Learn pane.')
    } catch (error) {
      setError(`Could not save your note: ${errorMessage(error)}`)
    } finally {
      setBusy(false)
    }
  }

  return <section class="note-capture" aria-label="Write a note">
    <Show when={open() || props.empty} fallback={<button type="button" class="secondary" onClick={() => {
      setOpen(true)
      queueMicrotask(() => textarea?.focus())
    }}>{draft() ? 'Resume draft' : 'Add a note'}</button>}>
      <form onSubmit={(event) => void save(event)}>
        <label>{props.empty ? 'Start with a thought, a question, or your source text' : 'Write a note'}
          <textarea ref={textarea} rows={6} value={draft()} disabled={busy()}
            placeholder="What do you want to understand? Paste your reading notes or write in your own words. Markdown is supported."
            onInput={(event) => setDraft(event.currentTarget.value)} />
        </label>
        <div class="learning-actions">
          <button type="submit" disabled={busy() || !draft().trim()}>{busy() ? 'Saving…' : 'Save note'}</button>
          <Show when={!props.empty}><button type="button" class="secondary" disabled={busy()} onClick={() => setOpen(false)}>Close draft</button></Show>
        </div>
        <Show when={error()}><p role="alert" class="note-inline-error">{error()}</p></Show>
        <p class="composer-help">Your draft stays here while you browse. Save it before closing the app.</p>
      </form>
    </Show>
  </section>
}
