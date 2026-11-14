import { EditorState } from '@codemirror/state';
import type { ChangeSpec } from '@codemirror/state';
import { describe, expect, it } from 'vitest';
import { applyOperator, joinLines, motionRange, openLine, putRegister, replaceChars, toggleCaseChars } from '../operators';
import type { MotionResult, OperatorKind, TextRange } from '../types';

function state(doc: string): EditorState { return EditorState.create({ doc }); }
function apply(doc: string, outcome: { changes: ChangeSpec; cursor: number }): { doc: string; cursor: number } {
  const next = state(doc).update({ changes: outcome.changes, selection: { anchor: outcome.cursor } }).state;
  return { doc: next.doc.toString(), cursor: next.selection.main.head };
}
function motion(pos: number, extra: Partial<MotionResult> = {}): MotionResult {
  return { pos, linewise: false, inclusive: false, desiredColumn: null, jump: false, ...extra };
}
function runOp(doc: string, op: OperatorKind, range: TextRange) {
  const result = applyOperator(state(doc), op, range);
  return { ...result, applied: result.changes === null ? doc : state(doc).update({ changes: result.changes }).state.doc.toString() };
}

describe('motionRange', () => {
  it.each([
    ['inclusive end includes grapheme', 'abc', 0, 1, true, null, 0, 2],
    ['exclusive motion', 'abc', 0, 2, false, null, 0, 2],
    ['operator adjusts next-line column zero', 'abc\ndef', 0, 4, false, 'd', 0, 3],
    ['motion without operator does not adjust', 'abc\ndef', 0, 4, false, null, 0, 4],
    ['backward motion sorts endpoints', 'abcdef', 4, 1, false, 'd', 1, 4],
    ['inclusive end is bounded by line', 'ab\ncd', 3, 4, true, null, 3, 5],
    ['zero range remains empty', 'abc', 1, 1, false, 'd', 1, 1],
  ])('%s', (_name, doc, from, pos, inclusive, op, expectedFrom, expectedTo) => {
    const result = motionRange(state(doc as string).doc, from as number, motion(pos as number, { inclusive: inclusive as boolean }), op as OperatorKind | null);
    expect([result.from, result.to]).toEqual([expectedFrom, expectedTo]);
  });
  it('uses full lines for a linewise motion', () => {
    expect(motionRange(state('a\nb\nc').doc, 2, motion(4, { linewise: true }), 'd')).toEqual({ from: 2, to: 5, linewise: true });
  });
  it('ends a linewise motion on an empty line at that line end', () => {
    expect(motionRange(state('a\n\nb').doc, 0, motion(2, { linewise: true }), 'd')).toEqual({ from: 0, to: 2, linewise: true });
  });
});

describe('applyOperator', () => {
  it.each([
    ['delete charwise', 'abcdef', 'd', { from: 1, to: 4, linewise: false }, 'aef', 1, 'bcd', false],
    ['change charwise', 'abcdef', 'c', { from: 1, to: 4, linewise: false }, 'aef', 1, 'bcd', true],
    ['delete middle line', 'one\ntwo\nthree', 'd', { from: 4, to: 7, linewise: true }, 'one\nthree', 4, 'two', false],
    ['delete final line uses leading break', 'one\ntwo', 'd', { from: 4, to: 7, linewise: true }, 'one', 0, 'two', false],
    ['delete whole document', 'one\ntwo', 'd', { from: 0, to: 7, linewise: true }, '', 0, 'one\ntwo', false],
    ['delete through an empty selected line', 'abc\n\nxyz', 'd', { from: 0, to: 4, linewise: true }, 'xyz', 0, 'abc\n', false],
    ['delete through empty line before final content', 'x\nabc\n\nz', 'd', { from: 2, to: 6, linewise: true }, 'x\nz', 2, 'abc\n', false],
    ['delete empty final line', 'abc\n', 'd', { from: 0, to: 4, linewise: true }, '', 0, 'abc\n', false],
    ['delete empty middle line', 'a\n\nb', 'd', { from: 2, to: 2, linewise: true }, 'a\nb', 2, '', false],
    ['change line keeps indent', '  foo\nbar', 'c', { from: 0, to: 5, linewise: true }, '  \nbar', 2, '  foo', true],
    ['change through an empty selected line', '  foo\n\nbar', 'c', { from: 0, to: 6, linewise: true }, '  \nbar', 2, '  foo\n', true],
  ])('%s', (_name, doc, op, range, expectedDoc, cursor, yanked, enterInsert) => {
    const result = runOp(doc as string, op as OperatorKind, range as TextRange);
    expect(result.applied).toBe(expectedDoc);
    expect(result.cursor).toBe(cursor);
    expect(result.yanked).toEqual({ text: yanked, linewise: (range as TextRange).linewise });
    expect(result.enterInsert).toBe(enterInsert);
  });
  it('yanks without changes and uses the sentinel for linewise cursor handling', () => {
    expect(runOp('abc', 'y', { from: 0, to: 2, linewise: false })).toMatchObject({ applied: 'abc', changes: null, cursor: 0, yanked: { text: 'ab', linewise: false } });
    expect(runOp('a\nb', 'y', { from: 0, to: 3, linewise: true })).toMatchObject({ changes: null, cursor: -1, yanked: { text: 'a\nb', linewise: true } });
  });
  it.each([
    ['indent nonblank lines', 'a\n\n b', '>', { from: 0, to: 5, linewise: true }, '  a\n\n   b'],
    ['unindent spaces and tab', '  a\n\tb', '<', { from: 0, to: 7, linewise: true }, 'a\nb'],
    ['indent charwise range expands to lines', 'a\nb', '>', { from: 0, to: 3, linewise: false }, '  a\n  b'],
  ])('%s', (_name, doc, op, range, expected) => {
    expect(runOp(doc as string, op as OperatorKind, range as TextRange).applied).toBe(expected);
  });
  it.each([
    ['upper expands sharp s', 'straße', 'gU', 'STRASSE'],
    ['toggle mixed case', 'aB', 'g~', 'Ab'],
    ['lower case', 'ABc', 'gu', 'abc'],
  ])('%s', (_name, doc, op, expected) => {
    expect(runOp(doc as string, op as OperatorKind, { from: 0, to: (doc as string).length, linewise: false }).applied).toBe(expected);
  });
});

