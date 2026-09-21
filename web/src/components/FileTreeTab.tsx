import { For, Show, type JSX } from 'solid-js'
import { useApp } from '../state/appStore'
import type { Note, Notebook } from '../notes/types'
import { noteDisplayTitle } from '../notes/noteText'

// Show notebooks directly; expanding a notebook lazily loads its notes.

export function FileTreeTab(props: { onNavigate?: () => void } = {}): JSX.Element {
  const app = useApp()
  const notebooks = () => app.state.notebooks.filter((notebook) => notebook.type !== 'AGENT_CHAT')

  return (
    <div class="file-tree" role="tree" aria-label="Notebooks and notes">
      <Show when={app.state.loading && app.state.notebooks.length === 0}>
        <div class="loading-state"><span class="loader" />Loading library…</div>
      </Show>
      <For each={notebooks()}>{(notebook) => <NotebookBranch notebook={notebook} level={1} onNavigate={props.onNavigate} />}</For>
      <Show when={!app.state.loading && notebooks().length === 0}>
        <p class="pane-empty">No notebooks yet.</p>
      </Show>
    </div>
  )
}

function NotebookBranch(props: { notebook: Notebook; level: number; onNavigate?: () => void }): JSX.Element {
  const app = useApp()
  const expanded = () => app.state.expandedNotebooks.includes(props.notebook.notebookId)
  const notes = (): Note[] => app.state.notesByNotebook[props.notebook.notebookId] ?? []
  return (
    <div>
      <div
        classList={{ 'tree-row': true, selected: app.state.notebookId === props.notebook.notebookId }}
        role="treeitem"
        aria-level={props.level}
        aria-expanded={expanded()}
        style={{ '--tree-level': props.level }}
      >
        <button
          type="button"
          class="tree-twisty"
          aria-label={`${expanded() ? 'Collapse' : 'Expand'} ${props.notebook.title}`}
          onClick={() => app.toggleNotebook(props.notebook.notebookId)}
        >{expanded() ? '⌄' : '›'}</button>
        <button
          type="button"
          class="tree-label"
          title={props.notebook.title}
          onClick={() => {
            app.openNotebook(props.notebook.notebookId)
            props.onNavigate?.()
          }}
        ><span class="tree-icon" aria-hidden="true">▤</span><span class="tree-label-text">{props.notebook.title}</span></button>
        <Show when={props.notebook.readOnly}><span class="tree-count" title="Read-only">L</span></Show>
      </div>
      <Show when={expanded()}>
        <div role="group">
          <For each={notes()}>{(note) =>
            <div
              classList={{ 'tree-row': true, selected: app.state.noteId === note.noteId }}
              role="treeitem"
              aria-level={props.level + 1}
              aria-selected={app.state.noteId === note.noteId}
              style={{ '--tree-level': props.level + 1 }}
            >
              <span class="tree-twisty" aria-hidden="true" />
              <button
                type="button"
                class="tree-label"
                title={noteDisplayTitle(note)}
                onClick={() => {
                  app.openNote(note.noteId, note.notebookId)
                  props.onNavigate?.()
                }}
              ><span class="tree-icon" aria-hidden="true">·</span><span class="tree-label-text">{noteDisplayTitle(note)}</span></button>
            </div>}
          </For>
          <Show when={notes().length === 0}>
            <p class="pane-empty" style={{ '--tree-level': props.level + 1 }}>No notes.</p>
          </Show>
        </div>
      </Show>
    </div>
  )
}
