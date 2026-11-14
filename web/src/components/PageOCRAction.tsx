import { Show, type JSX } from 'solid-js'
import type { NoteId } from '../notes/ids'
import { useApp } from '../state/appStore'
import { WorkspaceIcon } from './WorkspaceIcon'
import './form-controls.css'

/** Both the text viewer and Analysis enqueue the same deduplicated page task. */
export function PageOCRAction(props: { noteId: NoteId; pageNumber?: number; complete?: boolean }): JSX.Element {
  const app = useApp()
  const task = () => app.ocrTasks.taskFor(props.noteId)
  const busy = () => task()?.status === 'queued' || task()?.status === 'running'
  return <span class="page-ocr-action">
    <button type="button" class="secondary form-action-button" aria-label={props.complete ? "Run OCR again" : "Make page searchable"}
      title={props.complete ? "Run OCR again from the original page and replace its search text" : "Recognize the original page with OCR"} aria-busy={busy()} disabled={busy()}
      onClick={() => {
        const previous = task()
        if (previous?.status === 'failed') app.ocrTasks.retry(previous.id)
        else app.ocrTasks.enqueue(props.noteId, app.notebook()?.title ?? 'Document', props.pageNumber, true)
      }}>
      <WorkspaceIcon name={busy() ? 'refresh' : 'ai'} />{task()?.status === 'queued' ? 'Queued…' : task()?.status === 'running' ? 'Recognizing…' : task()?.status === 'failed' ? 'Retry OCR' : props.complete ? 'Run OCR again' : 'Recognize'}
    </button>
    <Show when={task()?.status === 'failed'}><span class="note-inline-error" role="alert">{task()?.error}</span></Show>
  </span>
}
