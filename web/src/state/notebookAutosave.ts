import { createEffect, createSignal, onCleanup, untrack } from 'solid-js'
import type { NoteGraphQLClient } from '../notes/client'
import type { Notebook } from '../notes/types'
import type { createWritingDrafts } from './writingDrafts'

type Draft = ReturnType<ReturnType<typeof createWritingDrafts>['get']>

/** App-owned so navigation cannot cancel a pending save or create another book. */
export function createNotebookAutosave(client: NoteGraphQLClient, draft: Draft, refresh: () => Promise<void>, onDeleted?: () => void) {
  const [notebook, setNotebook] = createSignal<Notebook>()
  const [deleting, setDeleting] = createSignal(false)
  const [retry, setRetry] = createSignal(0)
  let inFlight: Promise<boolean> | undefined
  let disposed = false
  let generation = 0
  draft.setBaseText('')

  const flush = (): Promise<boolean> => {
    if (inFlight) return inFlight
    if (disposed || deleting()) return Promise.resolve(false)
    const source = draft.text()
    if (source === draft.baseText() && !draft.submission()) return Promise.resolve(true)
    if (!notebook() && !source.trim() && !draft.submission()) return Promise.resolve(true)
    const startedGeneration = generation
    const request = draft.submission() ?? { key: crypto.randomUUID(), body: source }
    draft.setSubmission(request)
    draft.setBusy(true)
    draft.setError('')
    inFlight = (async () => {
      try {
        const existing = notebook()
        const saved = existing
          ? await client.saveNotebookDraft(existing.notebookId, request.body)
          : await client.saveNewNotebook(request.body, request.key)
        if (disposed || startedGeneration !== generation) return false
        setNotebook(saved)
        draft.setBaseText(request.body)
        draft.setSubmission(undefined)
        // Catalog failures must not mark a successful database write unsaved.
        void refresh().catch(() => {})
        return true
      } catch (error) {
        if (!disposed && startedGeneration === generation) draft.setError(`Could not save: ${error instanceof Error ? error.message : String(error)}. Retrying…`)
        return false
      } finally {
        if (startedGeneration === generation) {
          inFlight = undefined
          if (!disposed) { draft.setBusy(false); setRetry((value) => value + 1) }
        }
      }
    })()
    return inFlight
  }

  createEffect(() => {
    const source = draft.text()
    const base = draft.baseText()
    const pending = draft.submission()
    const busy = draft.busy()
    const removing = deleting()
    retry()
    if (busy || removing || (source === base && !pending) || (!source.trim() && !pending && !untrack(notebook))) return
    const timer = setTimeout(() => { void flush() }, 3000)
    onCleanup(() => clearTimeout(timer))
  })
  onCleanup(() => { disposed = true })

  const reset = () => {
    setNotebook(undefined)
    draft.setText(''); draft.setBaseText(''); draft.setSubmission(undefined); draft.setError('')
  }
  const startNew = async () => {
    // The New notebook command also resumes an as-yet uncreated draft.
    if (!notebook() && !inFlight) return
    if (await flush()) reset()
  }
  const clear = () => { generation += 1; inFlight = undefined; draft.setBusy(false); reset() }
  const remove = async () => {
    if (deleting()) return
    // Resolve an ambiguously committed creation before removing it, reusing
    // the original idempotency key rather than leaving an orphan notebook.
    if (!notebook() && draft.submission() && !inFlight) void flush()
    setDeleting(true)
    draft.setError('')
    try {
      // A creation already sent must finish before deletion; no new save may
      // start once the user chooses Delete notebook.
      if (inFlight && !await inFlight) throw new Error('Wait for the notebook to finish saving before deleting it')
      const existing = notebook()
      if (existing) await client.deleteNotebook(existing.notebookId)
      reset()
      onDeleted?.()
      void refresh().catch(() => {})
    } catch (error) {
      draft.setError(`Could not delete: ${error instanceof Error ? error.message : String(error)}`)
    } finally { setDeleting(false) }
  }
  const status = () => deleting() ? 'Deleting…' : draft.busy() ? 'Saving…' : draft.error() ? 'Save failed'
    : draft.text() !== draft.baseText() || draft.submission() ? 'Unsaved changes' : notebook() ? 'Saved' : ''
  return { notebook, deleting, status, flush, startNew, remove, clear }
}
