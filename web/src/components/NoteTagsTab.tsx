import { For, Show, createMemo, createSignal, type JSX } from 'solid-js'
import { WorkspaceIcon } from './WorkspaceIcon'
import './form-controls.css'
import { errorMessage, useApp } from '../state/appStore'
import { groupTagAssignments, qualifiedTagLabel } from '../notes/tree'

export function NoteTagsTab(): JSX.Element {
  const app = useApp()
  const [status, setStatus] = createSignal('')
  const [busy, setBusy] = createSignal(false)
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

  return <div class="pane-section">
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
          <button type="button" class="secondary form-action-button" aria-label="Extract tags with agent" title="Extract tags with agent" aria-busy={busy()} disabled={busy()} onClick={() => void extractTags()}>
            <WorkspaceIcon name="ai" />{busy() ? 'Requesting…' : 'Extract'}
          </button>
          <Show when={status()}><p class="pane-note" role="status">{status()}</p></Show>
        </section>

  </div>
}
