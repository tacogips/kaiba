/** Reader navigation is separate from editable Vim fields. */
export function readerControlPage(event: KeyboardEvent): -1 | 0 | 1 {
  if (!event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) return 0
  if (event.code === 'KeyD' || event.key.toLowerCase() === 'd') return 1
  if (event.code === 'KeyU' || event.key.toLowerCase() === 'u') return -1
  return 0
}

export function readerKeyAllowed(event: KeyboardEvent, container?: HTMLElement): boolean {
  if (event.defaultPrevented || event.isComposing || event.metaKey || event.altKey
    || document.querySelector('dialog[open], [role="dialog"]')) return false
  if (event.target instanceof Element) {
    if (event.target.closest('input, textarea, select, [contenteditable]:not([contenteditable="false"]), [role="textbox"]')) return false
    const workspace = container?.closest<HTMLElement>('.reader') ?? container
    if (workspace && event.target !== document.body && event.target !== document.documentElement && !workspace.contains(event.target)) return false
  }
  return true
}

export function scrollReader(event: KeyboardEvent, container: HTMLElement | undefined, pageKeys = true): boolean {
  if (!container || !readerKeyAllowed(event, container)) return false
  const page = pageKeys ? readerControlPage(event) : 0
  const line = !event.ctrlKey && !event.shiftKey ? event.key === 'j' ? 1 : event.key === 'k' ? -1 : 0 : 0
  if (!page && !line) return false
  const scrollable = container.querySelector<HTMLElement>('.pdf-text-stage, .pdf-viewer-stage:not([hidden])') ?? container
  scrollable.scrollBy({ top: page ? page * Math.max(1, scrollable.clientHeight * 0.9) : line * 48, behavior: 'instant' })
  event.preventDefault()
  return true
}

/** Detail of the `kaiba-goto-page` window event: a 1-based page, or an end. */
export type GotoPageTarget = number | 'first' | 'last'

export function onGotoPage(listener: (target: GotoPageTarget) => void): () => void {
  const handle = (event: Event) => {
    const detail = (event as CustomEvent<unknown>).detail
    if (detail === 'first' || detail === 'last' || (typeof detail === 'number' && Number.isSafeInteger(detail) && detail > 0)) listener(detail)
  }
  window.addEventListener('kaiba-goto-page', handle)
  return () => window.removeEventListener('kaiba-goto-page', handle)
}
