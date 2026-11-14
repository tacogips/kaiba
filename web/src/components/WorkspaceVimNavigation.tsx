import { For, Show, createMemo, createSignal, onCleanup, onMount, type JSX } from 'solid-js'
import { useApp } from '../state/appStore'
import { workspaceVimBindings, type WorkspaceVimAction } from '../notes/workspaceVimKeys'
import { vimModeEnabled } from '../notes/settings'
import { normalizeKey } from '../editor/vim/keys'
import { formatNotation } from '../editor/vim/notation'
import { compileUserKeymap } from '../editor/vimKeymap'
import '../editor/vim-editor.css'

const editableSelector = 'input, textarea, select, [role="textbox"], [contenteditable]:not([contenteditable="false"])'

/** Workspace chords are captured before the browser's Ctrl+W tab-close action.
 * A pending prefix (`g`, `<Space>`, `<C-w>`) lists its next keys at the bottom
 * right, the way Helix does. A count typed outside text fields selects a page
 * for the page commands (`12gg`, `12G`, `12gp`). */
export function WorkspaceVimNavigation(props: { onCommand: (action: WorkspaceVimAction, count?: number) => void; blocked: () => boolean }): JSX.Element {
  const app = useApp()
  const bindings = createMemo(() => workspaceVimBindings(app.state.settings.workspaceVimKeys))
  // Keys the editor's own keymap maps in normal mode stay with the editor.
  const editorKeys = createMemo(() => new Set(compileUserKeymap(app.state.settings.vimKeymap).keymap?.maps.n.map((mapping) => mapping.lhs[0]) ?? []))
  const [prefix, setPrefix] = createSignal<string[]>([])
  const [count, setCount] = createSignal('')
  const [pagePrompt, setPagePrompt] = createSignal(false)
  const clear = () => { setPrefix([]); setCount('') }

  const allowed = (context: 'any' | 'normal' | 'reader', target: EventTarget | null, first: string) => {
    if (context === 'any') return true
    const editable = target instanceof Element ? target.closest(editableSelector) : null
    if (!editable) return true
    if (context === 'reader') return false
    // A Vim editor in normal mode with nothing pending hands over the leader.
    return editable instanceof HTMLTextAreaElement && editable.dataset.vimMode === 'normal'
      && !editable.dataset.vimPending && !editorKeys().has(first)
  }

  onMount(() => {
    const keydown = (event: KeyboardEvent) => {
      if (!vimModeEnabled(app.state.settings) || props.blocked() || event.defaultPrevented || event.isComposing || event.repeat || pagePrompt()
        || document.querySelector('dialog[open], [role="dialog"]')) { clear(); return }
      const key = normalizeKey(event, true)
      if (!key) return
      if (key === '<Other>') { clear(); return }
      if (prefix().length && key === '<Esc>') { event.preventDefault(); event.stopPropagation(); clear(); return }
      const inField = event.target instanceof Element && Boolean(event.target.closest(editableSelector))
      // Counts are only read outside text fields and never consume the key.
      if (!prefix().length && !inField && /^[0-9]$/.test(key) && (key !== '0' || count())) { setCount((value) => (value + key).slice(-6)); return }
      const candidates = (sequence: string[]) => bindings().filter((entry) => sequence.every((token, index) => entry.keys[index] === token)
        && allowed(entry.context, event.target, entry.keys[0]!))
      let sequence = [...prefix(), key]
      let matches = candidates(sequence)
      if (!matches.length && prefix().length) { setPrefix([]); sequence = [key]; matches = candidates(sequence) }
      if (!matches.length) { setCount(''); return }
      event.preventDefault(); event.stopPropagation()
      const exact = matches.find((entry) => entry.keys.length === sequence.length)
      if (!exact) { setPrefix(sequence); return }
      const page = count() ? Number(count()) : undefined
      clear()
      if (exact.action === 'gotoPage' && page === undefined) { setPagePrompt(true); return }
      props.onCommand(exact.action, page)
    }
    const reset = () => clear()
    window.addEventListener('keydown', keydown, true)
    window.addEventListener('blur', reset)
    window.addEventListener('pointerdown', reset, true)
    onCleanup(() => {
      window.removeEventListener('keydown', keydown, true)
      window.removeEventListener('blur', reset)
      window.removeEventListener('pointerdown', reset, true)
    })
  })

  const next = createMemo(() => {
    const pending = prefix()
    if (!pending.length) return []
    return bindings().filter((entry) => entry.keys.length > pending.length && pending.every((token, index) => entry.keys[index] === token))
  })
  return <>
    <Show when={next().length}>
      <aside class="vim-hints" aria-label="Workspace next keys">
        <div class="vim-hints-prefix">{count()}{formatNotation(prefix())}</div>
        <div class="vim-hints-grid">
          <For each={next()}>{(entry) => <div class="vim-hints-row">
            <kbd><span class="vim-hints-typed">{formatNotation(prefix())}</span>{formatNotation(entry.keys.slice(prefix().length))}</kbd>
            <span>{entry.desc}</span>
          </div>}</For>
        </div>
        <span class="sr-only" aria-live="polite">{`${formatNotation(prefix())}: ${next().length} next keys`}</span>
      </aside>
    </Show>
    <Show when={pagePrompt()}>
      <form class="vim-hints vim-page-prompt" aria-label="Go to page" onSubmit={(event) => {
        event.preventDefault()
        const page = Number(new FormData(event.currentTarget).get('page'))
        setPagePrompt(false)
        if (Number.isSafeInteger(page) && page > 0) props.onCommand('gotoPage', page)
      }}>
        <label class="vim-hints-prefix">Go to page
          <input name="page" type="number" min="1" inputmode="numeric" autocomplete="off" aria-label="Page number to go to"
            ref={(input) => queueMicrotask(() => input.focus())}
            onKeyDown={(event) => { if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); setPagePrompt(false) } }}
            onBlur={() => setPagePrompt(false)} />
        </label>
      </form>
    </Show>
  </>
}
