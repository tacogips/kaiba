import type { ChangeSpec, Text } from '@codemirror/state';
import { classAt } from './words';

const textCache = new WeakMap<Text, string>();

function wholeText(doc: Text): string {
  let value = textCache.get(doc);
  if (value === undefined) {
    value = doc.toString();
    textCache.set(doc, value);
  }
  return value;
}

export function compilePattern(source: string): { regex: RegExp; literal: boolean; note: string | null } {
  const ignoreCase = source.endsWith('\\c');
  const body = ignoreCase ? source.slice(0, -2) : source;
  const flags = `u${ignoreCase ? 'i' : ''}`;
  if (!body) return { regex: new RegExp('(?:)', flags), literal: false, note: null };
  try {
    return { regex: new RegExp(body, flags), literal: false, note: null };
  } catch {
    return { regex: new RegExp(body.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), flags), literal: true, note: 'pattern compiled as literal text' };
  }
}

export function findMatch(doc: Text, from: number, regex: RegExp, direction: 1 | -1): { from: number; to: number; wrapped: boolean } | null {
  const source = wholeText(doc);
  const scan = new RegExp(regex.source, regex.flags.includes('g') ? regex.flags : `${regex.flags}g`);
  scan.lastIndex = 0;
  const matches: Array<{ from: number; to: number }> = [];
  let match: RegExpExecArray | null;
  while ((match = scan.exec(source)) !== null) {
    matches.push({ from: match.index, to: match.index + match[0].length });
    if (match[0].length === 0) {
      if (scan.lastIndex >= source.length) break;
      const cp = source.codePointAt(scan.lastIndex);
      scan.lastIndex += cp !== undefined && cp > 0xffff ? 2 : 1;
    }
  }
  if (direction === 1) {
    const next = matches.find((item) => item.from > from);
    return next ? { ...next, wrapped: false } : matches[0] ? { ...matches[0], wrapped: true } : null;
  }
  for (let i = matches.length - 1; i >= 0; i--) if (matches[i]!.from < from) return { ...matches[i]!, wrapped: false };
  return matches.length ? { ...matches[matches.length - 1]!, wrapped: true } : null;
}

export function wordUnderCursor(doc: Text, pos: number): { from: number; to: number; text: string } | null {
  const line = doc.lineAt(Math.max(0, Math.min(pos, doc.length)));
  const text = line.text;
  const runs: Array<{ from: number; to: number }> = [];
  let i = 0;
  while (i < text.length) {
    if (classAt(text, i) !== 1) { i += text.codePointAt(i)! > 0xffff ? 2 : 1; continue; }
    const from = i;
    do { i += text.codePointAt(i)! > 0xffff ? 2 : 1; } while (i < text.length && classAt(text, i) === 1);
    runs.push({ from, to: i });
  }
  const local = Math.max(0, Math.min(pos - line.from, text.length));
  const run = runs.find((r) => r.from <= local && local < r.to) ?? runs.find((r) => r.from >= local);
  return run ? { from: line.from + run.from, to: line.from + run.to, text: text.slice(run.from, run.to) } : null;
}

export function wordPattern(word: string): RegExp {
  // A trailing punctuation hyphen is excluded by the right boundary, matching the pinned Vim keyword rule.
  const escaped = word.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return new RegExp(`(?<![\\p{L}\\p{N}_\\-])${escaped}(?![\\p{L}\\p{N}_\\-])`, 'u');
}

function replacementText(match: RegExpExecArray, replacement: string): string {
  let out = '';
  for (let i = 0; i < replacement.length; i++) {
    const ch = replacement[i];
    if (ch === '&') out += match[0];
    else if (ch !== '\\' || i + 1 >= replacement.length) out += ch;
    else {
      const next = replacement[++i]!;
      if (next === '&') out += '&';
      else if (next === '\\') out += '\\';
      else if (next === '0') out += match[0];
      else if (/[1-9]/.test(next)) out += match[Number(next)] ?? '';
      else out += next;
    }
  }
  return out;
}

export function substitute(doc: Text, fromLine: number, toLine: number, regex: RegExp, replacement: string, global: boolean): { changes: ChangeSpec[]; count: number; lines: number } {
  const changes: ChangeSpec[] = [];
  const changedLines = new Set<number>();
  let count = 0;
  const first = Math.max(1, Math.min(fromLine, doc.lines));
  const last = Math.max(first, Math.min(toLine, doc.lines));
  for (let number = first; number <= last; number++) {
    const line = doc.line(number);
    const scan = new RegExp(regex.source, regex.flags.includes('g') ? regex.flags : `${regex.flags}g`);
    scan.lastIndex = 0;
    let match: RegExpExecArray | null;
    while ((match = scan.exec(line.text)) !== null) {
      changes.push({ from: line.from + match.index, to: line.from + match.index + match[0].length, insert: replacementText(match, replacement) });
      count++;
      changedLines.add(number);
      if (!global) break;
      if (match[0].length === 0) {
        if (scan.lastIndex >= line.text.length) break;
        const cp = line.text.codePointAt(scan.lastIndex);
        scan.lastIndex += cp !== undefined && cp > 0xffff ? 2 : 1;
      }
    }
  }
  return { changes, count, lines: changedLines.size };
}
