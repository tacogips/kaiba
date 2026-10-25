// Binds the Vim engine (ported from vactr, see ./vim) to a plain <textarea>.
//
// The engine edits a CodeMirror EditorState, so the textarea gets a shadow
// state that mirrors its value and selection:
// - Vim edits update the shadow state, are written to the textarea, and are
//   announced with a synthetic `input` event so Solid `onInput` handlers keep
//   their draft signals in step.
// - Native typing (insert mode) and pointer selection are diffed back into the
//   shadow state with the user events the engine records for `.` and macros.
// - Programmatic value changes (a Solid re-render, an untrusted `input` event)
//   are adopted as external edits that stay out of the undo history.
// In normal and visual modes the textarea selection shows the Vim cursor: one
// selected character stands in for the block cursor.

import { history, redo as redoCommand, undo as undoCommand } from '@codemirror/commands'
import { EditorSelection, EditorState, Transaction, type TransactionSpec } from '@codemirror/state'
import { TextareaGeometry } from './textareaGeometry'
import { VimController } from './vim/controller'
import { nextGrapheme } from './vim/words'
import { isVimControlChord, normalizeKey } from './vim/keys'
import type { CompiledKeymap } from './vim/keymap-schema'
import type { ClipboardAdapter, VimActions, VimHost, VimKeyInput, VimSnapshot, VimUpdate } from './vim/types'

export interface TextareaVimOptions {
  actions: VimActions
  onSnapshot(snapshot: VimSnapshot): void
  onAnnounce(message: string, assertive: boolean): void
  clipboard?: ClipboardAdapter
}

export interface TextareaVim {
  readonly controller: VimController
  readonly geometry: TextareaGeometry
  setKeymap(keymap: CompiledKeymap | null): void
  /** Returns focus to the textarea after a prompt or the mode button. */
  focus(): void
  dispose(): void
}

const isApple = (): boolean => /Mac|iP/.test(globalThis.navigator?.platform ?? '')

export function browserClipboard(): ClipboardAdapter {
  const clipboard = globalThis.navigator?.clipboard
  return {
    read: () => typeof clipboard?.readText === 'function' ? clipboard.readText() : Promise.reject(new Error('clipboard unavailable')),
    write: (text) => typeof clipboard?.writeText === 'function' ? clipboard.writeText(text) : Promise.reject(new Error('clipboard unavailable')),
  }
}

/** The smallest single change turning `before` into `after`. `prefixCap`
 * keeps the change at or before the caret, so typing into a run of equal
 * characters is recorded where it happened (dot-repeat depends on it). */
export function diffText(before: string, after: string, prefixCap = before.length): { from: number; to: number; insert: string } | null {
  if (before === after) return null
  const limit = Math.min(prefixCap, before.length, after.length)
  let prefix = 0
  while (prefix < limit && before.charCodeAt(prefix) === after.charCodeAt(prefix)) prefix++
  let suffix = 0
  const suffixLimit = Math.min(before.length, after.length) - prefix
  while (suffix < suffixLimit && before.charCodeAt(before.length - 1 - suffix) === after.charCodeAt(after.length - 1 - suffix)) suffix++
  return { from: prefix, to: before.length - suffix, insert: after.slice(prefix, after.length - suffix) }
}

function nativeUserEvent(inputType: string): string {
  if (inputType.startsWith('deleteContentBackward') || inputType === 'deleteWordBackward' || inputType === 'deleteSoftLineBackward' || inputType === 'deleteHardLineBackward') return 'delete.backward'
  if (inputType.startsWith('delete')) return inputType === 'deleteByCut' ? 'delete.cut' : 'delete.forward'
  if (inputType === 'insertFromPaste' || inputType === 'insertFromDrop') return 'input.paste'
  if (inputType === 'insertReplacementText') return 'input.complete'
  return 'input.type'
}

