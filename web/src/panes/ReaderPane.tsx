import { For, Show, createEffect, createMemo, createSignal, onCleanup, onMount, type JSX } from 'solid-js'
import { MarkdownBody } from '../components/Markdown'
import { NoteImageCarousel } from '../components/NoteImageCarousel'
import { noteDisplayTitle, noteExportFilename } from '../notes/noteText'
import { noteImageEntries, type NoteImageEntry } from '../notes/noteImages'
import { noteHeadingPrefix } from '../notes/toc'
import { useApp } from '../state/appStore'
import type { Note } from '../notes/types'

// Center reader: the open notebook's notes as one continuous scroll. Notes lazy-
// render as they approach the viewport, a click selects (or deselects) a note
// for the right pane, and a goto-page control jumps within the notebook.

/** Notes this close to the start always render eagerly so the first paint has
 * content without waiting for the observer. */
const eagerNoteCount = 6

export function ReaderPane(): JSX.Element {
  const app = useApp()
  const [copied, setCopied] = createSignal(false)
  const [gotoDraft, setGotoDraft] = createSignal('')
  const [body, setBody] = createSignal<HTMLElement>()
  let copiedTimer: ReturnType<typeof setTimeout> | undefined
  // Set when the selection change came from a click inside the reader; the
  // scroll-to-selected effect then skips scrolling (the note is already visible).
  let selectionFromClick = false

  const notes = createMemo(() => app.notes())
  const index = createMemo(() => notes().findIndex((note) => note.noteId === app.state.noteId))

  // The heading observer feeds the Contents tab. Every mounted note's headings
  // carry per-note-prefixed ids; notes mount lazily, so a MutationObserver
  // keeps newly rendered headings observed.
  createEffect(() => {
    const container = body()
    if (!container) return
    const visible = new Map<string, boolean>()
    const observed = new Set<Element>()
    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        const id = entry.target.id
        if (id) visible.set(id, entry.isIntersecting)
      }
      const headings = [...container.querySelectorAll<HTMLElement>('[data-md-heading][id]')]
      const active = headings.find((heading) => visible.get(heading.id))
        ?? [...headings].reverse().find((heading) => heading.getBoundingClientRect().top < 0)
      if (active?.id) app.setActiveHeading(active.id)
    }, { rootMargin: '0px 0px -70% 0px', threshold: [0, 1] })
    const observeHeadings = () => {
      for (const heading of container.querySelectorAll<HTMLElement>('[data-md-heading][id]')) {
        if (observed.has(heading)) continue
        observed.add(heading)
        observer.observe(heading)
      }
    }
    const mounts = new MutationObserver(observeHeadings)
    mounts.observe(container, { childList: true, subtree: true })
    queueMicrotask(observeHeadings)
    onCleanup(() => {
      observer.disconnect()
      mounts.disconnect()
    })
  })

  // Selection arriving from outside the reader (tree, contents, search, deep
  // link) scrolls the note into view; a click inside the reader does not.
  createEffect(() => {
    const noteId = app.state.noteId
    const container = body()
    if (!noteId || !container) return
    if (selectionFromClick) {
      selectionFromClick = false
      return
    }
    queueMicrotask(() => scrollToNote(container, noteId))
  })

  const select = (note: Note) => {
    selectionFromClick = true
    if (note.noteId === app.state.noteId) app.deselectNote()
    else app.openNote(note.noteId, note.notebookId)
  }

  // Clicking the reader's empty space (between or beside notes) clears the
  // selection; clicks inside a note section are handled by the section itself
  // and never reach this as a deselect.
  const backgroundClick = (event: MouseEvent) => {
    const target = event.target as HTMLElement | null
    if (target?.closest('.reader-note, a, button, input, textarea, select')) return
    if (window.getSelection()?.toString()) return
    if (app.state.noteId) {
      selectionFromClick = true
      app.deselectNote()
    }
  }

  const gotoPage = (event: Event) => {
    event.preventDefault()
    const container = body()
    const page = Number.parseInt(gotoDraft(), 10)
    if (!container || Number.isNaN(page)) return
    const all = notes()
    const target = all.find((note) => note.noteNumber === page) ?? all[page - 1]
    if (!target) return
    app.openNote(target.noteId, target.notebookId)
    queueMicrotask(() => scrollToNote(container, target.noteId))
  }

  const copy = async () => {
    const note = app.state.note
    if (!note) return
    try {
      await navigator.clipboard.writeText(note.bodyMarkdown)
      setCopied(true)
      if (copiedTimer) clearTimeout(copiedTimer)
      copiedTimer = setTimeout(() => setCopied(false), 1500)
    } catch {
      app.setMessage('Could not copy to the clipboard.')
    }
  }

  const download = () => {
    const note = app.state.note
    if (!note) return
    const blob = new Blob([note.bodyMarkdown], { type: 'text/markdown;charset=utf-8' })
    const url = URL.createObjectURL(blob)
    const anchor = document.createElement('a')
    anchor.href = url
    anchor.download = noteExportFilename(noteDisplayTitle(note))
    anchor.click()
    URL.revokeObjectURL(url)
  }

  onCleanup(() => { if (copiedTimer) clearTimeout(copiedTimer) })

  return (
    <main class="reader" id="main-content" tabindex="-1">
      <Show when={app.state.noteLoading && !app.state.notebookId && notes().length === 0}>
        <div class="loading-state"><span class="loader" />Loading note…</div>
      </Show>
      <Show
        when={app.state.notebookId || notes().length > 0}
        fallback={
          <Show when={!app.state.noteLoading}>
            <div class="empty-state">
              <span aria-hidden="true">◇</span>
              <strong>No notebook open</strong>
              <p>Pick a notebook or note in the Files pane to start reading.</p>
            </div>
          </Show>
        }
      >
        <header class="reader-head">
          <div class="reader-title">
            <span class="eyebrow">{app.notebook()?.title ?? 'NOTEBOOK'}</span>
            <h1>{app.state.note ? noteDisplayTitle(app.state.note) : app.notebook()?.title ?? 'Notebook'}</h1>
          </div>
          <div class="reader-actions">
            <Show when={app.state.note?.readOnly}><span class="note-readonly-badge">Read-only</span></Show>
            <form class="reader-goto" onSubmit={gotoPage}>
              <label>
                <span class="sr-only">Go to page</span>
                <input
                  type="number"
                  min="1"
                  inputmode="numeric"
                  placeholder="p."
                  value={gotoDraft()}
                  onInput={(event) => setGotoDraft(event.currentTarget.value)}
                />
              </label>
              <button type="submit" class="secondary">Go</button>
            </form>
            <span class="reader-position">{pageLabel(index(), notes().length)}</span>
            <Show when={app.state.note}>
              <button type="button" class="secondary" onClick={() => void copy()}>
                {copied() ? 'Copied' : 'Copy'}
              </button>
              <button type="button" class="secondary" onClick={download}>Download</button>
              <button type="button" class="secondary" onClick={app.deselectNote}>Deselect</button>
            </Show>
          </div>
        </header>
        <article class="reader-body" ref={setBody} onClick={backgroundClick}>
          <Show when={notes().length === 0}>
            <p class="pane-empty">This notebook has no notes.</p>
          </Show>
          <For each={notes()}>{(note, noteIndex) => (
            <NoteSection
              note={note}
              page={note.noteNumber ?? noteIndex() + 1}
              selected={note.noteId === app.state.noteId}
              eager={noteIndex() < eagerNoteCount}
              onSelect={() => select(note)}
            />
          )}</For>
          <LoadMoreSentinel />
        </article>
      </Show>
    </main>
  )
}

