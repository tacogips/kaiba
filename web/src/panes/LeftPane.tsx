import { Show, type JSX } from 'solid-js'
import { FileTreeTab } from '../components/FileTreeTab'
import { NotebookTimeline } from '../components/NotebookTimeline'
import { WorkspaceIcon } from '../components/WorkspaceIcon'
import { TocTab } from '../components/TocTab'
import { useApp } from '../state/appStore'

export function LeftPane(props: { onClose?: () => void; onNavigate?: () => void } = {}): JSX.Element {
  const app = useApp()
  const hasContents = () => Boolean(app.state.notebookId || app.state.note)
  return (
    <aside class="pane pane-left" aria-label="Library and contents">
      <Show
        when={app.state.pane.leftOpen}
        fallback={
          <div class="pane-rail">
            <button
              type="button"
              class="rail-button"
              aria-label="Open the library pane"
              aria-expanded={false}
              onClick={app.toggleLeftPane}
            >›</button>
            <span class="rail-label">Notebooks</span>
          </div>
        }
      >
        <div class="pane-head">
          <span class="notebook-tree-title">Notebooks</span>
          <div class="notebook-view-controls" role="group" aria-label="Notebook view">
            <button type="button" class="workspace-icon" aria-label="Tree view" title="Tree view"
              aria-pressed={app.state.pane.notebookView === 'tree'} onClick={() => app.setNotebookView('tree')}><WorkspaceIcon name="tree" /></button>
            <button type="button" class="workspace-icon" aria-label="Timeline view" title="Timeline view (⌘/Ctrl Shift T to toggle)"
              aria-pressed={app.state.pane.notebookView === 'timeline'} onClick={() => app.setNotebookView('timeline')}><WorkspaceIcon name="timeline" /></button>
          </div>
          <button
            type="button"
            class="pane-fold"
            aria-label="Collapse the library pane"
            aria-expanded={true}
            onClick={() => {
              app.toggleLeftPane()
              props.onClose?.()
            }}
          >‹</button>
        </div>
        <div class="pane-body">
          <Show when={app.state.pane.notebookView === 'timeline'} fallback={<FileTreeTab onNavigate={props.onNavigate} />}>
            <NotebookTimeline onNavigate={props.onNavigate} />
          </Show>
          <Show when={hasContents()}>
            <details class="notebook-outline">
              <summary>Outline</summary>
              <TocTab onNavigate={props.onNavigate} />
            </details>
          </Show>
        </div>
      </Show>
    </aside>
  )
}
