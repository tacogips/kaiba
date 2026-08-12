import { For, Show, createMemo, type JSX } from 'solid-js'
import { useApp } from '../state/appStore'
import { markdownHeadingTree, type HeadingNode } from '../notes/toc'
import { noteDisplayTitle } from '../notes/noteText'

// Contents tab: the open note's heading tree. A notebook holding several notes
// (an imported document, one note per H1 section) lists its notes as the top
// level with the open note's headings nested beneath it.

export function TocTab(): JSX.Element {
  const app = useApp()
  const headings = createMemo(() => markdownHeadingTree(app.state.note?.bodyMarkdown ?? ''))
  const notes = createMemo(() => app.notes())

  return (
    <div class="toc">
      <Show when={app.state.note} fallback={<p class="pane-empty">Open a note to see its contents.</p>}>
        <Show
          when={notes().length > 1}
          fallback={<HeadingList nodes={headings()} level={1} />}
        >
          <ul class="toc-list" aria-label="Notebook contents">
            <For each={notes()}>{(note) => {
              const open = () => note.noteId === app.state.noteId
              return <li>
                <button
                  type="button"
                  classList={{ 'toc-entry': true, 'toc-note': true, active: open() }}
                  style={{ '--toc-level': 1 }}
                  onClick={() => app.openNote(note.noteId, note.notebookId)}
                >{noteDisplayTitle(note)}</button>
                <Show when={open() && headings().length > 0}>
                  <HeadingList nodes={headings()} level={2} />
                </Show>
              </li>
            }}</For>
          </ul>
        </Show>
        <Show when={notes().length <= 1 && headings().length === 0}>
          <p class="pane-empty">This note has no headings.</p>
        </Show>
      </Show>
    </div>
  )
}

function HeadingList(props: { nodes: HeadingNode[]; level: number }): JSX.Element {
  const app = useApp()
  return (
    <Show when={props.nodes.length > 0}>
      <ul class="toc-list" aria-label={props.level === 1 ? 'Note contents' : undefined}>
        <For each={props.nodes}>{(node) =>
          <li>
            <button
              type="button"
              classList={{ 'toc-entry': true, active: app.state.activeHeadingId === node.id }}
              style={{ '--toc-level': props.level }}
              aria-current={app.state.activeHeadingId === node.id ? 'location' : undefined}
              onClick={() => scrollToHeading(node.id, app.setActiveHeading)}
            >{node.text}</button>
            <HeadingList nodes={node.children} level={props.level + 1} />
          </li>}
        </For>
      </ul>
    </Show>
  )
}

function scrollToHeading(id: string, setActive: (id: string) => void): void {
  const target = document.getElementById(id)
  if (!target) return
  target.scrollIntoView({ behavior: 'smooth', block: 'start' })
  setActive(id)
}
