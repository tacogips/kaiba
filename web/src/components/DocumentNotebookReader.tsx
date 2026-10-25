import { Show, createEffect, createMemo, createSignal, onCleanup, onMount, type JSX } from 'solid-js'
import { readerControlPage, readerKeyAllowed, scrollReader } from '../notes/readerKeyboard'
import { documentPageMetadata, pageStepForArrow } from '../notes/documentPages'
import { noteHeadingPrefix } from '../notes/toc'
import { tagTermsFromAssignments } from '../notes/tagMatch'
import type { NoteTagAssignment } from '../notes/types'
import type { NoteId, TagId } from '../notes/ids'
import type { Note } from '../notes/types'
import { NoteEditor } from './NoteEditor'
import { MarkdownBody } from './Markdown'
import { PageRegionSelector } from './PageRegionSelector'
import { NoteFileImage } from './NoteFileImage'
import { DocumentPageTextView } from './DocumentPageTextView'
import { PDFDocumentView } from './PDFDocumentView'
import { WorkspaceIcon } from './WorkspaceIcon'
import '../reader-controls.css'

export function DocumentNotebookReader(props: {
  onCaptureRegion?: (note: Note, file: File) => Promise<void> | void
  notes: Note[]
  displayMode?: 'original' | 'text' | 'translation'
  translatedVersion?: { noteId: string; text: string; targetLanguage: string }
  onOpenTranslation?: () => void
  onOpenAnalysis?: () => void
  selectedNoteId?: NoteId
  totalCount?: number | null
  notebookTags?: NoteTagAssignment[]
  onTagClick?: (tagId: TagId) => void
  onSelect: (note: Note) => void
  onLoadMore: () => Promise<void>
}): JSX.Element {
  const [originImage, setOriginImage] = createSignal<HTMLImageElement>()
  createEffect(() => { void props.selectedNoteId; setOriginImage(undefined) })
  const [loading, setLoading] = createSignal(false)
  const [message, setMessage] = createSignal('')
  const [jump, setJump] = createSignal('')
  const ordered = createMemo(() => [...props.notes].sort((a, b) => a.noteNumber - b.noteNumber))
  const index = () => props.selectedNoteId ? ordered().findIndex((note) => note.noteId === props.selectedNoteId) : 0
  const current = () => ordered()[index()]
  const metadata = () => documentPageMetadata(current())
  createEffect(() => {
    const first = ordered()[0]
    if (!props.selectedNoteId && first) props.onSelect(first)
  })
  const binding = () => {
    const value = metadata()?.analysis.binding
    return value && value !== 'unknown' ? value : ordered().map(documentPageMetadata)
      .find((page) => page?.analysis.binding !== undefined && page.analysis.binding !== 'unknown')?.analysis.binding ?? 'unknown'
  }
  const total = () => props.totalCount ?? ordered().length
  let disposed = false
  let swipeStart: number | undefined
  let reader!: HTMLElement
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
  const step = (delta: number) => void selectIndex(index() + delta)
  const keydown = (event: KeyboardEvent) => {
    if (!readerKeyAllowed(event, reader)) return
    if (scrollReader(event, reader, false)) return
    const delta = event.ctrlKey ? readerControlPage(event) : pageStepForArrow(event.key, binding())
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

  onMount(() => {
    window.addEventListener('keydown', keydown)
    onCleanup(() => window.removeEventListener('keydown', keydown))
  })
  const navigation = () => <nav classList={{ 'document-page-navigation': true, 'right-binding': binding() === 'right' }} aria-label="Page navigation">
        <button type="button" class="secondary reader-control" aria-label="Previous page" title="Previous page (Ctrl+U)" disabled={loading() || index() === 0}
          onClick={() => step(-1)}>{binding() === 'right' ? '→' : '←'}</button>
        <button type="button" class="secondary reader-control" aria-label="Next page" title="Next page (Ctrl+D)" disabled={loading() || index() + 1 >= total()}
          onClick={() => step(1)}>{binding() === 'right' ? '←' : '→'}</button>
      </nav>

  const position = () => <div class="pdf-footer-position">
      <span aria-live="polite" aria-atomic="true">Page {metadata()?.pageNumber ?? current()?.noteNumber ?? 0} / {total()}</span>
      <form onSubmit={(event) => {
        event.preventDefault()
        const page = Number(jump())
        if (Number.isSafeInteger(page) && page > 0) void selectIndex(page - 1)
      }}>
        <label><span class="sr-only">Page number</span><input aria-label="Page number" placeholder="#" type="number" min="1" max={total()} value={jump()} onInput={(event) => setJump(event.currentTarget.value)} /></label>
        <button type="submit" class="secondary reader-control reader-page-go" aria-label="Go to page" title="Go to page" disabled={loading()}><WorkspaceIcon name="back" /></button>
      </form>
  </div>

  // A translation is tied to the source page, including while new page data is loading.
  const translation = () => props.translatedVersion?.noteId === current()?.noteId ? props.translatedVersion : undefined
  const translatedView = () => <section class="pdf-text-stage" aria-label="Translated page">
    <Show when={translation()} fallback={<div class="document-page-text-empty">
      <p>No translation for this page yet</p>
      <Show when={props.onOpenTranslation}><button type="button" class="secondary reader-control" aria-label="Translate page" title="Translate page"
        onClick={props.onOpenTranslation}><WorkspaceIcon name="ai" /></button></Show>
    </div>}>{(version) => <pre lang={version().targetLanguage}>{version().text}</pre>}</Show>
  </section>

  return <section class="document-reader" aria-label="Document pages" tabindex="0" ref={reader} aria-keyshortcuts="Control+d Control+u j k">
    <Show when={metadata()?.originMediaType !== 'application/pdf'}>
      <header class="document-reader-toolbar">{navigation()}</header>
    </Show>
    <Show when={loading() || (props.selectedNoteId && index() < 0)}><p role="status">Loading pages…</p></Show>
    <Show when={message()}><p role="alert">{message()}</p></Show>
    <Show when={metadata()?.originMediaType === 'application/pdf'}>
      <PDFDocumentView onCaptureRegion={props.onCaptureRegion ? (file) => {
        const note = current()
        if (note) return props.onCaptureRegion?.(note, file)
      } : undefined} fileId={metadata()!.originFileId} pageNumber={metadata()!.pageNumber} navigation={navigation()} footer={position()}
        textView={props.displayMode === 'translation' ? translatedView() : props.displayMode === 'text' && current() ? <DocumentPageTextView noteId={current()!.noteId} onOpenAnalysis={props.onOpenAnalysis} /> : undefined}
        onTurnLeft={() => step(pageStepForArrow('ArrowLeft', binding()))}
        onTurnRight={() => step(pageStepForArrow('ArrowRight', binding()))}
        canTurnLeft={binding() === 'right' ? index() + 1 < total() : index() > 0}
        canTurnRight={binding() === 'right' ? index() > 0 : index() + 1 < total()} />
    </Show>
    <Show when={current()} keyed>{(note) => <div data-note-id={note.noteId}>
      <Show when={documentPageMetadata(note)} fallback={
        <div class="document-page-text">
          <MarkdownBody markdown={note.bodyMarkdown} anchorPrefix={noteHeadingPrefix(note.noteId)}
            tagTerms={tagTermsFromAssignments([note.tags, props.notebookTags])} onTagClick={props.onTagClick} />
          <Show when={props.selectedNoteId === note.noteId}><NoteEditor note={note} /></Show>
        </div>
      }>{(page) =>
        <Show when={page().originMediaType !== 'application/pdf'}>
        <Show when={props.displayMode === 'translation'} fallback={<Show when={props.displayMode === 'text'} fallback={<div class="document-origin-stage"
          onPointerDown={(event) => {
            if (event.pointerType === 'mouse') return
            swipeStart = event.clientX
            event.currentTarget.setPointerCapture?.(event.pointerId)
          }}
          onPointerUp={pointerUp} onPointerCancel={() => { swipeStart = undefined }}>
          <NoteFileImage fileId={page().originFileId} alt={`Original page ${page().pageNumber}`} onLoad={setOriginImage} />
          <Show when={props.onCaptureRegion}><PageRegionSelector canvas={originImage} sourceKey={`${note.noteId}:${page().originFileId}`} pageNumber={page().pageNumber}
            disabled={!originImage()} onCapture={(file) => props.onCaptureRegion?.(note, file)} /></Show>
        </div>}><DocumentPageTextView noteId={note.noteId} onOpenAnalysis={props.onOpenAnalysis} /></Show>}>{translatedView()}</Show></Show>
      }</Show>
    </div>}</Show>
    <Show when={metadata()?.originMediaType !== 'application/pdf' && current()}>
    <footer class="document-reader-footer" aria-label="Page position">
      <span aria-live="polite" aria-atomic="true">Page {metadata()?.pageNumber ?? current()?.noteNumber ?? 0} / {total()}</span>
      <form onSubmit={(event) => {
        event.preventDefault()
        const page = Number(jump())
        if (Number.isSafeInteger(page) && page > 0) void selectIndex(page - 1)
      }}>
        <label><span class="sr-only">Page number</span><input aria-label="Page number" placeholder="#" type="number" min="1" max={total()} value={jump()} onInput={(event) => setJump(event.currentTarget.value)} /></label>
        <button type="submit" class="secondary reader-control reader-page-go" aria-label="Go to page" title="Go to page" disabled={loading()}><WorkspaceIcon name="back" /></button>
      </form>
    </footer>
    </Show>
  </section>
}
