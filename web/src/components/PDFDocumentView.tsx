import { Show, createEffect, createMemo, createSignal, onCleanup, onMount, type JSX } from 'solid-js'
import type { PDFDocumentProxy, RenderTask } from 'pdfjs-dist'
import pdfWorkerURL from 'pdfjs-dist/build/pdf.worker.min.mjs?url'
import type { FileId } from '../notes/ids'
import { useApp } from '../state/appStore'
import { WorkspaceIcon } from './WorkspaceIcon'
import '../reader-controls.css'

/** The original PDF is fetched once per document. Canvas pixels are transient;
 * the selected physical page stays controlled by the reader and its memo scope. */
export function PDFDocumentView(props: {
  preview?: boolean
  fileId: FileId; pageNumber: number; navigation?: JSX.Element; footer?: JSX.Element; textView?: JSX.Element
  onTurnLeft?: () => void; onTurnRight?: () => void
  canTurnLeft?: boolean; canTurnRight?: boolean
}): JSX.Element {
  const app = useApp()
  const sourceFileId = createMemo(() => props.fileId)
  const [document, setDocument] = createSignal<PDFDocumentProxy>()
  const [zoom, setZoom] = createSignal(1)
  const [retry, setRetry] = createSignal(0)
  const [mounted, setMounted] = createSignal(false)
  const [loading, setLoading] = createSignal(true)
  const [error, setError] = createSignal('')
  let stage!: HTMLDivElement
  let canvas!: HTMLCanvasElement
  onMount(() => setMounted(true))

  createEffect(() => {
    const id = sourceFileId()
    retry()
    let disposed = false
    let destroy: (() => Promise<void>) | undefined
    setDocument(undefined)
    setError('')
    setLoading(true)
    void (async () => {
      const pdfjs = await import('pdfjs-dist')
      if (disposed) return
      pdfjs.GlobalWorkerOptions.workerSrc = pdfWorkerURL
      const blob = await app.client.noteFileBlob(id)
      if (disposed) return
      if (blob.type !== 'application/pdf') throw new Error('The original file is not a PDF')
      const task = pdfjs.getDocument({ data: new Uint8Array(await blob.arrayBuffer()) })
      destroy = () => task.destroy()
      if (disposed) { await destroy(); return }
      const pdf = await task.promise
      if (!disposed) setDocument(pdf)
    })().catch((failure: unknown) => {
      if (!disposed) { setError(failure instanceof Error ? failure.message : 'PDF could not be loaded'); setLoading(false) }
    })
    onCleanup(() => { disposed = true; void destroy?.().catch(() => {}) })
  })

  createEffect(() => {
    const pdf = document()
    const number = props.pageNumber
    const magnification = zoom()
    if (!pdf || !mounted() || props.textView) return
    let disposed = false
    let task: RenderTask | undefined
    setLoading(true)
    setError('')
    void (async () => {
      const page = await pdf.getPage(number)
      if (disposed) return
      const base = page.getViewport({ scale: 1 })
      const width = stage.clientWidth || 800
      const scale = Math.min(width / base.width, 2) * magnification
      const viewport = page.getViewport({ scale })
      const ratio = Math.min(window.devicePixelRatio || 1, 2)
      canvas.width = Math.ceil(viewport.width * ratio)
      canvas.height = Math.ceil(viewport.height * ratio)
      canvas.style.width = `${viewport.width}px`
      canvas.style.height = `${viewport.height}px`
      task = page.render({ canvas, viewport, transform: ratio === 1 ? undefined : [ratio, 0, 0, ratio, 0, 0] })
      await task.promise
      if (!disposed) setLoading(false)
    })().catch((failure: unknown) => {
      if (!disposed) { setError(failure instanceof Error ? failure.message : 'PDF page could not be displayed'); setLoading(false) }
    })
    onCleanup(() => { disposed = true; task?.cancel() })
  })

  return <section class="pdf-viewer" aria-label={props.preview ? "PDF page preview" : "PDF viewer"} aria-busy={!props.textView && loading()}>

    <Show when={!props.textView && loading()}><p role="status">Loading PDF page…</p></Show>
    <Show when={!props.textView && error()}><p role="alert">{error()} <button type="button" class="secondary reader-control" aria-label="Retry PDF" title="Retry" onClick={() => setRetry((value) => value + 1)}><WorkspaceIcon name="refresh" /></button></p></Show>
    <div class="pdf-viewer-frame">
    <Show when={props.textView}>{props.textView}</Show>
    <div class="pdf-viewer-stage" ref={stage} hidden={Boolean(props.textView)}>
      <canvas ref={canvas} role="img" aria-label={`PDF page ${props.pageNumber}`} style={{ visibility: loading() || error() ? 'hidden' : 'visible' }} />
    </div>
    <Show when={props.onTurnLeft}>
      <button type="button" class="pdf-page-edge pdf-page-edge-left" aria-label="Turn page left" title="Turn page left"
        disabled={!props.canTurnLeft} onClick={props.onTurnLeft}>‹</button>
    </Show>
    <Show when={props.onTurnRight}>
      <button type="button" class="pdf-page-edge pdf-page-edge-right" aria-label="Turn page right" title="Turn page right"
        disabled={!props.canTurnRight} onClick={props.onTurnRight}>›</button>
    </Show>
    </div>
    <Show when={!props.preview}><footer class="document-reader-footer pdf-controls-footer">
    {props.navigation}
    <Show when={!props.textView}><div class="pdf-viewer-zoom" role="group" aria-label="PDF zoom">
      <button type="button" class="secondary reader-control" aria-label="Zoom out" title="Zoom out" disabled={zoom() <= 0.5} onClick={() => setZoom(Math.max(0.5, zoom() - 0.25))}>−</button>
      <span>{Math.round(zoom() * 100)}%</span>
      <button type="button" class="secondary reader-control" aria-label="Zoom in" title="Zoom in" disabled={zoom() >= 3} onClick={() => setZoom(Math.min(3, zoom() + 0.25))}>+</button>
      <button type="button" class="secondary reader-control" aria-label="Fit width" title="Fit width" onClick={() => setZoom(1)}><WorkspaceIcon name="expand" /></button>
    </div></Show>
        {props.footer}
    </footer></Show>
  </section>
}