export function attachTextareaVim(textarea: HTMLTextAreaElement, options: TextareaVimOptions): TextareaVim {
  const doc = textarea.ownerDocument
  const view = doc.defaultView!
  const geometry = new TextareaGeometry(textarea)
  const clampSelection = (length: number) => {
    const start = Math.min(textarea.selectionStart ?? 0, length)
    const end = Math.min(textarea.selectionEnd ?? start, length)
    return textarea.selectionDirection === 'backward' ? EditorSelection.single(end, start) : EditorSelection.single(start, end)
  }
  let text = textarea.value
  let state = EditorState.create({ doc: text, selection: clampSelection(text.length), extensions: [history()] })
  const listeners = new Set<(update: VimUpdate) => void>()
  let rendered = { start: textarea.selectionStart ?? 0, end: textarea.selectionEnd ?? 0 }
  let valueDirty = false
  let flushQueued = false
  let notifying = false
  let composing = false
  let discardComposition = false
  let disposed = false
  let keymap: CompiledKeymap | null = null

  // App shortcuts win over Vim: Command chords never reach the engine, and a
  // Control chord does only when it is a built-in Vim chord (Ctrl-[, Ctrl-r,
  // Ctrl-d, ...) or the keymap maps it. Workspace shortcuts keep working.
  const passesToApp = (input: VimKeyInput): boolean => {
    if (input.metaKey) return true
    if (!input.ctrlKey || input.altKey || isVimControlChord(input)) return false
    const key = normalizeKey(input, true)
    return !keymap || !(['n', 'i', 'x', 'o'] as const).some((mode) => keymap!.maps[mode].some((entry) => entry.lhs[0] === key))
  }

  const host: VimHost = {
    state: () => state,
    dispatch(spec: TransactionSpec) {
      const tr = state.update(spec)
      state = tr.state
      if (tr.docChanged) {
        text = state.doc.toString()
        if (text !== textarea.value) valueDirty = true
      }
      const update: VimUpdate = { state, changes: tr.changes, docChanged: tr.docChanged, selectionSet: tr.selection !== undefined, userEvent: tr.annotation(Transaction.userEvent) ?? null }
      for (const listener of [...listeners]) listener(update)
      schedule()
    },
    subscribe(cb) { listeners.add(cb); return () => listeners.delete(cb) },
    undo: () => undoCommand({ state, dispatch: (tr) => host.dispatch(tr) }),
    redo: () => redoCommand({ state, dispatch: (tr) => host.dispatch(tr) }),
    historyReduced: () => false,
    viewport() {
      const lines = state.doc.lines
      const fallback = geometry.lineHeight()
      const top = textarea.scrollTop, bottom = top + textarea.clientHeight
      const lineTop = (line: number) => geometry.rect(state.doc.line(line).from)
      if (!lineTop(1)) {
        return { topLine: Math.max(1, Math.min(lines, Math.floor(top / fallback) + 1)), rows: Math.max(1, Math.floor(textarea.clientHeight / fallback)) }
      }
      // Binary searches over logical lines: the first line ending below the
      // scroll offset, and the last line starting above the visible bottom.
      let low = 1, high = lines
      while (low < high) { const mid = (low + high) >> 1; if ((lineTop(mid)?.bottom ?? 0) > top) high = mid; else low = mid + 1 }
      const topLine = low
      low = topLine; high = lines
      while (low < high) { const mid = (low + high + 1) >> 1; if ((lineTop(mid)?.top ?? 0) < bottom) low = mid; else high = mid - 1 }
      return { topLine, rows: Math.max(1, low - topLine + 1) }
    },
    scrollLines: (lines) => { textarea.scrollTop += lines * geometry.lineHeight() },
    scrollCaret: () => {
      const head = state.selection.main.head
      geometry.reveal(head, state.doc.lineAt(head).number)
    },
    clipboard: options.clipboard ?? browserClipboard(),
    // Saving reads the draft through Solid, so pending Vim edits land first.
    actions: {
      save: () => { flush(); options.actions.save() },
      close: () => { flush(); options.actions.close() },
    },
    closePopupWithEscape: () => false,
    announce: (message, assertive = false) => options.onAnnounce(message, assertive),
    platform: isApple() ? 'apple' : 'other',
    matchesDefaultKeymap: passesToApp,
    compositionActive: () => composing,
    typeText(value) {
      const { from, to } = state.selection.main
      host.dispatch({ changes: { from, to, insert: value }, selection: { anchor: from + value.length }, userEvent: 'input.type' })
    },
    defaultKey(key) {
      const { from, to, head } = state.selection.main
      const line = state.doc.lineAt(head)
      const move = (pos: number) => { host.dispatch({ selection: { anchor: Math.max(0, Math.min(state.doc.length, pos)) }, userEvent: 'select' }); return true }
      switch (key) {
        case '<BS>': {
          const start = from === to ? Math.max(0, from - 1) : from
          host.dispatch({ changes: { from: start, to }, selection: { anchor: start }, userEvent: 'delete.backward' })
          return true
        }
        case '<Del>': {
          const end = from === to ? Math.min(state.doc.length, to + 1) : to
          host.dispatch({ changes: { from, to: end }, selection: { anchor: from }, userEvent: 'delete.forward' })
          return true
        }
        case '<CR>':
          host.dispatch({ changes: { from, to, insert: '\n' }, selection: { anchor: from + 1 }, userEvent: 'input.type' })
          return true
        case '<Left>': return move(head - 1)
        case '<Right>': return move(head + 1)
        case '<Home>': return move(line.from)
        case '<End>': return move(line.to)
        case '<Up>': case '<Down>': {
          const target = line.number + (key === '<Up>' ? -1 : 1)
          if (target < 1 || target > state.doc.lines) return true
          const next = state.doc.line(target)
          return move(Math.min(next.to, next.from + (head - line.from)))
        }
        default: return false
      }
    },
    isVisible: (pos) => geometry.isVisible(pos),
    timer: (ms, cb) => { const id = view.setTimeout(cb, ms); return () => view.clearTimeout(id) },
  }

  const controller = new VimController(host)

  const renderSelection = () => {
    const snapshot = controller.snapshot
    const main = state.selection.main
    const textMode = snapshot.mode === 'insert' || snapshot.mode === 'replace'
    const visual = snapshot.mode === 'visual' || snapshot.mode === 'visual-line'
    const start = textMode || visual ? main.from : snapshot.displayCursor
    const end = visual ? Math.min(nextGrapheme(state.doc, main.to), state.doc.length) : textMode ? main.to : snapshot.displayCursorEnd
    const direction = main.head < main.anchor ? 'backward' : 'forward'
    textarea.dataset.vimMode = snapshot.mode
    rendered = { start, end }
    if (textarea.selectionStart !== start || textarea.selectionEnd !== end) textarea.setSelectionRange(start, end, direction)
  }

  const notifyValue = () => {
    notifying = true
    try {
      const InputEventCtor = view.InputEvent ?? view.Event
      textarea.dispatchEvent(new InputEventCtor('input', { bubbles: true, inputType: 'insertReplacementText' } as InputEventInit))
    } finally { notifying = false }
  }

  function flush(): void {
    flushQueued = false
    if (disposed) return
    if (valueDirty) {
      valueDirty = false
      const scrollTop = textarea.scrollTop
      textarea.value = text
      textarea.scrollTop = scrollTop
      renderSelection()
      notifyValue()
      return
    }
    renderSelection()
  }

  function schedule(): void {
    if (flushQueued) return
    flushQueued = true
    queueMicrotask(flush)
  }

  /** Adopts value and selection changes made outside the engine. */
  const reconcile = () => {
    if (composing || disposed) return
    if (textarea.value !== text) {
      const change = diffText(text, textarea.value)
      if (change) {
        host.dispatch({
          changes: change,
          selection: clampSelection(textarea.value.length),
          annotations: [Transaction.addToHistory.of(false), Transaction.userEvent.of('input.external')],
        })
      }
      return
    }
    const start = textarea.selectionStart ?? 0, end = textarea.selectionEnd ?? start
    if (start === rendered.start && end === rendered.end) return
    host.dispatch({ selection: clampSelection(text.length), userEvent: 'select.pointer' })
  }

  /** Records native editing (insert mode typing, IME commits, paste). */
  const adoptNativeInput = (inputType: string) => {
    if (textarea.value === text) { reconcile(); return }
    const cap = Math.min(state.selection.main.from, textarea.selectionStart ?? 0)
    const change = diffText(text, textarea.value, cap)
    if (!change) return
    host.dispatch({ changes: change, selection: clampSelection(textarea.value.length), userEvent: nativeUserEvent(inputType) })
  }

  const revert = () => {
    valueDirty = textarea.value !== text
    flush()
  }

  const onKeyDown = (event: KeyboardEvent) => {
    if (event.isComposing || event.keyCode === 229 || composing) return
    // Tab keeps moving focus through the form instead of becoming a Vim key.
    if (event.key === 'Tab') return
    flush()
    reconcile()
    const mod = isApple() ? event.metaKey : event.ctrlKey
    const key = event.key.toLowerCase()
    if (mod && !event.altKey && (key === 'z' || (key === 'y' && !isApple()))) {
      event.preventDefault()
      if (key === 'y' || event.shiftKey) host.redo(); else host.undo()
      flush()
      return
    }
    if (controller.handleKey(event)) {
      event.preventDefault()
      event.stopPropagation()
    }
    flush()
  }

  const onBeforeInput = (event: InputEvent) => {
    if (notifying || composing) return
    if (event.inputType === 'historyUndo' || event.inputType === 'historyRedo') {
      event.preventDefault()
      if (event.inputType === 'historyUndo') host.undo(); else host.redo()
      flush()
      return
    }
    if (!controller.allowsTextInput()) {
      if (event.inputType.startsWith('insert') || event.inputType.startsWith('delete')) event.preventDefault()
      return
    }
    if (event.inputType === 'insertText' && event.data) {
      const range = controller.overwriteRange(event.data)
      if (range) {
        event.preventDefault()
        host.dispatch({ changes: { ...range, insert: event.data }, selection: { anchor: range.from + event.data.length }, userEvent: 'input.type' })
        flush()
      }
    }
  }

  const onInput = (event: Event) => {
    if (notifying || composing) return
    if (!event.isTrusted) { reconcile(); return }
    if (!controller.allowsTextInput()) { revert(); return }
    adoptNativeInput((event as InputEvent).inputType ?? 'insertText')
  }

  const onCompositionStart = () => {
    flush()
    composing = true
    discardComposition = !controller.allowsTextInput()
  }

  const onCompositionEnd = () => {
    composing = false
    if (discardComposition) {
      discardComposition = false
      revert()
      controller.noteCompositionDiscarded()
      return
    }
    adoptNativeInput('insertText')
  }

  const onSelectionChange = () => {
    if (doc.activeElement === textarea) reconcile()
  }
  const onBlur = () => controller.blur()
  const onClipboard = (event: ClipboardEvent) => {
    const ranges = controller.snapshot.blockRanges
    if (!ranges || !event.clipboardData) return
    event.clipboardData.setData('text/plain', ranges.map((range) => state.doc.sliceString(range.from, range.to)).join('\n'))
    event.preventDefault()
    if (event.type === 'cut') {
      controller.handleKey({ key: 'd', ctrlKey: false, metaKey: false, altKey: false, shiftKey: false })
      flush()
    }
  }

  textarea.addEventListener('keydown', onKeyDown)
  textarea.addEventListener('beforeinput', onBeforeInput)
  textarea.addEventListener('input', onInput)
  textarea.addEventListener('compositionstart', onCompositionStart)
  textarea.addEventListener('compositionend', onCompositionEnd)
  textarea.addEventListener('select', onSelectionChange)
  textarea.addEventListener('mouseup', onSelectionChange)
  textarea.addEventListener('focus', reconcile)
  textarea.addEventListener('blur', onBlur)
  textarea.addEventListener('copy', onClipboard)
  textarea.addEventListener('cut', onClipboard)
  doc.addEventListener('selectionchange', onSelectionChange)
  const stopSnapshot = controller.subscribe((snapshot) => { options.onSnapshot(snapshot); schedule() })

  return {
    controller,
    geometry,
    setKeymap(next) { keymap = next; controller.setKeymap(next); flush() },
    focus() { if (!textarea.disabled) textarea.focus(); flush() },
    dispose() {
      if (disposed) return
      flush()
      const mode = controller.snapshot.mode
      disposed = true
      stopSnapshot()
      controller.dispose()
      textarea.removeEventListener('keydown', onKeyDown)
      textarea.removeEventListener('beforeinput', onBeforeInput)
      textarea.removeEventListener('input', onInput)
      textarea.removeEventListener('compositionstart', onCompositionStart)
      textarea.removeEventListener('compositionend', onCompositionEnd)
      textarea.removeEventListener('select', onSelectionChange)
      textarea.removeEventListener('mouseup', onSelectionChange)
      textarea.removeEventListener('focus', reconcile)
      textarea.removeEventListener('blur', onBlur)
      textarea.removeEventListener('copy', onClipboard)
      textarea.removeEventListener('cut', onClipboard)
      doc.removeEventListener('selectionchange', onSelectionChange)
      geometry.dispose()
      delete textarea.dataset.vimMode
      // Leave a caret, not the one-character block selection, behind.
      if ((mode === 'normal' || mode === 'operator-pending') && rendered.start !== rendered.end) textarea.setSelectionRange(rendered.start, rendered.start)
    },
  }
}
