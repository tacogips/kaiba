import { For, Show, type JSX } from 'solid-js'
import { useApp } from '../state/appStore'
import { JumpBackControl } from '../components/JumpBackControl'
import { formatTimestamp } from '../notes/format'
import '../components/tasks.css'

export function TasksView(): JSX.Element {
  const app = useApp()
  const priority = { running: 0, queued: 1, failed: 2, completed: 3, cancelled: 4 } as const
  const ordered = () => [...app.ocrTasks.tasks()].sort((left, right) => priority[left.status] - priority[right.status]
    || (left.status === 'queued' ? left.createdAt.localeCompare(right.createdAt) : right.createdAt.localeCompare(left.createdAt)))
  return <main class="tasks-view" id="main-content" tabindex="-1">
    <header class="tasks-head"><JumpBackControl /><div><h1>Tasks</h1><p>{app.ocrTasks.active().length} active · OCR and page text</p></div></header>
    <div class="tasks-body">
      <Show when={app.ocrTasks.active().length > 0}><p class="pane-note">Keep this app open until queued OCR tasks finish.</p></Show>
      <Show when={app.ocrTasks.tasks().length} fallback={<p class="pane-empty">No tasks yet. Start page recognition from the page text view or Analysis.</p>}>
        <ol class="task-list"><For each={ordered()}>{(task) => <li class="task-row">
          <div><h2>{task.label}{task.pageNumber ? ` · Page ${task.pageNumber}` : ''} OCR</h2>
            <p><span class="task-status" data-status={task.status}>{task.status === 'running' ? 'Running' : task.status === 'queued' ? 'Queued' : task.status === 'completed' ? 'Completed' : task.status === 'failed' ? 'Failed' : 'Cancelled'}</span> · {formatTimestamp(task.createdAt)}</p>
            <Show when={task.error}><p class="note-inline-error" role="alert">{task.error}</p></Show>
          </div>
          <div class="task-actions">
            <button type="button" class="secondary" onClick={() => app.openNoteWithReturn(task.noteId, task.notebookId)}>Open page</button>
            <Show when={task.status === 'failed'}><button type="button" class="secondary" onClick={() => app.ocrTasks.retry(task.id)}>Retry</button></Show>
            <Show when={task.status === 'queued'}><button type="button" class="secondary" onClick={() => app.ocrTasks.cancel(task.id)}>Cancel</button></Show>
          </div>
        </li>}</For></ol>
      </Show>
    </div>
  </main>
}
