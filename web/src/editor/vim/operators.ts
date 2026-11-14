import type { ChangeSpec, EditorState, Text } from '@codemirror/state';
import { INDENT_UNIT } from './types';
import type { MotionResult, OperatorKind, Register, TextRange } from './types';
import { firstNonBlank, nextGrapheme } from './words';

export type EditOutcome = { changes: ChangeSpec; cursor: number };
export type OperatorOutcome = { changes: ChangeSpec | null; cursor: number; yanked: Register | null; enterInsert: boolean };

const segmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' });

function graphemes(text: string): Array<{ segment: string; index: number }> {
  return Array.from(segmenter.segment(text), ({ segment, index }) => ({ segment, index }));
}

function textRange(doc: Text, range: TextRange): string {
  return doc.sliceString(range.from, range.to);
}

function lastLine(doc: Text, range: TextRange) {
  const end = range.linewise ? Math.min(range.to, doc.length) : Math.max(range.from, range.to - (range.to > range.from ? 1 : 0));
  return doc.lineAt(end);
}

export function motionRange(doc: Text, from: number, result: MotionResult, op: OperatorKind | null): TextRange {
  const a = Math.min(from, result.pos);
  let b = Math.max(from, result.pos);
  if (result.linewise) return { from: doc.lineAt(a).from, to: doc.lineAt(b).to, linewise: true };
  if (result.inclusive) b = Math.min(nextGrapheme(doc, b), doc.lineAt(b).to);
  else if (op !== null && b > a && b === doc.lineAt(b).from && doc.lineAt(b).number > doc.lineAt(a).number) b = doc.lineAt(b).from - 1;
  return { from: a, to: Math.max(a, b), linewise: false };
}

function linewiseDelete(doc: Text, range: TextRange): { from: number; to: number; text: string } {
  const first = doc.lineAt(range.from);
  const last = lastLine(doc, range);
  const text = Array.from({ length: last.number - first.number + 1 }, (_, i) => doc.line(first.number + i).text).join('\n');
  if (last.number < doc.lines) return { from: first.from, to: last.to + 1, text };
  if (first.number > 1) return { from: doc.line(first.number - 1).to, to: last.to, text };
  return { from: first.from, to: last.to, text };
}

export function applyOperator(state: EditorState, op: OperatorKind, range: TextRange): OperatorOutcome {
  const doc = state.doc;
  if (op === 'y') return { changes: null, cursor: range.linewise ? -1 : range.from, yanked: { text: textRange(doc, range), linewise: range.linewise }, enterInsert: false };
  if (op === '>' || op === '<') {
    const first = doc.lineAt(range.from).number;
    const last = lastLine(doc, range).number;
    const changes: ChangeSpec[] = [];
    for (let n = first; n <= last; n++) {
      const line = doc.line(n);
      if (!/\S/.test(line.text)) continue;
      if (op === '>') changes.push({ from: line.from, insert: INDENT_UNIT });
      else if (line.text.startsWith('\t')) changes.push({ from: line.from, to: line.from + 1, insert: '' });
      else {
        const spaces = line.text.match(/^ */)?.[0].length ?? 0;
        const remove = Math.min(spaces, INDENT_UNIT.length);
        if (remove) changes.push({ from: line.from, to: line.from + remove, insert: '' });
      }
    }
    const change = changes.length ? changes : { from: range.from, to: range.from, insert: '' };
    const updated = state.update({ changes: change }).state.doc;
    const cursor = firstNonBlank(updated, Math.min(first, updated.lines));
    return { changes: change, cursor, yanked: null, enterInsert: false };
  }
  if (op === 'g~' || op === 'gu' || op === 'gU') {
    const selected = graphemes(textRange(doc, range));
    const mapped = selected.map(({ segment }) => op === 'gu' ? segment.toLowerCase() : op === 'gU' ? segment.toUpperCase() : segment === segment.toUpperCase() ? segment.toLowerCase() : segment.toUpperCase()).join('');
    const change: ChangeSpec = { from: range.from, to: range.to, insert: mapped };
    return { changes: change, cursor: range.from, yanked: null, enterInsert: false };
  }
  let from = range.from;
  let to = range.to;
  let yankedText = textRange(doc, range);
  if (range.linewise && op === 'c') {
    const first = doc.lineAt(range.from);
    const last = lastLine(doc, range);
    from = first.from;
    to = last.to;
  } else if (range.linewise) {
    const deletion = linewiseDelete(doc, range);
    from = deletion.from;
    to = deletion.to;
    yankedText = deletion.text;
  }
  const originalFirstLine = doc.lineAt(range.from).number;
  const keepIndent = op === 'c' && range.linewise ? doc.line(originalFirstLine).text.match(/^[ \t]*/)?.[0] ?? '' : '';
  const change: ChangeSpec = { from, to, insert: keepIndent };
  const updated = state.update({ changes: change }).state.doc;
  const cursor = range.linewise && op !== 'c' ? firstNonBlank(updated, Math.min(doc.lineAt(Math.min(from, updated.length)).number, updated.lines)) : from + keepIndent.length;
  return {
    changes: change,
    cursor,
    yanked: { text: yankedText, linewise: range.linewise },
    enterInsert: op === 'c',
  };
}

