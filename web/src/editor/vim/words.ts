import type { Text } from '@codemirror/state';

const segmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' });
const keyword = /^[\p{L}\p{N}_]$/u;

export function charClass(ch: string): 0 | 1 | 2 {
  if (ch === ' ' || ch === '\t') return 0;
  return keyword.test(ch) ? 1 : 2;
}

export function classAt(line: string, index: number): 0 | 1 | 2 {
  const ch = index >= 0 && index < line.length ? String.fromCodePoint(line.codePointAt(index) as number) : '';
  if (ch === '-' && index > 0 && index + 1 < line.length) {
    const before = Array.from(line.slice(0, index)).at(-1) ?? '';
    const after = Array.from(line.slice(index + 1))[0] ?? '';
    if (charClass(before) === 1 && charClass(after) === 1) return 1;
  }
  return charClass(ch);
}

function lineSegments(line: string): Intl.Segments {
  return segmenter.segment(line);
}

export function nextGrapheme(doc: Text, pos: number): number {
  const safe = Math.max(0, Math.min(pos, doc.length));
  const line = doc.lineAt(safe);
  if (safe >= line.to) return line.number < doc.lines ? line.to + 1 : doc.length;
  for (const part of lineSegments(line.text)) if (line.from + part.index + part.segment.length > safe) return line.from + part.index + part.segment.length;
  return line.to;
}

export function prevGrapheme(doc: Text, pos: number): number {
  const safe = Math.max(0, Math.min(pos, doc.length));
  if (safe === 0) return 0;
  const line = doc.lineAt(safe);
  if (safe <= line.from && line.number > 1) return doc.line(line.number - 1).to;
  let previous = line.from;
  for (const part of lineSegments(line.text)) {
    const start = line.from + part.index;
    if (start >= safe) break;
    previous = start;
  }
  return previous;
}

export function graphemeColumn(doc: Text, pos: number): number {
  const line = doc.lineAt(Math.max(0, Math.min(pos, doc.length)));
  let count = 0;
  for (const part of lineSegments(line.text)) {
    if (line.from + part.index + part.segment.length > pos) break;
    count++;
  }
  return count;
}

export function posAtColumn(doc: Text, lineNumber: number, column: number): number {
  const line = doc.line(Math.max(1, Math.min(lineNumber, doc.lines)));
  const parts = Array.from(lineSegments(line.text));
  if (!parts.length) return line.from;
  const index = Number.isFinite(column) ? Math.max(0, Math.min(Math.floor(column), parts.length - 1)) : parts.length - 1;
  return line.from + parts[index]!.index;
}

export function clampNormal(doc: Text, pos: number): number {
  const safe = Math.max(0, Math.min(pos, doc.length));
  const line = doc.lineAt(safe);
  if (line.length === 0 || safe < line.to) return safe;
  const parts = Array.from(lineSegments(line.text));
  return parts.length ? line.from + parts[parts.length - 1]!.index : line.from;
}

export function firstNonBlank(doc: Text, lineNumber: number): number {
  const line = doc.line(Math.max(1, Math.min(lineNumber, doc.lines)));
  const offset = line.text.search(/[^ \t]/);
  return offset < 0 ? line.to : line.from + offset;
}
