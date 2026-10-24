import { Show, createEffect, createMemo, createSignal, onCleanup, onMount, type JSX } from 'solid-js'
import type { PDFDocumentProxy, RenderTask } from 'pdfjs-dist'
import pdfWorkerURL from 'pdfjs-dist/build/pdf.worker.min.mjs?url'
import type { FileId } from '../notes/ids'
import { useApp } from '../state/appStore'
import { PageRegionSelector } from './PageRegionSelector'
import { WorkspaceIcon } from './WorkspaceIcon'
import '../reader-controls.css'
import './pdf-viewer.css'

/** The original PDF is fetched once per document. Canvas pixels are transient;
 * the selected physical page stays controlled by the reader and its memo scope. */
export function PDFDocumentView(props: {
  onCaptureRegion?: (file: File) => Promise<void> | void
  preview?: boolean
  fileId: FileId; pageNumber: number; navigation?: JSX.Element; footer?: JSX.Element; textView?: JSX.Element
  onTurnLeft?: () => void; onTurnRight?: () => void
  canTurnLeft?: boolean; canTurnRight?: boolean
}): JSX.Element {
  const app = useApp()
  const sourceFileId = createMemo(() => props.fileId)
  const [document, setDocument] = createSignal<PDFDocumentProxy>()
  const [zoom, setZoom] = createSignal(1)
  const [fitPage, setFitPage] = createSignal(false)
  const [displayedZoom, setDisplayedZoom] = createSignal(1)
  const [viewportSize, setViewportSize] = createSignal({ width: 0, height: 0 }, {
    equals: (left, right) => left.width === right.width && left.height === right.height,
  })
  const [retry, setRetry] = createSignal(0)
  const [mounted, setMounted] = createSignal(false)
  const [loading, setLoading] = createSignal(true)
  const [error, setError] = createSignal('')
  let stage!: HTMLDivElement
  let canvas!: HTMLCanvasElement
  onMount(() => {
    const measure = () => setViewportSize({ width: stage.clientWidth, height: stage.clientHeight })
    measure()
    const observer = new ResizeObserver(measure)
    observer.observe(stage)
    onCleanup(() => observer.disconnect())
    setMounted(true)
  })
  const changeZoom = (delta: number) => {
    setZoom(Math.min(3, Math.max(0.1, displayedZoom() + delta)))
    setFitPage(false)
  }

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
    const fit = fitPage()
    const size = viewportSize()
    if (!pdf || !mounted() || props.textView) return
    let disposed = false
    let task: RenderTask | undefined
    setLoading(true)
    setError('')
    void (async () => {
      const page = await pdf.getPage(number)
      if (disposed) return
      const base = page.getViewport({ scale: 1 })
      const width = size.width || 800
      const widthScale = Math.min(width / base.width, 2)
      const scale = fit && size.height > 0
        ? Math.min(Math.max(1, width - 1) / base.width, Math.max(1, size.height - 1) / base.height)
        : widthScale * magnification
      setDisplayedZoom(scale / widthScale)
      if (fit) { stage.scrollTop = 0; stage.scrollLeft = 0 }
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

    <Show when={!props.textView && loading()}><p class="pdf-viewer-status" role="status">Loading PDF page…</p></Show>
    <Show when={!props.textView && error()}><p class="pdf-viewer-status" role="alert">{error()} <button type="button" class="secondary reader-control" aria-label="Retry PDF" title="Retry" onClick={() => setRetry((value) => value + 1)}><WorkspaceIcon name="refresh" /></button></p></Show>
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
    <Show when={!props.preview && !props.textView && props.onCaptureRegion}>
      <PageRegionSelector canvas={() => canvas} sourceKey={`${props.fileId}:${props.pageNumber}`} pageNumber={props.pageNumber}
        disabled={loading() || Boolean(error())} onCapture={(file) => props.onCaptureRegion?.(file)} />
    </Show>
    </div>
    <Show when={!props.preview}><footer class="document-reader-footer pdf-controls-footer">
    {props.navigation}
    <Show when={!props.textView}><div class="pdf-viewer-zoom" role="group" aria-label="PDF zoom">
      <button type="button" class="secondary reader-control" aria-label="Zoom out" title="Zoom out" disabled={displayedZoom() <= 0.1} onClick={() => changeZoom(-0.25)}>−</button>
      <span>{Math.round(displayedZoom() * 100)}%</span>
      <button type="button" class="secondary reader-control" aria-label="Zoom in" title="Zoom in" disabled={displayedZoom() >= 3} onClick={() => changeZoom(0.25)}>+</button>
      <button type="button" class="secondary reader-control" aria-label="Fit to page" title="Fit the entire page without scrolling" aria-pressed={fitPage()} onClick={() => setFitPage(true)}><WorkspaceIcon name="expand" /></button>
    </div></Show>
        {props.footer}
    </footer></Show>
  </section>
}
