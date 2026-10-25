import type { EditorState } from '@codemirror/state';
import type { EditOutcome } from './operators';
import type { TextRange } from './types';
import { selectTextObject } from './textobjects';
import { firstNonBlank } from './words';

type Pair = { open: string; close: string; space: boolean };
const pairs: Record<string, Pair> = {
  '(': { open: '(', close: ')', space: true }, ')': { open: '(', close: ')', space: false }, b: { open: '(', close: ')', space: false },
  '[': { open: '[', close: ']', space: true }, ']': { open: '[', close: ']', space: false }, r: { open: '[', close: ']', space: false },
  '{': { open: '{', close: '}', space: true }, '}': { open: '{', close: '}', space: false }, B: { open: '{', close: '}', space: false },
  '<': { open: '<', close: '>', space: true }, '>': { open: '<', close: '>', space: false }, a: { open: '<', close: '>', space: false },
  '"': { open: '"', close: '"', space: false }, "'": { open: "'", close: "'", space: false }, '`': { open: '`', close: '`', space: false },
};
const textObjectKey = (ch: string): string => ch === 'b' || ch === ')' ? '(' : ch === 'B' || ch === '}' ? '{' : ch === 'r' || ch === ']' ? '[' : ch === 'a' || ch === '>' ? '<' : ch;

export function surroundPair(ch: string): { open: string; close: string; space: boolean } | null {
  const pair = pairs[ch];
  return pair ? { ...pair } : null;
}

function actualRange(state: EditorState, range: TextRange): { from: number; to: number } {
  if (!range.linewise) return { from: range.from, to: range.to };
  const first = state.doc.lineAt(range.from), last = state.doc.lineAt(Math.max(range.from, range.to));
  const from = firstNonBlank(state.doc, first.number);
  let to = last.to;
  while (to > from && /[ \t]/u.test(state.doc.sliceString(to - 1, to))) to--;
  return { from, to };
}

export function surroundAdd(state: EditorState, range: TextRange, ch: string): EditOutcome | null {
  const pair = surroundPair(ch);
  if (!pair) return null;
  const { from, to } = actualRange(state, range);
  const open = pair.space ? `${pair.open} ` : pair.open;
  const close = pair.space ? ` ${pair.close}` : pair.close;
  return { changes: [{ from, to: from, insert: open }, { from: to, to, insert: close }], cursor: from };
}

function selectedPair(state: EditorState, cursor: number, ch: string): TextRange | null {
  const pair = surroundPair(ch);
  if (!pair) return null;
  const key = textObjectKey(ch);
  const range = selectTextObject(state.doc, cursor, { around: true, kind: key as '"' | "'" | '`' | '(' | '[' | '{' | '<' }, 1, null);
  if (!range || !['"', "'", '`'].includes(ch)) return range;
  let from = range.from, to = range.to;
  while (from < to && /[ \t]/u.test(state.doc.sliceString(from, from + 1))) from++;
  while (to > from && /[ \t]/u.test(state.doc.sliceString(to - 1, to))) to--;
  if (to - from < 2 || state.doc.sliceString(from, from + 1) !== ch || state.doc.sliceString(to - 1, to) !== ch) return null;
  return { ...range, from, to };
}

function trimInnerSpaces(state: EditorState, range: TextRange, ch: string): { from: number; to: number } {
  let from = range.from, to = range.to;
  if ('([{<'.includes(ch)) {
    while (from < to && /[ \t]/u.test(state.doc.sliceString(from, from + 1))) from++;
    while (to > from && /[ \t]/u.test(state.doc.sliceString(to - 1, to))) to--;
  }
  return { from, to };
}

export function surroundDelete(state: EditorState, cursor: number, ch: string): EditOutcome | null {
  const range = selectedPair(state, cursor, ch);
  if (!range || range.to - range.from < 2) return null;
  const inner = trimInnerSpaces(state, { ...range, from: range.from + 1, to: range.to - 1 }, ch);
  return { changes: { from: range.from, to: range.to, insert: state.doc.sliceString(inner.from, inner.to) }, cursor: range.from };
}

export function surroundChange(state: EditorState, cursor: number, from: string, to: string): EditOutcome | null {
  const source = surroundPair(from), target = surroundPair(to);
  const range = selectedPair(state, cursor, from);
  if (!source || !target || !range || range.to - range.from < 2) return null;
  const inner = trimInnerSpaces(state, { ...range, from: range.from + 1, to: range.to - 1 }, from);
  const open = target.space ? `${target.open} ` : target.open;
  const close = target.space ? ` ${target.close}` : target.close;
  const contents = state.doc.sliceString(inner.from, inner.to);
  const insert = `${open}${contents}${close}`;
  return { changes: { from: range.from, to: range.to, insert }, cursor: range.from };
}
