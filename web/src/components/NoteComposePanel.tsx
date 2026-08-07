import { Show, createSignal } from 'solid-js'
import { derivedNoteTitle, workspaceErrorMessage } from './NoteDetailLogic'

export type NoteComposeDestination = 'memo' | 'notebook'

/** Compose sheet for a new memo or a new note inside the selected notebook,
 * mirroring RielaNoteComposeView: a failed save keeps the typed body so the
 * text is never lost, and Cmd/Ctrl+Enter submits. */
export function NoteComposePanel(props: {
  destination: NoteComposeDestination
  notebookTitle?: string
  onSave: (bodyMarkdown: string) => Promise<void>
  onClose: () => void
}) {
  const [bodyMarkdown, setBodyMarkdown] = createSignal('')
  const [saving, setSaving] = createSignal(false)
  const [saveError, setSaveError] = createSignal('')
  const title = () => (props.destination === 'memo' ? 'New memo' : 'New note')
  const destinationText = () => props.destination === 'memo'
    ? 'User memo'
    : `Notebook: ${props.notebookTitle ?? 'Selected notebook'}`
  const canSave = () => !saving() && bodyMarkdown().trim().length > 0

  const save = async () => {
    if (!canSave()) return
    setSaving(true)
    setSaveError('')
    try {
      await props.onSave(bodyMarkdown())
    } catch (error) {
      setSaveError(workspaceErrorMessage(error))
      setSaving(false)
    }
  }

  return <div class="note-modal-backdrop" role="presentation" onClick={(event) => {
    if (event.target === event.currentTarget) props.onClose()
  }}>
    <section class="note-modal note-compose" role="dialog" aria-modal="true" aria-label={title()}>
      <header>
        <div>
          <span class="eyebrow">{destinationText()}</span>
          <h2>{derivedNoteTitle(bodyMarkdown())}</h2>
        </div>
        <button class="secondary" aria-label={`Close ${title()}`} onClick={props.onClose}>×</button>
      </header>
      <label>
        <span class="sr-only">Note body markdown</span>
        <textarea
          class="note-body-editor"
          aria-label="Note body markdown"
          autofocus
          rows={14}
          value={bodyMarkdown()}
          disabled={saving()}
          onInput={(event) => setBodyMarkdown(event.currentTarget.value)}
          onKeyDown={(event) => {
            if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
              event.preventDefault()
              void save()
            }
          }}
        />
      </label>
      <Show when={saveError()}><p class="note-inline-error" role="alert">{saveError()}</p></Show>
      <footer>
        <button class="secondary" disabled={saving()} onClick={props.onClose}>Cancel</button>
        <button disabled={!canSave()} onClick={() => void save()}>{saving() ? 'Saving…' : 'Save'}</button>
      </footer>
    </section>
  </div>
}
