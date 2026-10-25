import { For, Show, createSignal, onCleanup, onMount } from 'solid-js'
import { Portal } from 'solid-js/web'
import type { NoteGraphQLClient } from '../notes/client'
import type { Note, Notebook } from '../notes/types'
import type { NoteId, NotebookId } from '../notes/ids'
import { NoteDestinationLink } from './NoteDestinationLink'
import { WorkspaceIcon } from './WorkspaceIcon'
import { usePopoverDismissal } from './usePopoverDismissal'
import '../reader-controls.css'

const pageSize = 50

/** Tag occurrences use the central reader navigation so jumps can be restored. */
export function TagNotesPopup(props: {
  client: NoteGraphQLClient
  tagName: string
  notebooks: Notebook[]
  onOpenNote: (noteId: NoteId, notebookId: NotebookId) => void
  onClose: () => void
}) {
  const [notes, setNotes] = createSignal<Note[]>([])
  const [loading, setLoading] = createSignal(false)
  const [error, setError] = createSignal('')
  const [hasMore, setHasMore] = createSignal(false)
  let disposed = false
  let closeButton!: HTMLButtonElement
  let dialog!: HTMLElement
  usePopoverDismissal({ isOpen: () => true, canDismiss: () => true,
    contains: (target) => dialog.contains(target), onDismiss: () => props.onClose(),
    dismissOutside: false, captureEscape: false })
  const load = async () => {
    if (loading()) return
    setLoading(true)
    setError('')
    try {
      const page = await props.client.notesByTag(props.tagName, notes().length, pageSize)
      if (disposed) return
      setNotes((existing) => [...existing, ...page])
      setHasMore(page.length === pageSize)
    } catch (failure) {
      if (!disposed) setError(failure instanceof Error ? failure.message : 'Tagged notes could not be loaded')
    } finally { if (!disposed) setLoading(false) }
  }
  onMount(() => {
    const previousFocus = document.activeElement as HTMLElement | null
    closeButton.focus()
    void load()
    onCleanup(() => { if (previousFocus?.isConnected) previousFocus.focus() })
  })
  onCleanup(() => { disposed = true })
  return <Portal><div class="note-modal-backdrop" role="presentation" onClick={(event) => {
    if (event.target === event.currentTarget) props.onClose()
  }}>
    <section ref={dialog} class="note-modal note-search tag-notes-popup" role="dialog" aria-modal="true" aria-label={`Notes tagged ${props.tagName}`}
      onKeyDown={(event) => {
        if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); props.onClose() }
        if (event.key !== 'Tab') return
        const controls = [...dialog.querySelectorAll<HTMLButtonElement>('button:not(:disabled)')]
        const first = controls[0], last = controls[controls.length - 1]
        if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus() }
        else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus() }
      }}>
      <header><h2 title={props.tagName}>{props.tagName}</h2>
        <button ref={closeButton} type="button" class="workspace-icon" aria-label="Close tagged notes" title="Close" onClick={props.onClose}><WorkspaceIcon name="close" /></button>
      </header>
      <Show when={loading()}><p role="status">Loading tagged notes…</p></Show>
      <Show when={error()}><p role="alert">{error()} <button type="button" class="workspace-icon" aria-label="Retry tagged notes" title="Retry" onClick={() => void load()}><WorkspaceIcon name="refresh" /></button></p></Show>
      <Show when={!loading() && !error() && notes().length === 0}><p>No notes or pages with this tag.</p></Show>
      <ul class="note-search-results link-list" aria-label="Tagged notes">
        <For each={notes()}>{(note) => <li><NoteDestinationLink note={note}
          relationship={`Tag: ${props.tagName}`} previewMount={dialog}
          app={{ client: props.client, state: { get notebooks() { return props.notebooks } },
            openNote: (noteId, notebookId) => { props.onOpenNote(noteId, notebookId ?? note.notebookId); props.onClose() } }}
        /></li>}</For>
      </ul>
      <Show when={hasMore() && !error()}><button type="button" class="secondary" disabled={loading()} onClick={() => void load()}>Load more</button></Show>
    </section>
  </div></Portal>
}
