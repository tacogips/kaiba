import type { Text } from '@codemirror/state';
import { classAt, nextGrapheme, prevGrapheme } from './words';
import { SCAN_LIMIT, type TextObjectSpec, type TextRange } from './types';

type Pair = { open: number; close: number };
const brackets: Record<string, string> = { '(': ')', '[': ']', '{': '}', '<': '>' };

function range(from: number, to: number): TextRange { return { from, to, linewise: false }; }
function lineRuns(line: string, from: number, kind: 'w' | 'W'): Array<{ from: number; to: number; cls: number }> {
  const parts = Array.from(new Intl.Segmenter(undefined, { granularity: 'grapheme' }).segment(line));
  return parts.map((part) => ({ from: from + part.index, to: from + part.index + part.segment.length,
    cls: kind === 'W' ? (/^[ \t]+$/u.test(part.segment) ? 0 : 1) : classAt(line, part.index) }));
}
function wordObject(doc: Text, cursor: number, spec: TextObjectSpec, count: number): TextRange | null {
  const line = doc.lineAt(Math.max(0, Math.min(cursor, doc.length)));
  const runs = lineRuns(line.text, line.from, spec.kind as 'w' | 'W');
  if (!runs.length) return null;
  let at = runs.findIndex((part) => cursor >= part.from && cursor < part.to);
  if (at < 0) at = runs.length - 1;
  let left = at, right = at;
  while (right + 1 < runs.length && runs[right + 1]!.cls === runs[right]!.cls) right++;
  if (spec.around && runs[at]!.cls !== 0) {
    for (let n = 1; n < Math.max(1, Math.floor(count)); n++) {
      if (right + 1 < runs.length && runs[right + 1]!.cls === 0) {
        right++;
        while (right + 1 < runs.length && runs[right + 1]!.cls === 0) right++;
      }
      if (right + 1 >= runs.length) break;
      right++;
      while (right + 1 < runs.length && runs[right + 1]!.cls === runs[right]!.cls) right++;
    }
  } else {
    for (let n = 1; n < Math.max(1, Math.floor(count)); n++) {
      if (right + 1 >= runs.length) break;
      right++;
      while (right + 1 < runs.length && runs[right + 1]!.cls === runs[right]!.cls) right++;
    }
  }
  while (left > 0 && runs[left - 1]!.cls === runs[left]!.cls) left--;
  while (right + 1 < runs.length && runs[right + 1]!.cls === runs[right]!.cls) right++;
  let from = runs[left]!.from, to = runs[right]!.to;
  if (spec.around) {
    let trailing = right + 1;
    while (trailing < runs.length && runs[trailing]!.cls === 0) trailing++;
    if (trailing > right + 1) to = runs[trailing - 1]!.to;
    else {
      let leading = left - 1;
      while (leading >= 0 && runs[leading]!.cls === 0) leading--;
      if (leading < left - 1) from = runs[leading + 1]!.from;
    }
  }
  return range(from, to);
}
function blanks(doc: Text, from: number, to: number, lineFrom: number, lineTo: number): [number, number] {
  let a = from, b = to;
  while (b < lineTo && /[ \t]/u.test(doc.sliceString(b, nextGrapheme(doc, b)))) b = nextGrapheme(doc, b);
  if (b === to) while (a > lineFrom && /[ \t]/u.test(doc.sliceString(prevGrapheme(doc, a), a))) a = prevGrapheme(doc, a);
  return [a, b];
}
function quoteObject(doc: Text, cursor: number, spec: TextObjectSpec): TextRange | null {
  const line = doc.lineAt(Math.max(0, Math.min(cursor, doc.length)));
  const pairs: Pair[] = [];
  let open = -1;
  for (let pos = line.from; pos < line.to; pos++) {
    if (doc.sliceString(pos, pos + 1) !== spec.kind) continue;
    let slashes = 0;
    for (let back = pos - 1; back >= line.from && doc.sliceString(back, back + 1) === '\\'; back--) slashes++;
    if (slashes % 2) continue;
    if (open < 0) open = pos;
    else { pairs.push({ open, close: pos }); open = -1; }
  }
  const pair = pairs.find((p) => cursor >= p.open && cursor <= p.close) ?? pairs.find((p) => p.open >= cursor);
  if (!pair) return null;
  if (!spec.around) return range(pair.open + 1, pair.close);
  const [from, to] = blanks(doc, pair.open, pair.close + 1, line.from, line.to);
  return range(from, to);
}
function matchingClose(doc: Text, open: number, close: string, limit: number): number | null {
  const opener = doc.sliceString(open, open + 1);
  let depth = 0, scanned = 0;
  for (let pos = open; pos < doc.length && scanned < limit; pos++, scanned++) {
    const ch = doc.sliceString(pos, pos + 1);
    if (ch === opener) depth++;
    else if (ch === close && --depth === 0) return pos;
  }
  return null;
}
function enclosing(doc: Text, cursor: number, kind: string, before: number): Pair | null {
  const close = brackets[kind]!;
  let depth = 0, scanned = 0;
  for (let pos = before; pos >= 0 && scanned < SCAN_LIMIT; pos--, scanned++) {
    const ch = doc.sliceString(pos, pos + 1);
    if (ch === close) depth++;
    else if (ch === kind) {
      if (depth) depth--;
      else if (pos <= cursor) {
        const end = matchingClose(doc, pos, close, SCAN_LIMIT - Math.max(0, cursor - pos));
        if (end !== null && end >= cursor) return { open: pos, close: end };
      }
    }
  }
  return null;
}
function bracketRange(doc: Text, pair: Pair, around: boolean): TextRange {
  if (around) return range(pair.open, pair.close + 1);
  let from = pair.open + 1, to = pair.close;
  if (doc.sliceString(from, from + 1) === '\n') from++;
  const closeLine = doc.lineAt(pair.close);
  const prefix = doc.sliceString(closeLine.from, pair.close);
  if (/^[ \t]*$/u.test(prefix) && closeLine.from > 0) to = closeLine.from - 1;
  return range(Math.min(from, to), Math.max(from, to));
}
function bracketObject(doc: Text, cursor: number, spec: TextObjectSpec, count: number, visual: { anchor: number; head: number } | null): TextRange | null {
  const kind = spec.kind;
  const cl = brackets[kind]!;
  let pair: Pair | null = null;
  const at = doc.sliceString(cursor, cursor + 1);
  if (at === kind) {
    const end = matchingClose(doc, cursor, cl, SCAN_LIMIT);
    if (end !== null) pair = { open: cursor, close: end };
  }
  if (!pair) pair = enclosing(doc, cursor, kind, at === cl ? cursor - 1 : cursor);
  if (!pair) return null;
  const currentRange = bracketRange(doc, pair, spec.around);
  const visualFrom = visual && Math.min(visual.anchor, visual.head);
  const visualTo = visual && Math.max(visual.anchor, visual.head);
  const visualLast = currentRange.to > currentRange.from ? prevGrapheme(doc, currentRange.to) : currentRange.from;
  const repeat = Boolean(visual && visual.anchor !== visual.head && visualFrom === currentRange.from && visualTo === visualLast);
  let remaining = Math.max(1, Math.floor(count)) + (repeat ? 1 : 0);
  while (--remaining > 0) {
    const parent = enclosing(doc, pair.open - 1, kind, pair.open - 1);
    if (!parent) return null;
    pair = parent;
  }
  return bracketRange(doc, pair, spec.around);
}

export function selectTextObject(doc: Text, cursor: number, spec: TextObjectSpec, count: number, visual: { anchor: number; head: number } | null): TextRange | null {
  if (spec.kind === 'w' || spec.kind === 'W') return wordObject(doc, cursor, spec, count);
  if (spec.kind === '"' || spec.kind === "'" || spec.kind === '`') return quoteObject(doc, cursor, spec);
  return bracketObject(doc, cursor, spec, count, visual);
}
