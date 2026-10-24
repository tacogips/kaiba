import { Show, createSignal, createUniqueId, onCleanup, type JSX } from 'solid-js'
import { Portal } from 'solid-js/web'
import { documentPageMetadata } from '../notes/documentPages'
import { noteDisplayTitle } from '../notes/noteText'
import type { Note } from '../notes/types'
import { errorMessage, useApp, type AppStore } from '../state/appStore'
import { MarkdownBody } from './Markdown'
import { NoteFileImage } from './NoteFileImage'
import { PDFDocumentView } from './PDFDocumentView'
import { WorkspaceIcon } from './WorkspaceIcon'
import './link-preview.css'

/** All connection lists share the same destination and non-navigating preview. */
export function NoteDestinationLink(props: { note: Note; relationship?: string; app?: AppStore }): JSX.Element {
  const app = props.app ?? useApp()
  const [open, setOpen] = createSignal(false)
  const [loading, setLoading] = createSignal(false)
  const [error, setError] = createSignal('')
  const [text, setText] = createSignal('')
  const [original, setOriginal] = createSignal(false)
  const [detail, setDetail] = createSignal<Note>()
  const [position, setPosition] = createSignal({ left: 8, top: 8 })
  const id = createUniqueId()
  let row!: HTMLDivElement
  let popup: HTMLElement | undefined
  let timer: ReturnType<typeof setTimeout> | undefined
  let generation = 0
  const notebookTitle = () => app.state.notebooks?.find((book) => book.notebookId === props.note.notebookId)?.title ?? 'Notebook'
  const destination = () => `${notebookTitle()} · ${documentPageMetadata(detail() ?? props.note) ? 'Page' : 'Note'} ${props.note.noteNumber}`
  const cancelTimer = () => { if (timer) clearTimeout(timer); timer = undefined }
  const close = () => { cancelTimer(); generation += 1; setOpen(false); setDetail(undefined); setOriginal(false) }
  const place = () => {
    const bounds = row.getBoundingClientRect()
    const width = Math.min(400, window.innerWidth - 16)
    const left = bounds.left >= width + 16 ? bounds.left - width - 8 : Math.min(bounds.left, window.innerWidth - width - 8)
    setPosition({ left: Math.max(8, left), top: Math.max(8, Math.min(bounds.top, window.innerHeight - Math.min(500, window.innerHeight - 16) - 8)) })
  }
  const show = async () => {
    cancelTimer()
    if (open()) return
    const current = ++generation
    place(); setOpen(true); setLoading(true); setError(''); setText(''); setOriginal(false)
    try {
      const note = props.note.metaJSON === undefined ? await app.client.note(props.note.noteId) : props.note
      if (current !== generation) return
      setDetail(note)
      const content = documentPageMetadata(note) ? (await app.client.documentPageText(note.noteId)).text : note.bodyMarkdown
      if (current === generation) setText(content.slice(0, 12000))
    } catch (failure) {
      if (current === generation) setError(errorMessage(failure))
    } finally { if (current === generation) setLoading(false) }
  }
  const schedule = () => { cancelTimer(); timer = setTimeout(() => void show(), 220) }
  const leave = () => { cancelTimer(); timer = setTimeout(() => {
    if (!row.contains(document.activeElement) && !popup?.contains(document.activeElement)) close()
  }, 160) }
  const openDestination = () => { close(); app.openNote(props.note.noteId, props.note.notebookId) }
  const escape = (event: KeyboardEvent) => { if (event.key === 'Escape') { event.stopPropagation(); close() } }
  const dismiss = (event: PointerEvent) => {
    if (open() && event.target instanceof Node && !row.contains(event.target) && !popup?.contains(event.target)) close()
  }
  const reposition = () => { if (open()) place() }
  document.addEventListener('pointerdown', dismiss)
  window.addEventListener('resize', reposition)
  onCleanup(() => { close(); document.removeEventListener('pointerdown', dismiss); window.removeEventListener('resize', reposition) })
  return <div ref={row} class="note-destination" onPointerEnter={schedule} onPointerLeave={leave} onKeyDown={escape}
    onFocusOut={(event) => { if (!(event.relatedTarget instanceof Node) || (!row.contains(event.relatedTarget) && !popup?.contains(event.relatedTarget))) leave() }}>
    <button type="button" class="note-destination-open" onClick={openDestination} onFocus={() => void show()}>
      <strong>{noteDisplayTitle(props.note)}</strong>
      <span class="link-destination">{destination()}</span>
      <Show when={props.relationship}><span class="link-meta link-relationship">{props.relationship}</span></Show>
    </button>
    <button type="button" class="workspace-icon note-preview-trigger" aria-label={`Preview ${noteDisplayTitle(props.note)}`}
      title="Preview destination without leaving this page" aria-haspopup="dialog" aria-expanded={open()} aria-controls={open() ? id : undefined}
      onClick={() => open() ? close() : void show()}><WorkspaceIcon name="preview" /></button>
    <Show when={open()}><Portal>
      <section ref={popup} id={id} class="note-link-preview" role="dialog" aria-label={`Preview: ${noteDisplayTitle(props.note)}`}
        style={{ left: `${position().left}px`, top: `${position().top}px` }}
        onPointerEnter={cancelTimer} onPointerLeave={leave} onKeyDown={escape}
        onFocusOut={(event) => { if (!(event.relatedTarget instanceof Node) || (!row.contains(event.relatedTarget) && !popup?.contains(event.relatedTarget))) leave() }}>
        <header><div><strong>{noteDisplayTitle(props.note)}</strong><p>{destination()}</p></div>
          <button type="button" class="workspace-icon" aria-label="Close link preview" title="Close preview" onClick={close}><WorkspaceIcon name="close" /></button>
        </header>
        <Show when={props.relationship}><p class="link-preview-reason">{props.relationship}</p></Show>
        <div class="note-link-preview-content">
          <Show when={loading()}><p role="status">Loading preview…</p></Show>
          <Show when={error()}><p role="alert">{error()}</p></Show>
          <Show when={!loading() && !error()}>
            <Show when={documentPageMetadata(detail())} fallback={<MarkdownBody markdown={text() || 'This note is empty.'} />}>
              <Show when={!original()} fallback={documentPageMetadata(detail())?.originMediaType === 'application/pdf'
                ? <PDFDocumentView preview fileId={documentPageMetadata(detail())!.originFileId} pageNumber={documentPageMetadata(detail())!.pageNumber} />
                : <NoteFileImage fileId={documentPageMetadata(detail())!.originFileId} alt={`Original page ${props.note.noteNumber}`} />}>
                <pre>{text() || 'No extracted text for this page yet. Preview the original page below.'}</pre>
              </Show>
            </Show>
          </Show>
        </div>
        <footer>
          <Show when={documentPageMetadata(detail())}><button type="button" class="secondary" title={original() ? 'Show extracted text' : 'Preview the original page'} onClick={() => setOriginal(!original())}>{original() ? 'Text' : 'Original page'}</button></Show>
          <button type="button" onClick={openDestination}>Open {documentPageMetadata(detail() ?? props.note) ? 'page' : 'note'}</button>
        </footer>
      </section>
    </Portal></Show>
  </div>
}
