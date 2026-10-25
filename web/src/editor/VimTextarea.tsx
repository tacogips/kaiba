import { For, Show, createEffect, createMemo, createSignal, on, onCleanup, untrack, type Accessor, type JSX } from 'solid-js'
import { Portal } from 'solid-js/web'
import { useApp } from '../state/appStore'
import { vimModeEnabled } from '../notes/settings'
import { attachTextareaVim, type TextareaVim } from './textareaVim'
import { compileUserKeymap } from './vimKeymap'
import { normalizeKey } from './vim/keys'
import type { CompiledKeymap } from './vim/keymap-schema'
import type { HintView, HopView, VimKey, VimSnapshot } from './vim/types'
import './vim-editor.css'

// Vim mode for a Markdown <textarea>. Usage:
//
//   const vim = createVimTextarea({ save })
//   <textarea ref={vim.ref} ... />
//   <vim.Status />
//
// The binding follows the `vimMode` setting (on by default) and the stored
// keymap, attaching and detaching live when either changes.

export interface VimTextareaOptions {
  /** `:w` and the `kaiba.save` action; defaults to submitting the form. */
  save?: () => void
  /** `:q` and the `kaiba.close` action; defaults to leaving the editor. */
  close?: () => void
}

export interface VimTextareaBinding {
  ref: (textarea: HTMLTextAreaElement) => void
  enabled: Accessor<boolean>
  Status: (props: { class?: string }) => JSX.Element
}

export function createVimTextarea(options: VimTextareaOptions = {}): VimTextareaBinding {
  const app = useApp()
  const [textarea, setTextarea] = createSignal<HTMLTextAreaElement>()
  const [session, setSession] = createSignal<TextareaVim | null>(null)
  const [snapshot, setSnapshot] = createSignal<VimSnapshot | null>(null)
  const [announcement, setAnnouncement] = createSignal('')
  const enabled = () => vimModeEnabled(app.state.settings)
  const keymap = createMemo(() => compileUserKeymap(app.state.settings.vimKeymap).keymap)

  createEffect(() => {
    const element = textarea()
    if (!element || !enabled()) return
    const attached = attachTextareaVim(element, {
      actions: {
        save: () => options.save ? options.save() : element.form?.requestSubmit(),
        close: () => options.close ? options.close() : element.blur(),
      },
      onSnapshot: setSnapshot,
      onAnnounce: setAnnouncement,
    })
    attached.setKeymap(untrack(keymap))
    setSession(attached)
    onCleanup(() => {
      attached.dispose()
      setSession(null)
      setSnapshot(null)
    })
  })
  createEffect(on(keymap, (next) => untrack(session)?.setKeymap(next), { defer: true }))

  const Status = (props: { class?: string }) => <Show when={snapshot()}>{(current) =>
    <div class={`vim-status${props.class ? ` ${props.class}` : ''}`} data-mode={current().mode}>
      <button type="button" class="vim-status-mode" data-mode={current().mode}
        aria-label={`Vim ${current().label} mode; activate to ${current().mode === 'insert' || current().mode === 'replace' ? 'leave' : 'enter'} insert mode`}
        title={current().mode === 'insert' || current().mode === 'replace' ? 'Back to normal mode' : 'Enter insert mode'}
        onMouseDown={(event) => event.preventDefault()}
        onClick={() => { session()?.controller.tapMode(); session()?.focus() }}>{current().label}</button>
      <Show when={current().pending}><span class="vim-status-pending">{current().pending}</span></Show>
      <Show when={current().recording}>{(register) => <span class="vim-status-recording">recording @{register()}</span>}</Show>
      <Show when={current().prompt} fallback={<Show when={current().message}>
        <span class="vim-status-message" data-kind={current().messageKind ?? 'info'}>{current().message}</span>
      </Show>}>{(prompt) =>
        <VimPrompt kind={prompt().kind} initial={prompt().initial} keymap={keymap}
          onSubmit={(text) => { session()?.controller.submitPrompt(text); session()?.focus() }}
          onCancel={() => { session()?.controller.cancelPrompt(); session()?.focus() }} />}
      </Show>
      <span class="sr-only" aria-live="polite">{announcement()}</span>
      <Show when={current().hints}>{(hints) => <VimHints view={hints()} />}</Show>
      <Show when={current().hop}>{(hop) => <VimHopLabels view={hop()} session={session} />}</Show>
      <Show when={current().blockRanges}>{(ranges) => <VimBlockSelection ranges={ranges()} session={session} textarea={textarea} />}</Show>
    </div>}
  </Show>

  return { ref: setTextarea, enabled, Status }
}

