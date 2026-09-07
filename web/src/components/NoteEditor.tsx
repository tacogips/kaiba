import { Show, createSignal, type JSX } from 'solid-js'
import type { Note } from '../notes/types'
import { errorMessage, useApp } from '../state/appStore'

export function NoteEditor(props: { note: Note }): JSX.Element {
  const app = useApp()
  const record = app.writingDrafts.get(`edit:${props.note.noteId}`)
  const [open, setOpen] = createSignal(Boolean(record.text()))
  const [conflict, setConflict] = createSignal(false)
  const writable = () => !props.note.readOnly && !app.notebook()?.readOnly
  const save = async (event: Event) => {
    event.preventDefault()
    if (record.busy() || !writable() || !record.text().trim()) return
    record.setBusy(true)
    record.setError('')
    try {
      const latest = await app.client.note(props.note.noteId)
      if (latest.bodyMarkdown !== record.baseText()) {
        setConflict(true)
        record.setError('This note changed while you were editing. Your draft has not been saved over the newer version.')
        return
      }
      await app.client.updateNote(props.note.noteId, record.text())
      record.setText('')
      setOpen(false)
      await app.refreshCatalog()
      app.setMessage('Note updated.')
    } catch (error) {
      record.setError(`Could not save your changes: ${errorMessage(error)}`)
    } finally {
      record.setBusy(false)
    }
  }
  return <Show when={writable() || open()}>
    <div class="note-editor">
      <Show when={open()} fallback={<button type="button" class="secondary" onClick={() => {
        if (!record.text()) {
          record.setText(props.note.bodyMarkdown)
          record.setBaseText(props.note.bodyMarkdown)
        }
        setOpen(true)
      }}>{record.text() ? 'Resume editing' : 'Edit my note'}</button>}>
        <form onSubmit={(event) => void save(event)}>
          <label>Edit note text
            <textarea rows={10} value={record.text()} disabled={record.busy()}
              onInput={(event) => record.setText(event.currentTarget.value)} />
          </label>
          <div class="learning-actions">
            <button type="submit" disabled={!writable() || record.busy() || !record.text().trim()}>{record.busy() ? 'Saving…' : 'Save changes'}</button>
            <button type="button" class="secondary" disabled={record.busy()} onClick={() => setOpen(false)}>Close draft</button>
          </div>
          <Show when={!writable()}><p role="status">This note is now read-only. Your draft is kept for this session.</p></Show>
          <Show when={record.error()}><p role="alert" class="note-inline-error">{record.error()}</p></Show>
          <Show when={conflict()}><button type="button" class="secondary" disabled={record.busy()} onClick={async () => {
            record.setBusy(true)
            try {
              const latest = await app.client.note(props.note.noteId)
              record.setText(latest.bodyMarkdown)
              record.setBaseText(latest.bodyMarkdown)
              record.setError('')
              setConflict(false)
            } catch (error) { record.setError(errorMessage(error)) }
            finally { record.setBusy(false) }
          }}>Discard draft and load latest text</button></Show>
          <p class="composer-help">Markdown is supported. Changes update this note in your shared knowledge store.</p>
        </form>
      </Show>
    </div>
  </Show>
}
