import { onCleanup, onMount, type JSX } from 'solid-js'
import { useApp } from '../state/appStore'
import { defaultWorkspaceVimKeys } from '../notes/workspaceVimKeys'
import { vimModeEnabled } from '../notes/settings'
import { normalizeKey } from '../editor/vim/keys'
import { parseNotation } from '../editor/vim/notation'

/** Workspace chords are captured before the browser's Ctrl+W tab-close action. */
export function WorkspaceVimNavigation(props: { onWrite: () => void; onFocus: (pane: 'left' | 'right' | 'bottom' | 'reader' | 'next') => void; blocked: () => boolean }): JSX.Element {
  const app = useApp()
  let prefix: string[] = []
  let timer: ReturnType<typeof setTimeout> | undefined
  const clear = () => { prefix = []; clearTimeout(timer) }
  onMount(() => {
    const keydown = (event: KeyboardEvent) => {
      if (!vimModeEnabled(app.state.settings) || props.blocked() || event.defaultPrevented || event.isComposing || event.repeat
        || document.querySelector('dialog[open], [role="dialog"]')) { clear(); return }
      const key = normalizeKey(event, true)
      if (!key) return
      if (key === '<Other>') { clear(); return }
      const entries = Object.entries({ ...defaultWorkspaceVimKeys, ...app.state.settings.workspaceVimKeys }).flatMap(([action, binding]) => {
        const parsed = parseNotation(binding, null)
        return 'keys' in parsed ? [{ action, keys: parsed.keys }] : []
      })
      const editable = event.target instanceof Element && Boolean(event.target.closest('input, textarea, select, [role="textbox"], [contenteditable]:not([contenteditable="false"])'))
      const candidates = (sequence: string[]) => entries.filter((entry) => sequence.every((token, index) => entry.keys[index] === token)
        && !(editable && entry.action === 'write'))
      let sequence = [...prefix, key]
      let matches = candidates(sequence)
      if (!matches.length && prefix.length) { clear(); sequence = [key]; matches = candidates(sequence) }
      if (!matches.length) return
      event.preventDefault(); event.stopPropagation()
      clearTimeout(timer)
      const exact = matches.find((entry) => entry.keys.length === sequence.length)
      if (exact) {
        clear()
        if (exact.action === 'write') props.onWrite()
        else props.onFocus(exact.action as 'left' | 'right' | 'bottom' | 'reader' | 'next')
      } else { prefix = sequence; timer = setTimeout(clear, 1000) }
    }
    window.addEventListener('keydown', keydown, true)
    onCleanup(() => { clear(); window.removeEventListener('keydown', keydown, true) })
  })
  return <></>
}