export function putRegister(state: EditorState, cursor: number, reg: Register, before: boolean, count: number): EditOutcome {
  const doc = state.doc;
  const times = Math.max(1, count);
  if (reg.blockwise) {
    const first = doc.lineAt(cursor);
    const column = graphemes(first.text.slice(0, cursor - first.from)).length + (!before && cursor < first.to ? 1 : 0);
    const rows = reg.text.split('\n');
    const changes: ChangeSpec[] = [];
    let missing = '';
    for (const [index, row] of rows.entries()) {
      const number = first.number + index;
      if (number > doc.lines) { missing += `\n${' '.repeat(column)}${row.repeat(times)}`; continue; }
      const line = doc.line(number), characters = graphemes(line.text).map((part) => part.segment);
      const from = line.from + characters.slice(0, column).join('').length;
      changes.push({ from, insert: `${' '.repeat(Math.max(0, column - characters.length))}${row.repeat(times)}` });
    }
    if (missing) changes.push({ from: doc.length, insert: missing });
    const from = first.from + graphemes(first.text).map((part) => part.segment).slice(0, column).join('').length;
    return { changes, cursor: from };
  }
  if (reg.linewise) {
    const repeated = Array(times).fill(reg.text).join('\n');
    const line = doc.lineAt(cursor);
    const from = before ? line.from : line.to;
    const insert = before ? `${repeated}\n` : `\n${repeated}`;
    const change: ChangeSpec = { from, insert };
    const start = before ? from : from + 1;
    const firstText = reg.text.split('\n')[0] ?? '';
    const indent = firstText.match(/^[ \t]*/)?.[0].length ?? 0;
    return { changes: change, cursor: start + indent };
  }
  const line = doc.lineAt(cursor);
  let from = Math.max(line.from, Math.min(cursor, line.to));
  if (!before && from < line.to) from = nextGrapheme(doc, from);
  const insert = reg.text.repeat(times);
  const change: ChangeSpec = { from, insert };
  const items = graphemes(insert);
  const cursorAfter = from + (items.length ? items[items.length - 1]!.index : 0);
  return { changes: change, cursor: insert.includes('\n') ? from : cursorAfter };
}

export function joinLines(state: EditorState, cursor: number, count: number): EditOutcome | null {
  const doc = state.doc;
  const line = doc.lineAt(cursor);
  const joins = Math.min(Math.max(1, count - 1), doc.lines - line.number);
  if (!joins) return null;
  let joined = line.text;
  let cursorOffset = 0;
  for (let i = 1; i <= joins; i++) {
    const next = doc.line(line.number + i).text.replace(/^[ \t]+/, '');
    const separator = next.length === 0 || /[ \t]$/.test(joined) ? '' : ' ';
    joined += separator + next;
    cursorOffset = joined.length - next.length - (separator ? 1 : 0);
  }
  const end = doc.line(line.number + joins).to;
  return { changes: { from: line.from, to: end, insert: joined }, cursor: line.from + cursorOffset };
}

export function replaceChars(state: EditorState, cursor: number, ch: string, count: number): EditOutcome | null {
  const doc = state.doc;
  const line = doc.lineAt(cursor);
  const parts = graphemes(line.text.slice(Math.max(0, cursor - line.from)));
  const amount = Math.max(1, count);
  if (parts.length < amount) return null;
  const from = cursor;
  const to = cursor + parts[amount - 1]!.index + parts[amount - 1]!.segment.length;
  const insert = ch === '\n' ? '\n' : ch.repeat(amount);
  return { changes: { from, to, insert }, cursor: ch === '\n' ? from + 1 : from + graphemes(insert).at(-1)!.index };
}

export function toggleCaseChars(state: EditorState, cursor: number, count: number): EditOutcome | null {
  const doc = state.doc;
  const line = doc.lineAt(cursor);
  const parts = graphemes(line.text.slice(Math.max(0, cursor - line.from))).slice(0, Math.max(1, count));
  if (!parts.length) return null;
  const from = cursor;
  const to = cursor + parts.at(-1)!.index + parts.at(-1)!.segment.length;
  const mapped = parts.map(({ segment }) => segment === segment.toUpperCase() ? segment.toLowerCase() : segment.toUpperCase()).join('');
  return { changes: { from, to, insert: mapped }, cursor: from + mapped.length };
}

export function openLine(state: EditorState, cursor: number, above: boolean): EditOutcome {
  const doc = state.doc;
  const line = doc.lineAt(cursor);
  const indent = line.text.match(/^[ \t]*/)?.[0] ?? '';
  if (above) return { changes: { from: line.from, insert: `${indent}\n` }, cursor: line.from + indent.length };
  return { changes: { from: line.to, insert: `\n${indent}` }, cursor: line.to + 1 + indent.length };
}
