import { Show } from 'solid-js'
import { useApp } from '../state/appStore'
import { WorkspaceIcon } from './WorkspaceIcon'
import './tasks.css'

export function TaskIndicator() {
  const app = useApp()
  const active = () => app.ocrTasks.active()
  const first = () => active().find((task) => task.status === 'running') ?? active()[0]
  const label = () => {
    const task = first()
    return task ? `${task.label}${task.pageNumber ? ` · Page ${task.pageNumber}` : ''} OCR` : 'Tasks'
  }
  const description = () => `${label()}${active().length > 1 ? ` · ${active().length - 1} more` : ''}`
  return <a class="workspace-task-link" href="#/tasks" aria-label={`Open task list: ${description()}`} title={description()}
    aria-live="polite" onClick={(event) => { event.preventDefault(); app.openTasks() }}>
    <WorkspaceIcon name={active().length ? 'refresh' : 'tasks'} /><span class="workspace-task-title">{label()}</span>
    <Show when={active().length > 1}><span class="workspace-task-count">{active().length - 1} more</span></Show>
  </a>
}
