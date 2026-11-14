import type { EditorState } from '@codemirror/state'
import type { TextRange } from './types'

const segmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' })
const characters = (text: string) => Array.from(segmenter.segment(text), (part) => part.segment)

/** One exclusive character range per logical line of a rectangular selection. */
export function visualBlockRanges(state: EditorState, anchor: number, head: number): TextRange[] {
  const a = state.doc.lineAt(anchor), b = state.doc.lineAt(head)
  const columnA = characters(a.text.slice(0, anchor - a.from)).length
  const columnB = characters(b.text.slice(0, head - b.from)).length
  const left = Math.min(columnA, columnB), right = Math.max(columnA, columnB) + 1
  const ranges: TextRange[] = []
  for (let number = Math.min(a.number, b.number); number <= Math.max(a.number, b.number); number++) {
    const line = state.doc.line(number)
    const parts = characters(line.text)
    ranges.push({ from: line.from + parts.slice(0, left).join('').length,
      to: line.from + parts.slice(0, right).join('').length, linewise: false })
  }
  return ranges
}
