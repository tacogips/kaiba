import { EditorState } from '@codemirror/state';
import { describe, expect, it } from 'vitest';
import { SCAN_LIMIT, type MotionContext, type MotionKind } from '../types';
import { runMotion } from '../motions';

const context = (extra: Partial<MotionContext> = {}): MotionContext => ({ count: 1, explicitCount: false, desiredColumn: null, viewport: { topLine: 1, rows: 10 }, lastFind: null, ...extra });
const move = (text: string, kind: MotionKind, pos: number, extra: Partial<MotionContext> = {}, char?: string) => runMotion(EditorState.create({ doc: text }).doc, pos, { kind, char }, context(extra));
const cursor = (fixture: string, kind: MotionKind, extra: Partial<MotionContext> = {}, char?: string) => {
  const pos = fixture.indexOf('|'); return move(fixture.replace('|', ''), kind, pos, extra, char);
};
const cases: [string, MotionKind, number][] = [
  ['|abc', 'h', 0], ['a|bc', 'h', 0], ['ab|c', 'h', 1], ['|abc', 'l', 1], ['a|bc', 'l', 2], ['ab|c', 'l', 2], ['a|bc', 'l', 2],
  ['|abc', '0', 0], ['ab|c', '0', 0], ['  |x', '^', 2], ['|  x', '^', 2], ['ab|c', '$', 2], ['ab\n|cd', 'BS', 1],
  ['|foo.bar baz', 'w', 3], ['|foo.bar baz', 'W', 8], ['sound-kit |x', 'w', 11], ['foo| bar', 'w', 4],
  ['foo|\n\nbar', 'w', 4], ['|foo\nbar', 'w', 4], ['|a.\n.b', 'w', 1],
  ['|foo bar', 'e', 2], ['f|oo bar', 'e', 2], ['foo |bar baz', 'e', 6],
  ['f|oo\nbar', 'e', 2], ['fo|o\nbar', 'e', 6], ['fo|o\n\nbar', 'e', 7],
  ['foo bar| baz', 'b', 4], ['foo |bar baz', 'b', 0], ['foo |bar baz', 'B', 0],
  ['foo\nb|ar', 'b', 4], ['foo\n|bar', 'b', 0], ['foo.bar| baz', 'ge', 6],
  ['foo b|ar', 'ge', 2], ['foo.|bar', 'ge', 3], ['foo\n|bar', 'ge', 2],
  ['|foo bar', 'E', 2], ['|foo bar', 'W', 4], ['foo| bar', 'B', 0], ['|foo bar', 'ge', 0],
  ['abcdef|\nab\nabcdef', 'j', 8], ['a|\nb', 'j', 2], ['  a\n|  b\n c', '+', 9],
  ['a|\nb\nc', 'gg', 0], ['a\nb|\nc', 'G', 4], ['a\nb\nc\n|d', 'H', 0],
  ['|one\n\ntwo', '}', 4], ['one\n\ntwo|', '{', 4], ['|one\ntwo', '{', 0],
];
it.each(cases)('motion %s %s => %i', (fixture, kind, expected) => expect(cursor(fixture, kind)?.pos).toBe(expected));

describe('motion counts and columns', () => {
  it('moves j/k by count and returns null when clamped at the edge', () => {
    expect(move('a\nb\nc', 'j', 0, { count: 2, explicitCount: true })?.pos).toBe(4);
    expect(move('a\nb\nc', 'j', 4, { count: 4, explicitCount: true })).toBeNull();
    expect(move('a\nb\nc', 'k', 0)).toBeNull();
    expect(move('a\nb\nc', 'k', 4)?.pos).toBe(2);
    expect(move('a\nb\nc', '+', 0, { count: 2 })?.pos).toBe(4);
  });
  it('keeps desired column across a short line and restores it on the next line', () => {
    const doc = 'abcdef\nab\nabcdef';
    const first = move(doc, 'j', 5)!; expect(first).toMatchObject({ pos: 8, desiredColumn: 5, linewise: true });
    expect(move(doc, 'j', first.pos, { desiredColumn: first.desiredColumn })?.pos).toBe(15);
    expect(move(doc, 'j', 0, { count: 5, explicitCount: true })?.pos).toBe(10);
  });
  it('handles counted dollar and line jump destinations', () => {
    expect(move('abc\nxyz', '$', 0, { count: 2, explicitCount: true })).toMatchObject({ pos: 6, desiredColumn: Infinity, inclusive: true });
    expect(move('a\nb\nc', 'gg', 0, { count: 2, explicitCount: true })?.pos).toBe(2);
    expect(move('a\nb\nc', 'G', 0, { count: 2, explicitCount: true })?.pos).toBe(2);
    for (const kind of ['gg', 'G', 'H', 'M', 'L'] as MotionKind[]) expect(move('a\nb\nc', kind, 0)?.jump).toBe(true);
  });
  it('uses viewport rows for H M L and half-page/page scrolling', () => {
    const text = Array.from({ length: 40 }, (_, i) => String(i + 1)).join('\n');
    const view = { topLine: 5, rows: 10 };
    const doc = EditorState.create({ doc: text }).doc;
    expect(move(text, 'H', 0, { viewport: view, count: 2 })?.pos).toBe(doc.line(6).from);
    expect(move(text, 'M', 0, { viewport: view })?.pos).toBe(doc.line(9).from);
    expect(move(text, 'L', 0, { viewport: view, count: 2 })?.pos).toBe(doc.line(13).from);
    const pages = Array(40).fill('x').join('\n');
    expect(move(pages, 'C-d', 0)).toMatchObject({ pos: 10, scrollLines: 5, linewise: true });
    expect(move(pages, 'C-f', 0)).toMatchObject({ pos: 16, scrollLines: 8 });
    expect(move(pages, 'C-u', 0)).toMatchObject({ pos: 0, scrollLines: -5 });
    expect(move(pages, 'C-b', 30)).toMatchObject({ pos: 14, scrollLines: -8 });
    expect(move(pages, 'C-d', 0, { count: 3, explicitCount: true })?.scrollLines).toBe(3);
  });
});

