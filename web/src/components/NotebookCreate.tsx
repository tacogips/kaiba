import { Show, createSignal, type JSX } from 'solid-js'
import { errorMessage, routeHref, useApp } from '../state/appStore'

/** Inline creation keeps a learner's place and retains input after a failure. */
export function NotebookCreate(props: { onCreated?: () => void; buttonLabel?: string } = {}): JSX.Element {
  const app = useApp()
  const { text: title, setText: setTitle, busy, setBusy, error, setError } =
    app.writingDrafts.get('new-notebook')
  const [open, setOpen] = createSignal(Boolean(title()))
  let input: HTMLInputElement | undefined

  const submit = async (event: Event) => {
    event.preventDefault()
    if (busy() || !title().trim()) return
    setBusy(true)
    const startedRoute = routeHref(app.state.route)
    setError('')
    try {
      const notebook = await app.client.createNotebook(title())
      setTitle('')
      setOpen(false)
      await app.refreshCatalog()
      if (routeHref(app.state.route) === startedRoute) {
        app.openNotebook(notebook.notebookId)
        props.onCreated?.()
      } else app.setMessage(`Created notebook “${notebook.title}”.`)
    } catch (error) {
      setError(`Could not create the notebook: ${errorMessage(error)}`)
    } finally {
      setBusy(false)
    }
  }

  const closedLabel = () => title() ? 'Resume notebook draft' : props.buttonLabel ?? 'New notebook'

  return <div class="notebook-create">
    <Show when={open()} fallback={<button type="button" onClick={() => {
      setOpen(true)
      queueMicrotask(() => input?.focus())
    }} aria-label={closedLabel()} title={closedLabel()}>{title() ? 'Resume notebook draft' : props.buttonLabel ?? '+'}</button>}>
      <form class="notebook-create-form" onSubmit={(event) => void submit(event)}>
        <label>Notebook name
          <input ref={input} value={title()} disabled={busy()} required maxlength={200}
            placeholder="Untitled"
            onInput={(event) => setTitle(event.currentTarget.value)} />
        </label>
        <div class="learning-actions">
          <button type="submit" disabled={busy() || !title().trim()}>{busy() ? 'Creating…' : 'Create notebook'}</button>
          <button type="button" class="secondary" disabled={busy()} onClick={() => setOpen(false)}>Cancel</button>
        </div>
        <Show when={error()}><p role="alert" class="note-inline-error">{error()}</p></Show>
      </form>
    </Show>
  </div>
}
