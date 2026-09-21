import { For, Show, createMemo, type JSX } from 'solid-js'
import { useApp } from '../state/appStore'
import { formatTimestamp } from '../notes/format'

/** The same library as the tree, ordered by absolute update time, newest first. */
export function NotebookTimeline(props: { onNavigate?: () => void }): JSX.Element {
  const app = useApp()
  const notebooks = createMemo(() => app.state.notebooks
    .filter((notebook) => notebook.type !== 'AGENT_CHAT')
    .sort((a, b) => (Date.parse(b.updatedAt) || 0) - (Date.parse(a.updatedAt) || 0)
      || a.notebookId.localeCompare(b.notebookId)))
  return <section aria-label="Notebook timeline">
    <Show when={app.state.loading && app.state.notebooks.length === 0}>
      <div class="loading-state"><span class="loader" />Loading library…</div>
    </Show>
    <ol class="notebook-timeline">
      <For each={notebooks()}>{(notebook) => <li>
        <button type="button" class="notebook-timeline-entry"
          aria-current={app.state.notebookId === notebook.notebookId ? 'page' : undefined}
          onClick={() => { app.openNotebook(notebook.notebookId); props.onNavigate?.() }}>
          <strong>{notebook.title}</strong>
          <time datetime={notebook.updatedAt}>{formatTimestamp(notebook.updatedAt)}</time>
          <Show when={notebook.readOnly}><span>Read-only</span></Show>
        </button>
      </li>}</For>
    </ol>
    <Show when={!app.state.loading && notebooks().length === 0}><p class="pane-empty">No notebooks yet.</p></Show>
  </section>
}