describe('putRegister', () => {
  it.each([
    ['p repeats after cursor', 'abcd', 1, { text: 'X', linewise: false }, false, 3, 'abXXXcd', 4],
    ['P repeats before cursor', 'abcd', 2, { text: 'X', linewise: false }, true, 2, 'abXXcd', 3],
    ['p on empty line inserts at cursor', '', 0, { text: 'hi', linewise: false }, false, 1, 'hi', 1],
    ['multiline charwise put leaves cursor at start', 'ab', 0, { text: 'x\ny', linewise: false }, true, 1, 'x\nyab', 0],
    ['line p at last line', 'a\nb', 2, { text: 'x\ny', linewise: true }, false, 1, 'a\nb\nx\ny', 4],
    ['line P at first line', 'a\nb', 0, { text: 'x', linewise: true }, true, 1, 'x\na\nb', 0],
    ['line put count repeats', 'a', 0, { text: 'x', linewise: true }, false, 2, 'a\nx\nx', 2],
  ])('%s', (_name, doc, cursor, reg, before, count, expected, resultCursor) => {
    expect(apply(doc as string, putRegister(state(doc as string), cursor as number, reg as never, before as boolean, count as number))).toEqual({ doc: expected, cursor: resultCursor });
  });
});

describe('other edit builders', () => {
  it.each([
    ['join trims indent', 'one\n  two\nthree', 0, 2, 'one two\nthree', 3],
    ['join skips blank separator', 'one\n\ntwo', 0, 2, 'one\ntwo', 3],
    ['join count three lines', 'a\nb\nc\nd', 0, 3, 'a b c\nd', 3],
    ['join after trailing blank', 'one \ntwo', 0, 2, 'one two', 4],
  ])('%s', (_name, doc, cursor, count, expected, resultCursor) => {
    const result = joinLines(state(doc as string), cursor as number, count as number);
    expect(result).not.toBeNull();
    expect(apply(doc as string, result!)).toEqual({ doc: expected, cursor: resultCursor });
  });
  it('does not join from the last line', () => expect(joinLines(state('one'), 0, 2)).toBeNull());
  it.each([
    ['replace grapheme count', 'a😀c', 0, 'x', 2, 'xxc', 1],
    ['replace newline with one break', 'abcd', 1, '\n', 2, 'a\nd', 2],
    ['replace one grapheme', 'abc', 1, 'Z', 1, 'aZc', 1],
  ])('%s', (_name, doc, cursor, ch, count, expected, resultCursor) => {
    const result = replaceChars(state(doc as string), cursor as number, ch as string, count as number);
    expect(result).not.toBeNull();
    expect(apply(doc as string, result!)).toEqual({ doc: expected, cursor: resultCursor });
  });
  it('returns null when replace lacks enough graphemes', () => expect(replaceChars(state('abc'), 2, 'x', 2)).toBeNull());
  it.each([
    ['toggle case', 'aB', 0, 2, 'Ab', 2],
    ['case mapping can expand', 'ßa', 0, 1, 'SSa', 2],
    ['bounded at line end', 'ab\ncd', 1, 4, 'aB\ncd', 2],
  ])('%s', (_name, doc, cursor, count, expected, resultCursor) => {
    const result = toggleCaseChars(state(doc as string), cursor as number, count as number);
    expect(result).not.toBeNull();
    expect(apply(doc as string, result!)).toEqual({ doc: expected, cursor: resultCursor });
  });
  it('returns null when there is no character to toggle', () => expect(toggleCaseChars(state(''), 0, 1)).toBeNull());
  it.each([
    ['open below with indent', '  foo', 0, false, '  foo\n  ', 8],
    ['open above with indent', '  foo', 0, true, '  \n  foo', 2],
    ['open below empty line', '', 0, false, '\n', 1],
  ])('%s', (_name, doc, cursor, above, expected, resultCursor) => {
    expect(apply(doc as string, openLine(state(doc as string), cursor as number, above as boolean))).toEqual({ doc: expected, cursor: resultCursor });
  });
});
