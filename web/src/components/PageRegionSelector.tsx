import { Show, createEffect, createSignal, onCleanup, type JSX } from 'solid-js'
import { canvasRegion, capturePageRegion, type PageRegionSource } from '../notes/pageRegionCapture'
import { WorkspaceIcon } from './WorkspaceIcon'
import './page-region-selector.css'

export function PageRegionSelector(props: {
  canvas: () => PageRegionSource | undefined; sourceKey: string; pageNumber: number; disabled: boolean
  onCapture: (file: File) => Promise<void> | void
}): JSX.Element {
  const [selecting, setSelecting] = createSignal(false)
  const [busy, setBusy] = createSignal(false)
  const [message, setMessage] = createSignal('')
  const [box, setBox] = createSignal<{ x: number; y: number; width: number; height: number }>()
  let layer!: HTMLDivElement
  let trigger!: HTMLButtonElement
  let start: { x: number; y: number; pointerId: number } | undefined
  let generation = 0
  const cancel = () => { generation += 1; start = undefined; setBox(undefined); setSelecting(false); setBusy(false); setMessage('') }
  createEffect(() => { if (props.disabled) cancel() })
  createEffect(() => { void props.sourceKey; cancel() })
  onCleanup(() => { generation += 1 })
  const point = (event: PointerEvent) => {
    const canvas = props.canvas()!.getBoundingClientRect(), frame = layer.getBoundingClientRect()
    return { x: Math.max(Math.max(canvas.left, frame.left), Math.min(event.clientX, Math.min(canvas.right, frame.right))),
      y: Math.max(Math.max(canvas.top, frame.top), Math.min(event.clientY, Math.min(canvas.bottom, frame.bottom))) }
  }
  const move = (event: PointerEvent) => {
    if (!start || start.pointerId !== event.pointerId) return
    const end = point(event), bounds = layer.getBoundingClientRect()
    setBox({ x: Math.min(start.x, end.x) - bounds.left, y: Math.min(start.y, end.y) - bounds.top,
      width: Math.abs(end.x - start.x), height: Math.abs(end.y - start.y) })
  }
  const finish = async (event: PointerEvent) => {
    if (!start || start.pointerId !== event.pointerId || busy()) return
    move(event)
    const origin = start, end = point(event), canvas = props.canvas()!
    start = undefined
    if (!box() || box()!.width < 8 || box()!.height < 8) { setMessage('Drag to select a larger area.'); return }
    const current = ++generation
    const key = props.sourceKey
    setBusy(true); setMessage('Preparing selected image…')
    try {
      const file = await capturePageRegion(canvas, canvasRegion('naturalWidth' in canvas ? { width: canvas.naturalWidth, height: canvas.naturalHeight } : canvas, canvas.getBoundingClientRect(), origin, end), `page-${props.pageNumber}-selection-${Date.now()}`)
      if (current !== generation || props.sourceKey !== key) return
      // Dismiss before the footer opens and resizes the reader.
      setSelecting(false); setBox(undefined)
      await props.onCapture(file)
      if (current === generation) setMessage('Selected image attached to AI chat.')
    } catch (error) { if (current === generation) setMessage(error instanceof Error ? error.message : 'Capture failed.') }
    finally { if (current === generation) setBusy(false) }
  }
  return <>
    <button ref={trigger} type="button" class="page-region-trigger" aria-label={selecting() ? 'Cancel area selection' : 'Select area for AI'}
      title={selecting() ? 'Cancel selection (Escape)' : 'Select an area and ask AI about its image'} aria-pressed={selecting()}
      disabled={props.disabled || busy()} onClick={() => {
        if (selecting()) { cancel(); return }
        setMessage('Drag over the page to select an area. Escape cancels.'); setSelecting(true)
        queueMicrotask(() => layer?.focus())
      }}><WorkspaceIcon name={selecting() ? 'close' : 'crop'} /></button>
    <Show when={selecting()}><div ref={layer} class="page-region-layer" role="dialog" aria-label="Select page area for AI" tabindex="0"
      onKeyDown={(event) => { if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); cancel(); trigger.focus() } }}
      onPointerDown={(event) => {
        if (event.button !== 0 || busy() || start || !props.canvas()) return
        event.preventDefault(); event.stopPropagation()
        start = { ...point(event), pointerId: event.pointerId }; setBox(undefined)
        event.currentTarget.setPointerCapture?.(event.pointerId)
      }} onPointerMove={move} onPointerUp={(event) => void finish(event)} onPointerCancel={() => { start = undefined; setBox(undefined) }}>
      <Show when={box()}>{(rect) => <div class="page-region-box" style={{ left: `${rect().x}px`, top: `${rect().y}px`, width: `${rect().width}px`, height: `${rect().height}px` }} />}</Show>
    </div></Show>
    <Show when={message()}><p class="page-region-message" role="status">{message()}</p></Show>
  </>
}
