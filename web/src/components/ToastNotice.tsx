import { Show, createEffect, onCleanup, type JSX } from 'solid-js'
import { WorkspaceIcon } from './WorkspaceIcon'
import './toast-notice.css'

/** Timed notifications keep a manual close action and pause while being read. */
export function ToastNotice(props: { message: string; severity?: 'info' | 'error'; onDismiss: () => void; onRetry?: () => void; duration?: number }): JSX.Element {
  let root!: HTMLDivElement
  let timer: ReturnType<typeof setTimeout> | undefined
  let remaining = 8000
  let started = 0
  let hovered = false
  let focused = false
  const clear = () => { clearTimeout(timer); timer = undefined }
  const pause = () => {
    if (timer !== undefined) remaining = Math.max(0, remaining - (Date.now() - started))
    clear()
  }
  const resume = () => {
    if (hovered || focused || timer !== undefined) return
    started = Date.now()
    timer = setTimeout(() => { timer = undefined; props.onDismiss() }, remaining)
  }
  createEffect(() => {
    void props.message
    remaining = props.duration ?? 8000
    clear(); resume()
  })
  onCleanup(clear)
  return <div ref={root} classList={{ 'app-toast': true, 'app-toast-error': props.severity === 'error',
    'error-banner': props.severity === 'error', 'notes-message': props.severity !== 'error' }}
    role={props.severity === 'error' ? 'alert' : 'status'} aria-live={props.severity === 'error' ? 'assertive' : 'polite'} aria-atomic="true"
    onPointerEnter={() => { hovered = true; pause() }} onPointerLeave={() => { hovered = false; resume() }}
    onFocusIn={() => { focused = true; pause() }} onFocusOut={(event) => {
      if (event.relatedTarget instanceof Node && root.contains(event.relatedTarget)) return
      focused = false; resume()
    }}>
    <span class="app-toast-message">{props.message}</span>
    <div class="app-toast-actions">
      <Show when={props.onRetry}><button type="button" class="workspace-icon" aria-label="Retry" title="Retry" onClick={() => props.onRetry?.()}><WorkspaceIcon name="refresh" /></button></Show>
      <button type="button" class="workspace-icon" aria-label="Dismiss message" title="Dismiss message" onClick={props.onDismiss}><WorkspaceIcon name="close" /></button>
    </div>
  </div>
}
