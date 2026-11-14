import { For, createEffect, createMemo, createSignal, onCleanup, type Accessor, type JSX } from 'solid-js'
import { TextareaGeometry } from './textareaGeometry'

// Line numbers beside a <textarea>. Only the logical lines in view are
// measured and rendered, through the same mirror geometry the Vim host uses,
// so soft-wrapped lines keep their number on their first row.

interface Row { line: number; top: number; height: number }

export function LineNumberGutter(props: { textarea: Accessor<HTMLTextAreaElement | undefined>; text: Accessor<string> }): JSX.Element {
  const [revision, setRevision] = createSignal(0)
  const [current, setCurrent] = createSignal(1)
  const starts = createMemo(() => {
    const text = props.text(), result = [0]
    for (let index = text.indexOf('\n'); index >= 0; index = text.indexOf('\n', index + 1)) result.push(index + 1)
    return result
  })
  let geometry: TextareaGeometry | undefined
  createEffect(() => {
    const input = props.textarea()
    if (!input) return
    const measure = new TextareaGeometry(input)
    geometry = measure
    let frame = 0
    const update = () => { cancelAnimationFrame(frame); frame = requestAnimationFrame(() => setRevision((value) => value + 1)) }
    const caret = () => {
      const position = input.selectionStart ?? 0, lines = starts()
      let low = 0, high = lines.length - 1
      while (low < high) { const mid = (low + high + 1) >> 1; if (lines[mid]! <= position) low = mid; else high = mid - 1 }
      setCurrent(low + 1)
    }
    const changed = () => { caret(); update() }
    const resize = typeof ResizeObserver === 'function' ? new ResizeObserver(update) : undefined
    resize?.observe(input)
    input.addEventListener('scroll', update)
    input.addEventListener('input', changed)
    input.addEventListener('select', caret)
    input.addEventListener('keyup', caret)
    input.addEventListener('mouseup', caret)
    input.ownerDocument.addEventListener('selectionchange', caret)
    window.addEventListener('resize', update)
    changed()
    onCleanup(() => {
      cancelAnimationFrame(frame)
      resize?.disconnect()
      input.removeEventListener('scroll', update)
      input.removeEventListener('input', changed)
      input.removeEventListener('select', caret)
      input.removeEventListener('keyup', caret)
      input.removeEventListener('mouseup', caret)
      input.ownerDocument.removeEventListener('selectionchange', caret)
      window.removeEventListener('resize', update)
      measure.dispose()
      if (geometry === measure) geometry = undefined
    })
  })
  createEffect(() => { props.text(); setRevision((value) => value + 1) })

  const rows = createMemo<Row[]>(() => {
    revision()
    const input = props.textarea(), lines = starts()
    if (!input) return []
    const top = input.scrollTop, bottom = top + input.clientHeight
    const lineHeight = geometry?.lineHeight() ?? 20
    const rect = (line: number) => geometry?.rect(lines[line]!) ?? null
    if (!rect(0)) {
      // No layout (hidden or a test DOM): estimate unwrapped rows.
      const padding = Number.parseFloat(getComputedStyle(input).paddingTop) || 0
      const first = Math.max(0, Math.floor((top - padding) / lineHeight))
      const count = Math.max(1, Math.ceil(input.clientHeight / lineHeight) + 1)
      return lines.slice(first, first + count).map((_, offset) => ({ line: first + offset + 1, top: padding + (first + offset) * lineHeight - top, height: lineHeight }))
    }
    // The first line whose box ends below the scroll offset.
    let low = 0, high = lines.length - 1
    while (low < high) { const mid = (low + high) >> 1; if ((rect(mid)?.bottom ?? 0) > top) high = mid; else low = mid + 1 }
    const result: Row[] = []
    for (let line = low; line < lines.length; line++) {
      const box = rect(line)
      if (!box || box.top >= bottom) break
      result.push({ line: line + 1, top: box.top - top, height: box.bottom - box.top })
    }
    return result
  })
  const width = () => `${Math.max(2, String(starts().length).length) + 1}ch`
  return <div class="line-number-gutter" aria-hidden="true" style={{ width: width() }}>
    <For each={rows()}>{(row) => <span data-current={row.line === current() ? 'true' : undefined}
      style={{ top: `${row.top}px`, height: `${row.height}px`, 'line-height': `${row.height}px` }}>{row.line}</span>}</For>
  </div>
}