describe('find and repeat motions', () => {
  it.each([
    ['abc def def', 'f', 0, 2, 'd', 8], ['abc def', 't', 0, 1, 'd', 3],
    ['abc def', 'F', 6, 1, 'a', 0], ['abc def', 'T', 6, 1, 'a', 1],
    ['abca', 'f', 0, 1, 'a', 3], ['abcabc', 't', 0, 1, 'c', 1],
    ['abcabc', 'F', 5, 1, 'a', 3], ['abcabc', 'T', 5, 1, 'a', 4],
    ['abab', 'f', 0, 2, 'b', 3], ['abab', 't', 0, 2, 'b', 2],
    ['abc', 'f', 0, 1, 'z', -1], ['abc', 'F', 0, 1, 'z', -1],
    ['abc', 't', 0, 1, 'z', -1], ['abc', 'T', 0, 1, 'z', -1],
  ] as [string, 'f' | 'F' | 't' | 'T', number, number, string, number][])('find %s %s', (text, kind, pos, count, char, expected) => {
    const result = move(text, kind, pos, { count }, char);
    if (expected < 0) expect(result).toBeNull(); else expect(result?.pos).toBe(expected);
  });
  it('repeats and reverses the last find, including till adjacency', () => {
    expect(move('abc def def', ';', 3, { lastFind: { kind: 'f', char: 'd' } })?.pos).toBe(4);
    expect(move('d abc def', ',', 6, { lastFind: { kind: 'f', char: 'd' } })?.pos).toBe(0);
    expect(move('abc', ';', 0)).toBeNull();
    expect(move('xxyx', ';', 0, { lastFind: { kind: 't', char: 'x' } })?.pos).toBe(2);
  });
  it('uses grapheme boundaries for horizontal and word movement', () => {
    expect(move('éx', 'l', 0)?.pos).toBe(2);
    expect(move('😀x', 'l', 0)?.pos).toBe(2);
    expect(move('foo bar', 'w', 4)?.pos).toBe(7);
    expect(move('foo bar baz', 'w', 0, { count: 2 })?.pos).toBe(8);
    expect(move('a b c', 'ge', 4, { count: 2 })).toMatchObject({ pos: 0, inclusive: true });
  });
});

describe('end-of-word motions from single-grapheme classes', () => {
  it.each([
    ['a bc', 'e', 0, 3],
    ['x = 1;', 'e', 0, 2],
    ['foo.bar', 'e', 3, 6],
    ['a b c', 'E', 0, 2],
    ['a\n\nbc', 'e', 0, 4],
    ['é bc', 'e', 0, 3],
  ] as [string, 'e' | 'E', number, number][])('%s %s at %i => %i', (text, kind, pos, expected) => {
    expect(move(text, kind, pos)?.pos).toBe(expected);
  });
  it('applies counts across one-grapheme word and punctuation runs', () => {
    expect(move('i = 0', 'e', 0, { count: 2, explicitCount: true })?.pos).toBe(4);
  });
});

describe('bracket and paragraph motions', () => {
  it.each([
    ['f(x) + g(y)', 3, 1], ['(a) (b)', 2, 0], ['f(x)(y)', 3, 1], ['f(x)(y)', 1, 3],
    ['(a [b] c)', 0, 8], ['(a [b] c)', 1, 5], ['(a [b] c)', 3, 5], ['(a [b] c)', 5, 3], ['(a [b] c)', 8, 0],
    ['fn {\n  x = foo(a)\n}', 7, 16], ['[x, f(y)]', 1, 7], ['foo(bar)', 0, 7],
  ] as [string, number, number][])('matches the first bracket on the line in %s at %i', (text, pos, expected) => {
    expect(move(text, '%', pos)?.pos).toBe(expected);
  });
  it('returns null for unmatched brackets and matches beyond SCAN_LIMIT', () => {
    expect(move('x) (abc', '%', 3)).toBeNull();
    expect(move('(abc', '%', 0)).toBeNull();
    expect(move(`(${''.padEnd(SCAN_LIMIT + 10, 'x')})`, '%', 0)).toBeNull();
    expect(move(`${'x'.repeat(SCAN_LIMIT + 1)}()`, '%', 0)).toBeNull();
  });
  it('moves between blank paragraph lines with both directions', () => {
    expect(move('one\n\ntwo\nthree', '}', 0)?.pos).toBe(4);
    expect(move('one\n\ntwo\nthree', '{', 6)?.pos).toBe(4);
    expect(move('one\ntwo', '}', 0)?.pos).toBe(7);
    expect(move('one\n\ntwo', '{', 0)?.pos).toBe(0);
    const oversizedLine = 'x'.repeat(SCAN_LIMIT + 1);
    expect(move(`start\n${oversizedLine}\n\nend`, '}', 0)).toBeNull();
    const backwardDoc = `start\n\n${oversizedLine}\nend`;
    expect(move(backwardDoc, '{', backwardDoc.length - 1)).toBeNull();
    const exactBudgetLine = 'x'.repeat(SCAN_LIMIT - 1);
    expect(move(`start\n${exactBudgetLine}\n\nend`, '}', 0)).toBeNull();
    const exactBudgetBackwardDoc = `start\n\n${exactBudgetLine}\nend`;
    expect(move(exactBudgetBackwardDoc, '{', exactBudgetBackwardDoc.length - 1)).toBeNull();
  });
});
