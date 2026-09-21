import { Show, type JSX } from 'solid-js'
import { errorMessage, routeHref, useApp } from '../state/appStore'
import { DocumentImportForm } from './DocumentImportForm'
import { WorkspaceIcon } from './WorkspaceIcon'

export function NewNotebookEditor(): JSX.Element {
  const app = useApp()
  const draft = app.writingDrafts.get('new-notebook-body')

  const save = async (event: Event) => {
    event.preventDefault()
    if (draft.busy() || !draft.text().trim()) return
    const startedRoute = routeHref(app.state.route)
    // Retain the exact request across failures and remounts: a lost response
    // must not create a second notebook when the user retries.
    const request = draft.submission() ?? { key: crypto.randomUUID(), body: draft.text() }
    draft.setSubmission(request)
    draft.setBusy(true)
    draft.setError('')
    try {
      const notebook = await app.client.saveNewNotebook(request.body, request.key)
      draft.setText('')
      draft.setSubmission(undefined)
      await app.refreshCatalog()
      if (routeHref(app.state.route) === startedRoute) app.openNotebook(notebook.notebookId)
    } catch (error) {
      draft.setError(`Could not save. Retry to keep this draft: ${errorMessage(error)}`)
    } finally {
      draft.setBusy(false)
    }
  }

  const importDocument = async (file: File, title?: string, maximumOCRPages?: string) => {
    const startedRoute = routeHref(app.state.route)
    const notebook = await app.client.importDocument(file, title, maximumOCRPages)
    await app.refreshCatalog()
    if (routeHref(app.state.route) === startedRoute) app.openNotebook(notebook.notebookId)
  }

  return <div class="reader-body new-notebook-editor">
    <DocumentImportForm onImport={importDocument} />
    <form class="note-capture" aria-label="New notebook" onSubmit={(event) => void save(event)}>
      <textarea aria-label="Write a new notebook" rows={16}
        value={draft.text()} disabled={draft.busy() || Boolean(draft.submission())}
        onInput={(event) => draft.setText(event.currentTarget.value)} />
      <div class="learning-actions">
        <button type="submit" aria-label="Save notebook" title="Save notebook"
          disabled={draft.busy() || !draft.text().trim()}><WorkspaceIcon name="save" /></button>
      </div>
      <Show when={draft.error()}><p class="note-inline-error" role="alert">{draft.error()}</p></Show>
    </form>
  </div>
}
