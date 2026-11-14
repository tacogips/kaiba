import { For, Show, createMemo, createSignal, type JSX } from 'solid-js'
import { useApp, type AppStore } from '../state/appStore'
import { markdownHeadingTree, noteHeadingPrefix, type HeadingNode } from '../notes/toc'
import { noteDisplayTitle } from '../notes/noteText'
import type { Note } from '../notes/types'

// Contents tab: notebook -> note -> heading hierarchy. The open notebook is the
// root entry, every note nests beneath it, and each note's markdown heading
// tree (h1-h6) nests beneath the note. The open note's headings are expanded by
// default; any note can be expanded or collapsed explicitly.

export function TocTab(props: { app?: AppStore } = {}): JSX.Element {
  const app = props.app ?? useApp()
  const notes = createMemo(() => app.notes())
  const [expanded, setExpanded] = createSignal(new Map<string, boolean>())

  const isExpanded = (note: Note): boolean =>
    expanded().get(note.noteId) ?? note.noteId === app.state.noteId

  const toggle = (note: Note) => {
    const next = new Map(expanded())
    next.set(note.noteId, !isExpanded(note))
    setExpanded(next)
  }

  return (
    <div class="toc">
      <Show
        when={app.state.notebookId || app.state.note}
        fallback={<p class="pane-empty">Open a notebook to see its contents.</p>}
      >
        <ul class="toc-list" aria-label="Notebook contents">
          <li>
            <button
              type="button"
              classList={{ 'toc-entry': true, 'toc-notebook': true }}
              style={{ '--toc-level': 1 }}
              onClick={() => {
                const notebookId = app.state.notebookId ?? app.state.note?.notebookId
                if (notebookId) app.openNotebook(notebookId)
              }}
            >{app.notebook()?.title ?? 'Notebook'}</button>
            <ul class="toc-list">
              <For each={notes()}>{(note) => {
                const open = () => note.noteId === app.state.noteId
                const headings = createMemo(() =>
                  markdownHeadingTree(note.bodyMarkdown, noteHeadingPrefix(note.noteId)))
                return <li>
                  <div class="toc-note-row">
                    <Show
                      when={headings().length > 0}
                      fallback={<span class="toc-disclosure-spacer" aria-hidden="true" />}
                    >
                      <button
                        type="button"
                        class="toc-disclosure"
                        aria-label={isExpanded(note)
                          ? `Collapse the contents of ${noteDisplayTitle(note)}`
                          : `Expand the contents of ${noteDisplayTitle(note)}`}
                        aria-expanded={isExpanded(note)}
                        onClick={() => toggle(note)}
                      >{isExpanded(note) ? '▾' : '▸'}</button>
                    </Show>
                    <button
                      type="button"
                      classList={{ 'toc-entry': true, 'toc-note': true, active: open() }}
                      style={{ '--toc-level': 2 }}
                      onClick={() => app.openNote(note.noteId, note.notebookId)}
                    >{noteDisplayTitle(note)}</button>
                  </div>
                  <Show when={isExpanded(note) && headings().length > 0}>
                    <HeadingList app={app} noteId={note.noteId} nodes={headings()} level={3} />
                  </Show>
                </li>
              }}</For>
            </ul>
          </li>
        </ul>
        <Show when={notes().length === 0}>
          <p class="pane-empty">This notebook has no notes.</p>
        </Show>
      </Show>
    </div>
  )
}

function HeadingList(props: {
  app: AppStore
  noteId: string
  nodes: HeadingNode[]
  level: number
}): JSX.Element {
  const app = props.app
  return (
    <Show when={props.nodes.length > 0}>
      <ul class="toc-list" aria-label={props.level === 3 ? 'Note contents' : undefined}>
        <For each={props.nodes}>{(node) =>
          <li>
            <button
              type="button"
              classList={{ 'toc-entry': true, active: app.state.activeHeadingId === node.id }}
              style={{ '--toc-level': props.level }}
              aria-current={app.state.activeHeadingId === node.id ? 'location' : undefined}
              onClick={() => jumpToHeading(props.noteId, node.id, app.setActiveHeading)}
            >{node.text}</button>
            <HeadingList app={app} noteId={props.noteId} nodes={node.children} level={props.level + 1} />
          </li>}
        </For>
      </ul>
    </Show>
  )
}

/** Scrolls the reader to a heading. A heading inside a note that has not
 * lazy-mounted yet has no element, so the note section is scrolled into view
 * first (which mounts it) and the heading is retried until it exists. */
function jumpToHeading(noteId: string, headingId: string, setActive: (id: string) => void): void {
  setActive(headingId)
  const existing = document.getElementById(headingId)
  if (existing) {
    existing.scrollIntoView({ behavior: 'smooth', block: 'start' })
    return
  }
  document.querySelector<HTMLElement>(`[data-note-id="${CSS.escape(noteId)}"]`)
    ?.scrollIntoView({ block: 'start' })
  let tries = 25
  const poll = () => {
    const target = document.getElementById(headingId)
    if (target) {
      target.scrollIntoView({ behavior: 'smooth', block: 'start' })
      return
    }
    tries -= 1
    if (tries > 0) setTimeout(poll, 80)
  }
  setTimeout(poll, 80)
}
