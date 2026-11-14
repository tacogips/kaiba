import type { EditorState, Text } from '@codemirror/state';
import type { ParsedCommand } from './parser';
import { joinLines, type EditOutcome } from './operators';
import { textToTokens } from './record';
import type { RecordToken, TextRange, VimMode } from './types';
import { classAt, prevGrapheme, nextGrapheme } from './words';

export function changeWordEnd(doc: Text, cursor: number): number | null {
  const line = doc.lineAt(cursor);
  if (cursor >= line.to || line.length === 0) return null;
  const wordClass = classAt(line.text, cursor - line.from);
  if (wordClass === 0) return null;
  let end = nextGrapheme(doc, cursor);
  while (end < line.to && classAt(line.text, end - line.from) === wordClass) {
    const next = nextGrapheme(doc, end);
    if (next <= end || next > line.to) break;
    end = next;
  }
  return end;
}

export function commandInputTokens(command: ParsedCommand, pending: string): RecordToken[] {
  const keys = pending ? pending.split(/(?=<)/u).filter(Boolean) : [];
  if (keys.length) return keys.map((key) => ({ kind: 'key', key }));
  const actionKey = command.action === 'insert' ? 'i' : command.action === 'append' ? 'a' : command.action === 'replace-mode' ? 'R' : command.action === 'open-below' ? 'o' : command.action === 'open-above' ? 'O' : command.action === 'put-after' ? 'p' : command.action === 'put-before' ? 'P' : command.action === 'repeat' ? '.' : command.operator ?? '';
  return actionKey ? [{ kind: 'key', key: actionKey }] : [];
}

export function withoutCounts(tokens: readonly RecordToken[]): RecordToken[] {
  const keys = tokens.map((token) => token.kind === 'key' ? token.key : null);
  const removed = new Set<number>();
  const skipCount = (start: number): number => {
    if (!keys[start] || !/^[1-9]$/u.test(keys[start]!)) return start;
    let end = start + 1;
    while (end < keys.length && keys[end] !== null && /^[0-9]$/u.test(keys[end]!)) end++;
    for (let i = start; i < end; i++) removed.add(i);
    return end;
  };
  let index = skipCount(0);
  if (keys[index] === '"' && index + 1 < keys.length) index += 2;
  index = skipCount(index);
  const key = keys[index];
  const operatorLength = key && ['d', 'c', 'y', '>', '<'].includes(key) ? 1
    : key === 'g' && ['~', 'u', 'U'].includes(keys[index + 1] ?? '') ? 2 : 0;
  if (operatorLength) skipCount(index + operatorLength);
  return tokens.filter((_, tokenIndex) => !removed.has(tokenIndex)).map((token) => ({ ...token }));
}

export function visualRange(state: EditorState, anchor: number, head: number, mode: VimMode): TextRange {
  const from = Math.min(anchor, head);
  const last = Math.max(anchor, head);
  if (mode === 'visual-line') {
    return { from: state.doc.lineAt(from).from, to: state.doc.lineAt(last).to, linewise: true };
  }
  return { from, to: Math.min(nextGrapheme(state.doc, last), state.doc.length), linewise: false };
}

export function visualLineRange(state: EditorState, anchor: number, head: number): TextRange {
  const first = state.doc.lineAt(Math.min(anchor, head));
  const last = state.doc.lineAt(Math.max(anchor, head));
  return { from: first.from, to: last.to, linewise: true };
}

export function lineTargetRange(state: EditorState, cursor: number, count: number, visual: { anchor: number; head: number } | null): TextRange {
  if (visual) return visualLineRange(state, visual.anchor, visual.head);
  const first = state.doc.lineAt(cursor);
  return { from: first.from, to: state.doc.line(Math.min(state.doc.lines, first.number + count - 1)).to, linewise: true };
}

export function visualJoin(state: EditorState, cursor: number, count: number, visual: { anchor: number; head: number } | null): { outcome: EditOutcome | null; range: TextRange | null } {
  if (!visual) return { outcome: joinLines(state, cursor, count), range: null };
  const range = visualLineRange(state, visual.anchor, visual.head);
  const first = state.doc.lineAt(range.from), last = state.doc.lineAt(range.to);
  return { outcome: joinLines(state, first.from, last.number - first.number + 1), range };
}

export function repeatTokens(tokens: readonly RecordToken[], count: number | null): RecordToken[] {
  return count === null ? tokens.map((token) => ({ ...token })) : [...textToTokens(String(count)), ...tokens.map((token) => ({ ...token }))];
}

export function preserveChangeWordSeparator(doc: Text, range: TextRange, count: number): TextRange {
  if (count <= 1 || range.to <= range.from) return range;
  const separator = prevGrapheme(doc, range.to);
  return /^\s$/u.test(doc.sliceString(separator, range.to)) ? { ...range, to: separator } : range;
}

export function selectionForVisual(state: EditorState, range: TextRange): { anchor: number; head: number } {
  const last = range.to > range.from ? prevGrapheme(state.doc, range.to) : range.from;
  return { anchor: range.from, head: last };
}

export function visualReplaceChars(state: EditorState, range: TextRange, value: string): { changes: { from: number; to: number; insert: string }; cursor: number } {
  const count = Array.from(new Intl.Segmenter(undefined, { granularity: 'grapheme' }).segment(state.doc.sliceString(range.from, range.to))).length;
  return { changes: { from: range.from, to: range.to, insert: value.repeat(count) }, cursor: range.from };
}

export function isChanging(command: ParsedCommand, mode: VimMode): boolean {
  if (mode === 'visual' || mode === 'visual-line' || mode === 'visual-block') return false;
  if (command.operator) return command.operator !== 'y';
  return ['replace-char', 'toggle-case', 'join', 'join-raw', 'surround-add', 'surround-change', 'surround-delete', 'put-after', 'put-before', 'open-below', 'open-above', 'insert', 'append', 'insert-line-start', 'append-line-end', 'replace-mode'].includes(command.action ?? '');
}

