import { For, Show, createEffect, createMemo, createSignal, on, onCleanup, type JSX } from 'solid-js'
import { WorkspaceIcon } from './WorkspaceIcon'
import './form-controls.css'
import { errorMessage, useApp } from '../state/appStore'
import type { NoteId } from '../notes/ids'
import { groupTagAssignments, qualifiedTagLabel } from '../notes/tree'

export function NoteTagsTab(): JSX.Element {
  const app = useApp()
  const [status, setStatus] = createSignal('')
  const [failed, setFailed] = createSignal(false)
  const [busy, setBusy] = createSignal(false)
  const groups = createMemo(() =>
    groupTagAssignments(app.state.note?.tags ?? [], app.state.tagClasses))
  let generation = 0
  let timer: ReturnType<typeof setTimeout> | undefined
  const reset = () => { generation += 1; if (timer) clearTimeout(timer); timer = undefined; return generation }
  const isCurrent = (id: NoteId, run: number) => run === generation && id === app.state.noteId
  const poll = async (id: NoteId, run: number, refreshOnComplete = false): Promise<void> => {
    try {
      const phase = await app.client.tagExtractionStatus(id)
      if (!isCurrent(id, run)) return
      const active = ['queued', 'running', 'retrying'].includes(phase)
      setBusy(active)
      setFailed(phase === 'failed' || phase === 'retrying')
      const messages: Record<string, string> = {
        none: '', queued: 'Tag extraction queued.', running: 'Extracting tags…',
        retrying: 'Tag extraction failed; an automatic retry is queued.',
        completed: 'Tag extraction complete.',
        failed: 'Tag extraction failed. Check the AI provider configuration, then retry.',
      }
      setStatus(messages[phase] ?? 'Tag extraction status could not be read.')
      if (phase === 'completed' && refreshOnComplete) await app.refreshCatalog()
      if (active && isCurrent(id, run)) timer = setTimeout(() => void poll(id, run, true), 1000)
    } catch (error) {
      if (isCurrent(id, run)) { setBusy(false); setFailed(true); setStatus(errorMessage(error)) }
    }
  }
  createEffect(on(() => app.state.noteId, (id) => {
    const run = reset(); setStatus(''); setFailed(false); setBusy(false)
    if (id) void poll(id, run)
  }))
  onCleanup(reset)

  const extractTags = async () => {
    const id = app.state.noteId
    if (!id || busy()) return
    const run = reset()
    setBusy(true); setStatus('Requesting tag extraction…'); setFailed(false)
    try {
      const result = await app.client.requestTagExtraction({ noteId: id })
      if (!isCurrent(id, run)) return
      if (result === 'queued') { await poll(id, run, true); return }
      setBusy(false); setFailed(true)
      setStatus('Tag extraction could not start: no AI agent is configured. Configure an AI provider before extracting names, book titles, and other tags.')
    } catch (error) {
      if (isCurrent(id, run)) { setBusy(false); setFailed(true); setStatus(errorMessage(error)) }
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
                    >{app.state.tags.some((tag) => tag.tagId === assignment.tag.tagId)
                      ? qualifiedTagLabel(app.state.tags, assignment.tag.tagId) : assignment.tag.name}</button>
                    <em class="tag-provenance">{assignment.provenance}</em>
                  </span>}
                </For>
              </div>
            </div>}
          </For>
          <button type="button" class="secondary form-action-button" aria-label="Extract tags with agent" title="Extract tags with agent" aria-busy={busy()} disabled={busy()} onClick={() => void extractTags()}>
            <WorkspaceIcon name="ai" />{busy() ? 'Extracting…' : failed() ? 'Retry' : 'Extract'}
          </button>
          <Show when={status()}><p class={failed() ? "note-inline-error" : "pane-note"} role={failed() ? "alert" : "status"}>{status()}</p></Show>
        </section>

  </div>
}
