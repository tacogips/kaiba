import { Text } from '@codemirror/state';
import { describe, expect, it } from 'vitest';
import { assignLabels, HOP_TARGET_LIMIT, HopSession, hopTargets, type HopKind, type HopSource } from '../hop';

function source(value: string, cursor: number, options: { topLine?: number; rows?: number; isVisible?: (pos: number) => boolean } = {}): HopSource {
  return {
    doc: Text.of(value.split('\n')),
    cursor,
    viewport: { topLine: options.topLine ?? 1, rows: options.rows ?? 10 },
    isVisible: options.isVisible ?? (() => true),
  };
}

function session(kind: HopKind, value: string, cursor: number, settings = { keys: 'abc', uppercaseLabels: false }, options: Parameters<typeof source>[2] = {}): HopSession {
  return new HopSession(kind, settings, source(value, cursor, options));
}

describe('hop label assignment', () => {
  it('uses the alphabet in order for one-key labels', () => expect(assignLabels(3, 'abc')).toEqual(['a', 'b', 'c']));
  it('expands the final label first', () => expect(assignLabels(4, 'abc')).toEqual(['a', 'b', 'ca', 'cb']));
  it.each([1, 26, 27, 100, 700])('keeps labels unique and prefix-free for %i targets', (count) => {
    const labels = assignLabels(count, 'fdjhklsagqwertyuiopzxcvbnm');
    expect(new Set(labels).size).toBe(labels.length);
    expect(labels.every((label, i) => labels.every((other, j) => i === j || !other.startsWith(label)))).toBe(true);
  });
  it('caps generated labels at the target limit', () => expect(assignLabels(5000, 'abc')).toHaveLength(HOP_TARGET_LIMIT));
});

describe('hop targets', () => {
  it('finds grapheme starts nearest-first and excludes the cursor', () => {
    const src = source('foo bar\nfoo', 1);
    expect(hopTargets(src, 'char1', 'o')).toEqual([2, 9, 10]);
  });
  it('matches uppercase ASCII when the typed character is lowercase', () => {
    const src = source('fF|f'.replace('|', ''), 2);
    expect(hopTargets(src, 'char1', 'f')).toEqual([1, 0]);
    expect(hopTargets(src, 'char1', 'F')).toEqual([1]);
  });
  it('limits char1Line to the cursor line', () => expect(hopTargets(source('o\noo', 2), 'char1Line', 'o')).toEqual([3]));
  it('excludes positions rejected by the visibility predicate', () => expect(hopTargets(source('foofoo', 3, { isVisible: (pos) => pos < 4 }), 'char1', 'o')).toEqual([2, 1]));
  it('limits scanning to visible viewport lines', () => expect(hopTargets(source('x\no\no', 0, { topLine: 2, rows: 1 }), 'char1', 'o')).toEqual([2]));
  it('collects starts of word-class runs', () => expect(hopTargets(source('ab  cd.ef', 0), 'word', null)).toEqual([4, 6, 7]));
  it('uses first non-blank positions and skips blank lines', () => expect(hopTargets(source('  a\n \t\n b', 0), 'line', null)).toEqual([2, 8]));
  it('orders tied positions forward before backward', () => expect(hopTargets(source('xox', 1), 'char1', 'x')).toEqual([2, 0]));
  it('caps target collection at 4096', () => expect(hopTargets(source('o'.repeat(5000), 0), 'char1', 'o')).toHaveLength(HOP_TARGET_LIMIT));
});

describe('hop session', () => {
  it('waits for the character, then jumps to the first label', () => {
    const hop = session('char1', 'foo', 0);
    expect(hop.start()).toEqual({ kind: 'pending', view: null, prompt: 'hop' });
    const pending = hop.feed('o');
    expect(pending.kind).toBe('pending');
    if (pending.kind !== 'pending' || !pending.view) throw new Error('expected hop view');
    expect(hop.feed(pending.view.labels[0]!.text)).toEqual({ kind: 'jump', pos: 1 });
  });
  it('narrows multikey labels and increments the view revision', () => {
    const hop = session('word', 'a b c', 1, { keys: 'ab', uppercaseLabels: false });
    const initial = hop.start();
    if (initial.kind !== 'pending' || !initial.view) throw new Error('expected hop view');
    expect(initial.view.labels.map((label) => label.text)).toEqual(['a', 'ba', 'bb']);
    const narrowed = hop.feed('b');
    expect(narrowed.kind).toBe('pending');
    if (narrowed.kind !== 'pending' || !narrowed.view) throw new Error('expected narrowed view');
    expect(narrowed.view.revision).toBe(initial.view.revision + 1);
    expect(narrowed.view.labels.map((label) => label.text)).toEqual(['a', 'b']);
    expect(hop.feed('a')).toEqual({ kind: 'jump', pos: 0 });
  });
  it('displays uppercase labels and accepts lowercase input', () => {
    const hop = session('word', 'a b', 0, { keys: 'ab', uppercaseLabels: true });
    const pending = hop.start();
    if (pending.kind !== 'pending' || !pending.view) throw new Error('expected hop view');
    expect(pending.view.labels[0]!.text).toBe('A');
    expect(hop.feed('a')).toEqual({ kind: 'jump', pos: 2 });
  });
  it('cancels on Escape while waiting for a character or label', () => {
    expect(session('char1', 'a', 0).feed('<Esc>')).toEqual({ kind: 'cancel', message: null });
    expect(session('word', 'a b', 0).feed('<Esc>')).toEqual({ kind: 'cancel', message: null });
  });
  it('cancels non-printable character input and unmatched labels', () => {
    expect(session('char1', 'a', 0).feed('<Left>')).toEqual({ kind: 'cancel', message: null });
    expect(session('char1', 'a', 0).feed('\n')).toEqual({ kind: 'cancel', message: null });
    const hop = session('word', 'a b', 0, { keys: 'ab', uppercaseLabels: false });
    hop.start();
    expect(hop.feed('z')).toEqual({ kind: 'cancel', message: null });
  });
  it('reports no match for empty target sets', () => expect(session('char1', 'abc', 1).feed('z')).toEqual({ kind: 'cancel', message: 'hop: no match' }));
});
