// @vitest-environment node

import { EditorState } from '@codemirror/state';
import { describe, expect, it } from 'vitest';
import { selectTextObject } from '../textobjects';
import type { TextObjectKind } from '../types';

function select(marked: string, kind: TextObjectKind, around: boolean, count = 1, visual: { anchor: number; head: number } | null = null) {
  const cursor = marked.indexOf('|');
  const text = marked.replace('|', '');
  const state = EditorState.create({ doc: text });
  const result = selectTextObject(state.doc, cursor, { kind, around }, count, visual);
  return result && [result.from, result.to] as const;
}

describe('selectTextObject', () => {
  it.each([
    ['foo b|ar baz', 'w', false, 1, [4, 7]],
    ['foo |... bar', 'w', false, 1, [4, 7]],
    ['foo|   bar', 'w', false, 1, [3, 6]],
    ['foo| bar', 'w', true, 1, [3, 4]],
    ['|foo', 'w', true, 1, [0, 3]],
    ['|foo bar baz', 'w', false, 2, [0, 4]],
    ['|foo bar baz', 'w', true, 2, [0, 8]],
    ['|a.b c.d e', 'W', true, 2, [0, 8]],
    ['a.|b-c', 'W', false, 1, [0, 5]],
    ['|a.b-c rest', 'W', true, 1, [0, 6]],
    ['|sound-kit', 'w', false, 1, [0, 9]],
    ['e\u0301|x z', 'w', false, 1, [0, 3]],
    ['x "fo|o" y', '"', false, 1, [3, 6]],
    ['|x "foo" y', '"', true, 1, [2, 8]],
    ['x "fo\\"o|"', '"', false, 1, [3, 8]],
    ['x "foo\n|bar"', '"', false, 1, null],
    ['x \'fo|o\'', "'", false, 1, [3, 6]],
    ['|x \'foo\'', "'", true, 1, [1, 7]],
    ['x `fo|o`', '`', false, 1, [3, 6]],
    ['x `fo|o`', '`', true, 1, [1, 7]],
    ['x |(foo) y', '(', false, 1, [3, 6]],
    ['x |(foo) y', '(', true, 1, [2, 7]],
    ['(|foo)', '(', true, 1, [0, 5]],
    ['(a(|b)c)', '(', false, 2, [1, 6]],
    ['f {\n  |x\n}', '{', false, 1, [4, 7]],
    ['x [fo|o]', '[', false, 1, [3, 6]],
    ['x [fo|o]', '[', true, 1, [2, 7]],
    ['x {fo|o}', '{', false, 1, [3, 6]],
    ['x {fo|o}', '{', true, 1, [2, 7]],
    ['x <fo|o>', '<', false, 1, [3, 6]],
    ['x <fo|o>', '<', true, 1, [2, 7]],
    ['x (|)', '(', false, 1, [3, 3]],
    ['a (|x) b', '(', false, 1, [3, 4]],
    ['x (|foo', '(', false, 1, null],
    ['([|x])', '(', true, 1, [0, 5]],
  ] as const)('selects %s as %s/%s count %i', (marked, kind, around, count, expected) => {
    expect(select(marked, kind, around, count)).toEqual(expected);
  });

  it('returns null when a matching bracket is beyond the scan bound', () => {
    const doc = `(${`x`.repeat(65_536)}|)`;
    expect(select(doc, '(', false)).toBeNull();
  });

  it('expands an inclusive around visual bracket object to its enclosing pair', () => {
    expect(select('((|x))', '(', true, 1, { anchor: 1, head: 3 })).toEqual([0, 5]);
  });

  it('expands an inclusive inner visual bracket object to its enclosing pair', () => {
    expect(select('((x|y))', '(', false, 1, { anchor: 2, head: 3 })).toEqual([1, 5]);
  });

  it('expands a trimmed multi-line inner visual bracket object', () => {
    expect(select('{\n {\n  |x\n }\n}', '{', false, 1, { anchor: 5, head: 7 })).toEqual([2, 11]);
  });

  it('does not expand a non-matching visual bracket selection', () => {
    expect(select('((|x))', '(', true, 1, { anchor: 1, head: 2 })).toEqual([1, 4]);
  });
});
