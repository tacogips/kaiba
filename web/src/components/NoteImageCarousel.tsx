import { Show, createEffect, createSignal, onCleanup, onMount, type JSX } from 'solid-js'
import { useApp } from '../state/appStore'
import { steppedImageIndex, type NoteImageEntry } from '../notes/noteImages'

// Page-flip image viewer for a note's source images. Opening flips the note
// left; stepping back (the right-edge arrow, a right swipe, or ArrowRight)
// flips toward the note text and closes once it steps past the first image.
// Bytes are fetched with the authenticated client and shown via object URLs,
// since an <img src> cannot carry the bearer header.

const swipeThresholdPx = 60

export function NoteImageCarousel(props: { entries: NoteImageEntry[]; onClose: () => void }): JSX.Element {
  const app = useApp()
  const [index, setIndex] = createSignal(0)
  const [urls, setUrls] = createSignal<Record<string, string>>({})
  const [failed, setFailed] = createSignal<Record<string, boolean>>({})
  const pending = new Set<string>()
  let root: HTMLDivElement | undefined
  let swipeStartX: number | undefined

  const entry = () => props.entries[index()]

  const load = (target?: NoteImageEntry) => {
    if (!target || pending.has(target.fileId) || urls()[target.fileId] || failed()[target.fileId]) return
    pending.add(target.fileId)
    void app.client.noteFileBlob(target.fileId)
      .then((blob) => setUrls((current) => ({ ...current, [target.fileId]: URL.createObjectURL(blob) })))
      .catch(() => setFailed((current) => ({ ...current, [target.fileId]: true })))
      .finally(() => pending.delete(target.fileId))
  }

  // The shown image loads first; its neighbors prefetch so flipping is instant.
  createEffect(() => {
    load(props.entries[index()])
    load(props.entries[index() + 1])
    load(props.entries[index() - 1])
  })

  onCleanup(() => {
    for (const url of Object.values(urls())) URL.revokeObjectURL(url)
  })

  onMount(() => root?.focus())

  const step = (delta: number) => {
    const next = steppedImageIndex(index(), delta, props.entries.length)
    if (next === null) props.onClose()
    else setIndex(next)
  }

  const keydown = (event: KeyboardEvent) => {
    if (event.key === 'ArrowLeft') { event.preventDefault(); step(1) }
    else if (event.key === 'ArrowRight') { event.preventDefault(); step(-1) }
    else if (event.key === 'Escape') { event.preventDefault(); props.onClose() }
  }

  const pointerDown = (event: PointerEvent) => {
    swipeStartX = event.clientX
    ;(event.currentTarget as HTMLElement).setPointerCapture(event.pointerId)
  }

  const pointerUp = (event: PointerEvent) => {
    if (swipeStartX === undefined) return
    const dx = event.clientX - swipeStartX
    swipeStartX = undefined
    if (dx >= swipeThresholdPx) step(-1)
    else if (dx <= -swipeThresholdPx) step(1)
  }

  return (
    <div
      ref={root}
      class="note-carousel"
      role="group"
      aria-label="Source images of this note"
      tabindex="-1"
      onKeyDown={keydown}
    >
      <button
        type="button"
        class="note-carousel-arrow prev"
        aria-label="Next image"
        disabled={index() >= props.entries.length - 1}
        onClick={() => step(1)}
      >‹</button>
      <div
        class="note-carousel-stage"
        onPointerDown={pointerDown}
        onPointerUp={pointerUp}
        onPointerCancel={() => { swipeStartX = undefined }}
      >
        <Show when={entry()} keyed>{(current) =>
          <Show
            when={urls()[current.fileId]}
            fallback={
              <div class="note-carousel-loading">
                {failed()[current.fileId] ? 'This image could not be loaded.' : 'Loading image…'}
              </div>
            }
          >{(url) => <img src={url()} alt={current.label} draggable={false} />}</Show>
        }</Show>
      </div>
      <button
        type="button"
        class="note-carousel-arrow next"
        aria-label="Back toward the note text"
        onClick={() => step(-1)}
      >›</button>
      <footer class="note-carousel-bar">
        <span class="note-carousel-label">{entry()?.label ?? ''}</span>
        <span class="note-carousel-count">{index() + 1} / {props.entries.length}</span>
        <button type="button" class="secondary" onClick={props.onClose}>Back to text</button>
      </footer>
    </div>
  )
}
