import { For, Show, createMemo, createSignal, type JSX } from 'solid-js'
import { errorMessage, useApp } from '../state/appStore'
import { groupTagAssignments, qualifiedTagLabel } from '../notes/tree'

// Info tab: the note's own facts (kind, numbering, timestamps, lock state) and
// its structured tag assignments grouped by tag class, each showing where the
// assignment came from. Tag extraction can be requested for the note here, and
// the whole notebook can be queued for AI translation.

export function NoteInfoTab(): JSX.Element {
  const app = useApp()
  const [status, setStatus] = createSignal('')
  const [busy, setBusy] = createSignal(false)
  const [language, setLanguage] = createSignal('')
  const [translateBusy, setTranslateBusy] = createSignal(false)
  const [translateStatus, setTranslateStatus] = createSignal('')
  const groups = createMemo(() =>
    groupTagAssignments(app.state.note?.tags ?? [], app.state.tagClasses))

  const extractTags = async () => {
    const noteId = app.state.noteId
    if (!noteId || busy()) return
    setBusy(true)
    setStatus('')
    try {
      const result = await app.client.requestTagExtraction({ noteId })
      setStatus(result === 'queued'
        ? 'Tag extraction queued. Tags appear once the agent finishes.'
        : 'Agent runtime not configured, so tag extraction was not queued.')
    } catch (error) {
      setStatus(errorMessage(error))
    } finally {
      setBusy(false)
    }
  }

  const translateNotebook = async () => {
    const notebookId = app.state.note?.notebookId
    const targetLanguage = language().trim()
    if (!notebookId || !targetLanguage || translateBusy()) return
    setTranslateBusy(true)
    setTranslateStatus('')
    try {
      const result = await app.client.requestNotebookTranslation({ notebookId, targetLanguage })
      setTranslateStatus(result.status === 'queued'
        ? 'Translation queued. The translated notebook fills in as the agent finishes each note.'
        : 'Agent runtime not configured, so translation was not queued.')
    } catch (error) {
      setTranslateStatus(errorMessage(error))
    } finally {
      setTranslateBusy(false)
    }
  }

  return (
    <div class="pane-section">
      <Show when={app.state.note} fallback={<p class="pane-empty">Open a note to see its details.</p>}>{(note) => <>
        <dl class="info-grid">
          <div><dt>Note</dt><dd>#{note().noteNumber}</dd></div>
          <div><dt>Access</dt><dd>{note().readOnly ? 'Read-only' : 'Editable'}</dd></div>
          <div><dt>Created</dt><dd>{formatTimestamp(note().createdAt)}</dd></div>
          <div><dt>Updated</dt><dd>{formatTimestamp(note().updatedAt)}</dd></div>
          <div><dt>Notebook</dt><dd>{app.notebook()?.title ?? note().notebookId}</dd></div>
        </dl>

        <section class="info-tags" aria-label="Tags">
          <h3>Tags</h3>
          <Show when={groups().length === 0}><p class="pane-empty">No tags on this note.</p></Show>
          <For each={groups()}>{(group) =>
            <div class="info-tag-group">
              <span class="info-tag-class">{group.label}</span>
              <div class="detail-chips">
                <For each={group.assignments}>{(assignment) =>
                  <span class="folder-chip" title={`${assignment.provenance}${assignment.assignedBy ? ` · ${assignment.assignedBy}` : ''}`}>
                    <button
                      type="button"
                      class="tag-chip-open"
                      title={`Open tag details: ${assignment.tag.name}`}
                      onClick={() => app.openTagPane(assignment.tag.tagId)}
                    >{qualifiedTagLabel(app.state.tags, assignment.tag.tagId)}</button>
                    <em class="tag-provenance">{assignment.provenance}</em>
                  </span>}
                </For>
              </div>
            </div>}
          </For>
          <button type="button" class="secondary" disabled={busy()} onClick={() => void extractTags()}>
            {busy() ? 'Requesting…' : 'Extract tags with agent'}
          </button>
          <Show when={status()}><p class="pane-note" role="status">{status()}</p></Show>
        </section>

        <section class="info-tags" aria-label="Translate notebook">
          <h3>Translate notebook</h3>
          <label>
            Target language
            <input
              value={language()}
              placeholder="e.g. English, 日本語"
              onInput={(event) => setLanguage(event.currentTarget.value)}
            />
          </label>
          <button
            type="button"
            class="secondary"
            disabled={translateBusy() || language().trim() === ''}
            onClick={() => void translateNotebook()}
          >
            {translateBusy() ? 'Requesting…' : 'Translate notebook with agent'}
          </button>
          <Show when={translateStatus()}><p class="pane-note" role="status">{translateStatus()}</p></Show>
        </section>
      </>}</Show>
    </div>
  )
}

function formatTimestamp(value: string): string {
  const date = new Date(value)
  return Number.isNaN(date.getTime())
    ? value
    : new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(date)
}
