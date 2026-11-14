import { For, Show, createEffect, createSignal, onCleanup, type JSX } from 'solid-js'
import { useApp } from '../state/appStore'
import type { Note, Notebook } from '../notes/types'
import { documentPageMetadata } from '../notes/documentPages'
import { importedNotebookSource } from '../notes/importedNotebook'
import { noteDisplayTitle } from '../notes/noteText'
import { WorkspaceIcon } from './WorkspaceIcon'

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
  const imported = () => importedNotebookSource(props.notebook, notes())
  const expanded = () => app.state.expandedNotebooks.includes(props.notebook.notebookId)
  const notes = (): Note[] => app.state.notesByNotebook[props.notebook.notebookId] ?? []
  const [visibleCount, setVisibleCount] = createSignal(200)
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
          aria-label={`${expanded() ? 'Collapse' : 'Expand'} ${props.notebook.title}`} title={`${expanded() ? 'Collapse' : 'Expand'} ${props.notebook.title}`}
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
        ><Show when={imported()} fallback={<span class="tree-icon" aria-hidden="true">▤</span>}>{(source) =>
          <span class="tree-icon" role="img" aria-label={`Imported file: ${source()}`} title={`Imported file: ${source()}`}><WorkspaceIcon name="file" /></span>
        }</Show><span class="tree-label-text">{props.notebook.title}</span></button>
        <Show when={props.notebook.readOnly && !imported()}><span class="tree-count" role="img" aria-label="Read-only notebook" title="Read-only notebook"><WorkspaceIcon name="lock" /></span></Show>
      </div>
      <Show when={expanded()}>
        <div role="group">
          <For each={notes().slice(0, visibleCount())}>{(note) =>
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
                aria-current={app.state.noteId === note.noteId ? 'page' : undefined}
                title={documentPageMetadata(note) ? `Page ${note.noteNumber}: ${noteDisplayTitle(note)}` : noteDisplayTitle(note)}
                onClick={() => {
                  app.openNote(note.noteId, note.notebookId)
                  props.onNavigate?.()
                }}
              ><span class="tree-icon" aria-hidden="true">·</span><span class="tree-label-text">{documentPageMetadata(note) ? `Page ${note.noteNumber}` : noteDisplayTitle(note)}</span></button>
            </div>}
          </For>
          <TreePageLoader notebook={props.notebook} visibleCount={visibleCount()} onReveal={() => setVisibleCount((count) => count + 200)} />
          <Show when={notes().length === 0}>
            <Show when={app.notesLoadState(props.notebook.notebookId) === 'loading'}>
              <p class="pane-empty" role="status">Loading notes…</p>
            </Show>
            <Show when={app.notesLoadState(props.notebook.notebookId) === 'error'}>
              <div class="pane-empty"><p role="status">Could not load notes.</p>
                <button type="button" class="secondary" onClick={() => void app.loadNotes(props.notebook.notebookId)}>Retry loading notes</button>
              </div>
            </Show>
            <Show when={app.notesLoadState(props.notebook.notebookId) === 'ready'}>
              <p class="pane-empty" style={{ '--tree-level': props.level + 1 }}>No notes.</p>
            </Show>
          </Show>
        </div>
      </Show>
    </div>
  )
}

/** The sentinel stays after existing rows, so fetching never replaces the tree. */
function TreePageLoader(props: { notebook: Notebook; visibleCount: number; onReveal: () => void }): JSX.Element {
  const app = useApp()
  const [busy, setBusy] = createSignal(false)
  let marker!: HTMLDivElement
  const hasMore = () => (app.state.notesByNotebook[props.notebook.notebookId]?.length ?? 0) > props.visibleCount || app.canLoadMoreNotes(props.notebook.notebookId)
  const load = async () => {
    if (busy() || !hasMore()) return
    setBusy(true)
    try {
      if ((app.state.notesByNotebook[props.notebook.notebookId]?.length ?? 0) <= props.visibleCount) await app.loadMoreNotes(props.notebook.notebookId)
      if ((app.state.notesByNotebook[props.notebook.notebookId]?.length ?? 0) > props.visibleCount) props.onReveal()
    }
    finally { setBusy(false) }
  }
  createEffect(() => {
    const count = app.state.notesByNotebook[props.notebook.notebookId]?.length ?? 0
    if (!count || !hasMore()) return
    const observer = new IntersectionObserver((entries) => {
      if (entries.some((entry) => entry.isIntersecting)) void load()
    }, { root: marker.closest('.pane-body'), rootMargin: '240px 0px' })
    observer.observe(marker)
    onCleanup(() => observer.disconnect())
  })
  return <div ref={marker} class="tree-page-loader">
    <Show when={hasMore()}>
      <button type="button" class="secondary" disabled={busy()} onClick={() => void load()}>
        {busy() ? 'Loading more…' : 'Load more notes'}
      </button>
    </Show>
  </div>
}