/** One note in the continuous scroll. The section element always exists (so
 * goto/scroll targets resolve), but the markdown mounts only once the section
 * nears the viewport. */
function NoteSection(props: {
  note: Note
  page: number
  selected: boolean
  eager: boolean
  onSelect: () => void
}): JSX.Element {
  const app = useApp()
  const [mounted, setMounted] = createSignal(props.eager)
  const [images, setImages] = createSignal<NoteImageEntry[]>([])
  const [imagesOpen, setImagesOpen] = createSignal(false)
  let imagesFetched = false
  let element: HTMLElement | undefined

  onMount(() => {
    if (mounted() || !element) return
    const observer = new IntersectionObserver((entries) => {
      if (entries.some((entry) => entry.isIntersecting)) {
        setMounted(true)
        observer.disconnect()
      }
    }, { rootMargin: '1200px 0px' })
    observer.observe(element)
    onCleanup(() => observer.disconnect())
  })

  // Attachment discovery waits for the section to mount so a long notebook
  // does not fire hundreds of queries up front. An older server without the
  // noteFiles field simply leaves the note without an image arrow.
  createEffect(() => {
    if (!mounted() || imagesFetched) return
    imagesFetched = true
    void app.client.noteFiles(props.note.noteId)
      .then((attachments) => setImages(noteImageEntries(attachments)))
      .catch(() => setImages([]))
  })

  const click = (event: MouseEvent) => {
    const target = event.target as HTMLElement | null
    // Links, buttons, text selection, and the image viewer inside the note
    // must not toggle its selection.
    if (target?.closest('a, button, input, textarea, select, .note-carousel')) return
    if (window.getSelection()?.toString()) return
    props.onSelect()
  }

  return (
    <section
      ref={element}
      classList={{ 'reader-note': true, selected: props.selected, 'has-images': images().length > 0 }}
      data-note-id={props.note.noteId}
      aria-current={props.selected ? 'true' : undefined}
      onClick={click}
    >
      <header class="reader-note-head">
        <span class="reader-note-page">p.{props.page}</span>
        <span class="reader-note-title">{noteDisplayTitle(props.note)}</span>
        <Show when={props.selected}><span class="reader-note-selected">Selected</span></Show>
      </header>
      <Show when={images().length > 0 && !imagesOpen()}>
        <button
          type="button"
          class="note-images-arrow"
          aria-label={`Show ${images().length} source image${images().length === 1 ? '' : 's'}`}
          title="Show source images"
          onClick={() => setImagesOpen(true)}
        >‹</button>
      </Show>
      <Show when={mounted()} fallback={<div class="reader-note-placeholder" aria-hidden="true" />}>
        <Show
          when={!imagesOpen()}
          fallback={<NoteImageCarousel entries={images()} onClose={() => setImagesOpen(false)} />}
        >
          <MarkdownBody markdown={props.note.bodyMarkdown} anchorPrefix={noteHeadingPrefix(props.note.noteId)} />
        </Show>
      </Show>
    </section>
  )
}

