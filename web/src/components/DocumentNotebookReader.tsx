import { Show, createMemo, createSignal, onCleanup, type JSX } from 'solid-js'
import { documentPageMetadata, pageStepForArrow } from '../notes/documentPages'
import { noteHeadingPrefix } from '../notes/toc'
import { tagTermsFromAssignments } from '../notes/tagMatch'
import type { NoteTagAssignment } from '../notes/types'
import type { NoteId, TagId } from '../notes/ids'
import type { Note } from '../notes/types'
import { NoteEditor } from './NoteEditor'
import { MarkdownBody } from './Markdown'
import { NoteFileImage } from './NoteFileImage'

export function DocumentNotebookReader(props: {
  notes: Note[]
  selectedNoteId?: NoteId
  totalCount?: number | null
  notebookTags?: NoteTagAssignment[]
  onTagClick?: (tagId: TagId) => void
  onSelect: (note: Note) => void
  onLoadMore: () => Promise<void>
  onRecognize?: (note: Note) => Promise<void>
}): JSX.Element {
  const [loading, setLoading] = createSignal(false)
  const [message, setMessage] = createSignal('')
  const [jump, setJump] = createSignal('')
  const [ocrBusy, setOCRBusy] = createSignal(false)
  const [ocrError, setOCRError] = createSignal<{ noteId: NoteId; message: string }>()
  const ordered = createMemo(() => [...props.notes].sort((a, b) => a.noteNumber - b.noteNumber))
  const index = () => Math.max(0, ordered().findIndex((note) => note.noteId === props.selectedNoteId))
  const current = () => ordered()[index()]
  const metadata = () => documentPageMetadata(current())
  const binding = () => {
    const value = metadata()?.analysis.binding
    return value && value !== 'unknown' ? value : ordered().map(documentPageMetadata)
      .find((page) => page?.analysis.binding !== undefined && page.analysis.binding !== 'unknown')?.analysis.binding ?? 'unknown'
  }
  const total = () => props.totalCount ?? ordered().length
  let disposed = false
  let swipeStart: number | undefined
  onCleanup(() => { disposed = true })

  const selectIndex = async (targetIndex: number) => {
    if (loading() || targetIndex < 0 || targetIndex >= total()) return
    const selected = props.selectedNoteId
    setLoading(true)
    setMessage('')
    try {
      while (targetIndex >= ordered().length) {
        const before = ordered().length
        await props.onLoadMore()
        if (disposed || props.selectedNoteId !== selected) return
        if (ordered().length <= before) {
          setMessage('Could not load that page. Try again.')
          return
        }
      }
      const target = ordered()[targetIndex]
      if (target && !disposed) props.onSelect(target)
    } catch {
      if (!disposed) setMessage('Could not load that page. Try again.')
    } finally { if (!disposed) setLoading(false) }
  }
  const recognize = async () => {
    const note = current()
    if (!note || !props.onRecognize || ocrBusy()) return
    setOCRBusy(true)
    setOCRError(undefined)
    try { await props.onRecognize(note) }
    catch (error) {
      if (!disposed) setOCRError({ noteId: note.noteId, message: error instanceof Error ? error.message : 'OCR failed. Try again.' })
    } finally { if (!disposed) setOCRBusy(false) }
  }
  const step = (delta: number) => void selectIndex(index() + delta)
  const keydown = (event: KeyboardEvent) => {
    if (event.target instanceof Element && event.target.closest('input, textarea, select, [contenteditable="true"]')) return
    const delta = pageStepForArrow(event.key, binding())
    if (delta) { event.preventDefault(); step(delta) }
  }
  const pointerUp = (event: PointerEvent) => {
    if (swipeStart === undefined) return
    const difference = event.clientX - swipeStart
    swipeStart = undefined
    if (Math.abs(difference) < 60) return
    const key = difference > 0 ? 'ArrowLeft' : 'ArrowRight'
    step(pageStepForArrow(key, binding()))
  }

  return <section class="document-reader" aria-label="Document pages" tabindex="0" onKeyDown={keydown}>
    <div class="document-reader-toolbar">
      <nav classList={{ 'document-page-navigation': true, 'right-binding': binding() === 'right' }} aria-label="Page navigation">
        <button type="button" class="secondary" aria-label="Previous page" disabled={loading() || index() === 0}
          onClick={() => step(-1)}>{binding() === 'right' ? 'Previous →' : '← Previous'}</button>
        <span aria-live="polite">Page {metadata()?.pageNumber ?? current()?.noteNumber ?? 0} / {total()}</span>
        <button type="button" class="secondary" aria-label="Next page" disabled={loading() || index() + 1 >= total()}
          onClick={() => step(1)}>{binding() === 'right' ? '← Next' : 'Next →'}</button>
      </nav>
      <form onSubmit={(event) => {
        event.preventDefault()
        const page = Number(jump())
        if (Number.isSafeInteger(page) && page > 0) void selectIndex(page - 1)
      }}>
        <label>Page <input type="number" min="1" max={total()} value={jump()} onInput={(event) => setJump(event.currentTarget.value)} /></label>
        <button type="submit" class="secondary" disabled={loading()}>Go to page</button>
      </form>
    </div>
    <Show when={metadata()?.ocrState === 'pending'}>
      <Show when={props.onRecognize}>
        <button type="button" class="secondary" disabled={ocrBusy() || current()?.readOnly} onClick={() => void recognize()}>
          {ocrBusy() ? 'Making page searchable...' : 'Make page searchable'}
        </button>
      </Show>
      <p class="document-ocr-pending">Text on this page is not searchable yet.</p>
    </Show>
    <Show when={ocrError()?.noteId === current()?.noteId}><p role="alert">{ocrError()?.message}</p></Show>
    <Show when={loading()}><p role="status">Loading pages…</p></Show>
    <Show when={message()}><p role="alert">{message()}</p></Show>
    <Show when={current()} keyed>{(note) => <div data-note-id={note.noteId}>
      <Show when={documentPageMetadata(note)} fallback={
        <div class="document-page-text">
          <MarkdownBody markdown={note.bodyMarkdown} anchorPrefix={noteHeadingPrefix(note.noteId)}
            tagTerms={tagTermsFromAssignments([note.tags, props.notebookTags])} onTagClick={props.onTagClick} />
          <Show when={props.selectedNoteId === note.noteId}><NoteEditor note={note} /></Show>
        </div>
      }>{(page) =>
        <div class="document-origin-stage"
          onPointerDown={(event) => {
            if (event.pointerType === 'mouse') return
            swipeStart = event.clientX
            event.currentTarget.setPointerCapture?.(event.pointerId)
          }}
          onPointerUp={pointerUp} onPointerCancel={() => { swipeStart = undefined }}>
          <NoteFileImage fileId={page().originFileId} alt={`Original page ${page().pageNumber}`} />
        </div>
      }</Show>
    </div>}</Show>
  </section>
}
