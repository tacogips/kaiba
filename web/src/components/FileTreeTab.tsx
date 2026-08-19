import { For, Show, createMemo, type JSX } from 'solid-js'
import { useApp } from '../state/appStore'
import { buildFolderTree, directFolderAssignments, type TagTreeNode } from '../notes/tree'
import type { Note, Notebook } from '../notes/types'
import { noteDisplayTitle } from '../notes/noteText'

// Files tab: the folder tag tree from `notes/tree.ts`, the notebooks filed in
// each folder, and each notebook's notes. Notes load the first time a notebook
// is expanded so opening the tree never fetches the whole store.

export function FileTreeTab(props: { onNavigate?: () => void } = {}): JSX.Element {
  const app = useApp()
  const folders = createMemo(() => buildFolderTree(app.state.tags))
  const unfiled = createMemo(() =>
    app.state.notebooks.filter((notebook) => directFolderAssignments(notebook).length === 0))

  return (
    <div class="file-tree" role="tree" aria-label="Folders, notebooks and notes">
      <Show when={app.state.loading && app.state.notebooks.length === 0}>
        <div class="loading-state"><span class="loader" />Loading library…</div>
      </Show>
      <For each={folders()}>{(node) => <FolderBranch node={node} level={1} onNavigate={props.onNavigate} />}</For>
      <Show when={unfiled().length > 0}>
        <div class="tree-group" role="treeitem" aria-level={1} aria-expanded={true}>
          <span class="tree-label tree-static">Unfiled</span>
        </div>
        <div role="group">
          <For each={unfiled()}>{(notebook) => <NotebookBranch notebook={notebook} level={2} onNavigate={props.onNavigate} />}</For>
        </div>
      </Show>
      <Show when={!app.state.loading && app.state.notebooks.length === 0}>
        <p class="pane-empty">No notebooks yet.</p>
      </Show>
    </div>
  )
}

function FolderBranch(props: { node: TagTreeNode; level: number; onNavigate?: () => void }): JSX.Element {
  const app = useApp()
  const expanded = () => app.state.expandedFolders.includes(props.node.tag.tagId)
  const notebooks = createMemo(() => app.state.notebooks.filter((notebook) =>
    directFolderAssignments(notebook).some((tag) => tag.tagId === props.node.tag.tagId)))
  return (
    <div>
      <div
        class="tree-row"
        role="treeitem"
        aria-level={props.level}
        aria-expanded={expanded()}
        style={{ '--tree-level': props.level }}
      >
        <button
          type="button"
          class="tree-twisty"
          aria-label={`${expanded() ? 'Collapse' : 'Expand'} ${props.node.tag.name}`}
          onClick={() => app.toggleFolder(props.node.tag.tagId)}
        >{expanded() ? '⌄' : '›'}</button>
        <button
          type="button"
          class="tree-label"
          onClick={() => app.toggleFolder(props.node.tag.tagId)}
        ><span class="tree-icon" aria-hidden="true">▰</span>{props.node.tag.name}</button>
        <span class="tree-count">{notebooks().length}</span>
      </div>
      <Show when={expanded()}>
        <div role="group">
          <For each={props.node.children}>{(child) =>
            <FolderBranch node={child} level={props.level + 1} onNavigate={props.onNavigate} />}
          </For>
          <For each={notebooks()}>{(notebook) =>
            <NotebookBranch notebook={notebook} level={props.level + 1} onNavigate={props.onNavigate} />}
          </For>
          <Show when={props.node.children.length === 0 && notebooks().length === 0}>
            <p class="pane-empty" style={{ '--tree-level': props.level + 1 }}>Empty folder.</p>
          </Show>
        </div>
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
          onClick={() => {
            app.openNotebook(props.notebook.notebookId)
            props.onNavigate?.()
          }}
        ><span class="tree-icon" aria-hidden="true">▤</span>{props.notebook.title}</button>
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
                onClick={() => {
                  app.openNote(note.noteId, note.notebookId)
                  props.onNavigate?.()
                }}
              ><span class="tree-icon" aria-hidden="true">·</span>{noteDisplayTitle(note)}</button>
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