/** Fetches the next page of notes once the end of the scroll comes near. */
function LoadMoreSentinel(): JSX.Element {
  const app = useApp()
  let element: HTMLElement | undefined
  onMount(() => {
    if (!element) return
    const observer = new IntersectionObserver((entries) => {
      if (!entries.some((entry) => entry.isIntersecting)) return
      const notebookId = app.state.notebookId
      if (notebookId) void app.loadMoreNotes(notebookId)
    }, { rootMargin: '800px 0px' })
    observer.observe(element)
    onCleanup(() => observer.disconnect())
  })
  return <div ref={(el) => { element = el }} class="reader-load-more" aria-hidden="true" />
}

function scrollToNote(container: HTMLElement, noteId: string): void {
  const target = container.querySelector<HTMLElement>(`[data-note-id="${cssEscape(noteId)}"]`)
  if (!target) return
  const containerBox = container.getBoundingClientRect()
  const box = target.getBoundingClientRect()
  const alreadyVisible = box.top >= containerBox.top - 4 && box.top < containerBox.bottom - 80
  if (!alreadyVisible) target.scrollIntoView({ behavior: 'smooth', block: 'start' })
}

function cssEscape(value: string): string {
  return typeof CSS !== 'undefined' && CSS.escape ? CSS.escape(value) : value.replace(/"/g, '\\"')
}

function pageLabel(index: number, total: number): string {
  if (total === 0) return ''
  if (index < 0) return `${total} page${total === 1 ? '' : 's'}`
  return `${index + 1} / ${total}`
}
