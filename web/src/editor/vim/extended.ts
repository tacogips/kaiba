import type { EditorState, Text } from '@codemirror/state';
import type { VimViewport } from './types';
import type { EditOutcome } from './operators';
import type { TextRange } from './types';
import { posAtColumn } from './words';

export function joinRaw(state: EditorState, cursor: number, count: number, visual: { anchor: number; head: number } | null): { outcome: EditOutcome | null; range: TextRange | null } {
  const doc = state.doc;
  const first = doc.lineAt(visual ? Math.min(visual.anchor, visual.head) : cursor);
  const selectedLast = visual ? doc.lineAt(Math.max(visual.anchor, visual.head)).number : first.number;
  const last = doc.line(Math.min(doc.lines, Math.max(selectedLast, first.number + Math.max(2, count) - 1)));
  if (last.number <= first.number) return { outcome: null, range: visual ? { from: first.from, to: first.to, linewise: true } : null };
  const range = { from: first.from, to: last.to, linewise: true };
  const text = Array.from({ length: last.number - first.number + 1 }, (_, index) => doc.line(first.number + index).text).join('');
  return { outcome: { changes: { from: first.from, to: last.to, insert: text }, cursor: first.from }, range: visual ? range : null };
}

export function scrollCenterDelta(doc: Text, cursor: number, viewport: VimViewport): number {
  const cursorLine = doc.lineAt(Math.max(0, Math.min(cursor, doc.length))).number;
  return cursorLine - (Math.max(1, viewport.topLine) + Math.floor(Math.max(1, viewport.rows) / 2));
}

export function scrollLineResult(doc: Text, cursor: number, viewport: VimViewport, delta: number, desiredColumn: number | null): { scrollLines: number; cursor: number | null } {
  const rows = Math.max(1, Math.floor(viewport.rows));
  const maxTop = Math.max(1, doc.lines - rows + 1);
  const oldTop = Math.max(1, Math.min(maxTop, Math.floor(viewport.topLine)));
  const newTop = Math.max(1, Math.min(maxTop, oldTop + Math.trunc(delta)));
  const line = doc.lineAt(Math.max(0, Math.min(cursor, doc.length))).number;
  if (line >= newTop && line < newTop + rows) return { scrollLines: newTop - oldTop, cursor: null };
  const visibleLine = line < newTop ? newTop : Math.min(doc.lines, newTop + rows - 1);
  return { scrollLines: newTop - oldTop, cursor: posAtColumn(doc, visibleLine, desiredColumn ?? 0) };
}
