import { For, Show, createEffect, createSignal, type JSX } from 'solid-js'
import { MarkdownBody } from './Markdown'
import { errorMessage, useApp } from '../state/appStore'
import type { NoteComment } from '../notes/types'

// Memos are the note's comments: the stored list is read with `noteComments`
// and a new memo is written with `addNoteComment`, after which the list is
// re-read so what is on screen is always the server's copy.

export function MemoListTab(): JSX.Element {
  const app = useApp()
  const [memos, setMemos] = createSignal<NoteComment[]>([])
  const [loading, setLoading] = createSignal(false)
  const [draft, setDraft] = createSignal('')
  const [busy, setBusy] = createSignal(false)
  const [error, setError] = createSignal('')
  let generation = 0

  createEffect(() => {
    const noteId = app.state.noteId
    // Re-reads when the note's notebook reports a change, so an edit that
    // arrives through the events feed also refreshes the memos beside it.
    if (app.state.notebookId) void app.state.notebookRevisions[app.state.notebookId]
    if (!noteId) {
      generation += 1
      setMemos([])
      return
    }
    void load(noteId)
  })

  const load = async (noteId: string) => {
    const current = ++generation
    setLoading(true)
    setError('')
    try {
      const values = await app.client.noteComments(noteId)
      if (current !== generation) return
      setMemos(values)
    } catch (loadError) {
      if (current !== generation) return
      setMemos([])
      setError(errorMessage(loadError))
    } finally {
      if (current === generation) setLoading(false)
    }
  }

  const add = async () => {
    const noteId = app.state.noteId
    const body = draft().trim()
    if (!noteId || !body || busy()) return
    setBusy(true)
    setError('')
    try {
      await app.client.addNoteComment(noteId, body)
      setDraft('')
      await load(noteId)
    } catch (addError) {
      // The draft stays so a failed add is never lost.
      setError(errorMessage(addError))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div class="pane-section">
      <Show when={app.state.noteId} fallback={<p class="pane-empty">Open a note to read and write memos.</p>}>
        <Show when={loading() && memos().length === 0}>
          <div class="loading-state"><span class="loader" />Loading memos…</div>
        </Show>
        <For each={memos()}>{(memo) =>
          <article class="memo">
            <header><strong>{memo.author}</strong><span>{formatTimestamp(memo.createdAt)}</span></header>
            <MarkdownBody markdown={memo.bodyMarkdown} />
          </article>}
        </For>
        <Show when={!loading() && memos().length === 0 && !error()}>
          <p class="pane-empty">No memos on this note.</p>
        </Show>
        <label>
          <span class="sr-only">New memo markdown</span>
          <textarea
            aria-label="New memo markdown"
            rows={4}
            placeholder="Write a memo"
            value={draft()}
            disabled={busy()}
            onInput={(event) => setDraft(event.currentTarget.value)}
          />
        </label>
        <Show when={error()}><p class="note-inline-error" role="alert">{error()}</p></Show>
        <button type="button" disabled={busy() || draft().trim().length === 0} onClick={() => void add()}>
          {busy() ? 'Adding…' : 'Add memo'}
        </button>
      </Show>
    </div>
  )
}

function formatTimestamp(value: string): string {
  const date = new Date(value)
  return Number.isNaN(date.getTime())
    ? value
    : new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(date)
}
