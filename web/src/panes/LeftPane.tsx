import { Show, type JSX } from 'solid-js'
import { NotebookCreate } from '../components/NotebookCreate'
import { FileTreeTab } from '../components/FileTreeTab'
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
          <NotebookCreate onCreated={props.onNavigate} />
          <FileTreeTab onNavigate={props.onNavigate} />
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