function VimBlockSelection(props: { ranges: { from: number; to: number }[]; session: Accessor<TextareaVim | null>; textarea: Accessor<HTMLTextAreaElement | undefined> }): JSX.Element {
  const [revision, setRevision] = createSignal(0)
  createEffect(() => {
    const input = props.textarea()
    const update = () => setRevision((value) => value + 1)
    input?.addEventListener('scroll', update)
    window.addEventListener('resize', update)
    onCleanup(() => { input?.removeEventListener('scroll', update); window.removeEventListener('resize', update) })
  })
  const rectangles = createMemo(() => {
    revision()
    const input = props.textarea(), geometry = props.session()?.geometry
    if (!input || !geometry) return []
    return geometry.clientRangesRects(props.ranges)
  })
  return <Portal><div aria-hidden="true" class="vim-block-selection"><For each={rectangles()}>{(box) =>
    <span style={{ position: 'fixed', top: `${box.top}px`, left: `${box.left}px`, width: `${box.width}px`, height: `${box.height}px` }} />
  }</For></div></Portal>
}

function VimPrompt(props: { kind: ':' | '/' | '?'; initial: string; keymap: Accessor<CompiledKeymap | null>; onSubmit(text: string): void; onCancel(): void }): JSX.Element {
  let done = false
  const finish = (action: () => void) => {
    if (done) return
    done = true
    action()
  }
  const applyKey = (input: HTMLInputElement, key: VimKey) => {
    const start = input.selectionStart ?? input.value.length
    const end = input.selectionEnd ?? start
    if (key === '<Esc>') finish(props.onCancel)
    else if (key === '<CR>') finish(() => props.onSubmit(input.value))
    else if (key === '<Home>') input.setSelectionRange(0, 0)
    else if (key === '<End>') input.setSelectionRange(input.value.length, input.value.length)
    else if (key === '<Left>' || key === '<Right>') {
      const caret = start === end ? Math.max(0, Math.min(input.value.length, start + (key === '<Right>' ? 1 : -1))) : key === '<Right>' ? end : start
      input.setSelectionRange(caret, caret)
    } else if (key === '<BS>' || key === '<Del>') {
      const from = start === end && key === '<BS>' ? Math.max(0, start - 1) : start
      const to = start === end && key === '<Del>' ? Math.min(input.value.length, end + 1) : end
      input.setRangeText('', from, to, 'end')
    } else if (Array.from(key).length === 1 && key >= ' ') input.setRangeText(key, start, end, 'end')
  }
  return <label class="vim-status-prompt">
    <span aria-hidden="true">{props.kind}</span>
    <input type="text" autocomplete="off" spellcheck={false} value={props.initial}
      aria-label={props.kind === ':' ? 'Vim command' : 'Vim search'}
      ref={(input) => queueMicrotask(() => { input.focus(); input.setSelectionRange(input.value.length, input.value.length) })}
      onKeyDown={(event) => {
        if (event.isComposing || event.keyCode === 229) return
        const key = normalizeKey(event, true)
        const mapped = key === null ? null : props.keymap()?.cmdline.get(key) ?? null
        if (mapped !== null) applyKey(event.currentTarget, mapped)
        else if (event.key === 'Enter') finish(() => props.onSubmit(event.currentTarget.value))
        else if (event.key === 'Escape' || (event.ctrlKey && event.key === '[')) finish(props.onCancel)
        else return
        event.preventDefault()
        event.stopPropagation()
      }}
      onBlur={() => finish(props.onCancel)} />
  </label>
}

const hintRows = 24

function VimHints(props: { view: HintView }): JSX.Element {
  const hidden = () => Math.max(0, props.view.entries.length - (hintRows - 1))
  const visible = () => props.view.entries.slice(0, props.view.entries.length > hintRows ? hintRows - 1 : hintRows)
  return <aside class="vim-hints" aria-label="Vim next keys">
    <div class="vim-hints-prefix">{props.view.prefix}</div>
    <div class="vim-hints-grid" aria-hidden="true">
      <For each={visible()}>{(entry) => <div class="vim-hints-row" data-group={entry.group ? 'true' : undefined}>
        <kbd>{entry.key}</kbd><span>{entry.desc}</span>
      </div>}</For>
      <Show when={props.view.entries.length > hintRows}><div class="vim-hints-row"><span>+{hidden()} more</span></div></Show>
    </div>
    <span class="sr-only" aria-live="polite">{props.view.summary}</span>
  </aside>
}

function VimHopLabels(props: { view: HopView; session: Accessor<TextareaVim | null> }): JSX.Element {
  // Positions are measured once per hop revision; the labels are fixed to
  // the viewport, so a Portal keeps transformed ancestors from offsetting them.
  const placed = createMemo(() => {
    void props.view.revision
    const geometry = props.session()?.geometry
    return props.view.labels.flatMap((label) => {
      const point = geometry?.clientPoint(label.pos)
      return point ? [{ text: label.text, top: point.top, left: point.left, height: point.height }] : []
    })
  })
  return <Portal>
    <div class="vim-hop-layer" aria-hidden="true">
      <For each={placed()}>{(label) => <span class="vim-hop-label"
        style={{ top: `${label.top}px`, left: `${label.left}px`, 'line-height': `${label.height}px` }}>{label.text}</span>}</For>
    </div>
  </Portal>
}
