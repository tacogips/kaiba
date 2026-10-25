import { onCleanup, onMount } from 'solid-js'

/** Capture Escape even when a native input has moved focus outside the form.
 * Outside clicks keep their destination focus; keyboard dismissal restores it. */
export function usePopoverDismissal(options: {
  isOpen: () => boolean
  canDismiss: () => boolean
  contains: (target: Node) => boolean
  onDismiss: (restoreFocus: boolean) => void
  dismissOutside?: boolean
  /** Nested modal previews handle Escape first and stop its bubbling. */
  captureEscape?: boolean
}) {
  onMount(() => {
    const pointer = (event: PointerEvent) => {
      if (options.dismissOutside !== false && options.isOpen() && options.canDismiss() && event.target instanceof Node && !options.contains(event.target)) {
        options.onDismiss(false)
      }
    }
    const key = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && !event.defaultPrevented && !event.cancelBubble && options.isOpen() && options.canDismiss()) {
        event.preventDefault()
        event.stopPropagation()
        options.onDismiss(true)
      }
    }
    document.addEventListener('pointerdown', pointer, true)
    const capture = options.captureEscape !== false
    document.addEventListener('keydown', key, capture)
    onCleanup(() => {
      document.removeEventListener('pointerdown', pointer, true)
      document.removeEventListener('keydown', key, capture)
    })
  })
}
