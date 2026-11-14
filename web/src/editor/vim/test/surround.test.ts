import { EditorState } from '@codemirror/state';
import { describe, expect, it } from 'vitest';
import type { EditOutcome } from '../operators';
import { CommandParser } from '../parser';
import { surroundAdd, surroundChange, surroundDelete, surroundPair } from '../surround';

const state = (doc: string) => EditorState.create({ doc });
const apply = (doc: string, outcome: EditOutcome | null): string => outcome ? state(doc).update({ changes: outcome.changes }).state.doc.toString() : doc;
describe('minimal surround helpers', () => {
  it('returns the supported bracket and quote pairs', () => {
    for (const ch of ['(', ')', 'b', '[', ']', 'r', '{', '}', 'B', '<', '>', 'a', '"', "'", '`']) expect(surroundPair(ch)).not.toBeNull();
    expect(surroundPair('x')).toBeNull();
  });
  it('adds spaced opening bracket surround around a word', () => {
    const s = state('foo'); const out = surroundAdd(s, { from: 0, to: 3, linewise: false }, '(');
    expect(apply('foo', out)).toBe('( foo )'); expect(out?.cursor).toBe(0);
  });
  it('adds tight closing bracket form around a word', () => expect(apply('foo', surroundAdd(state('foo'), { from: 0, to: 3, linewise: false }, ')'))).toBe('(foo)'));
  it('keeps alias surrounds tight', () => {
    expect(surroundPair('b')).toEqual({ open: '(', close: ')', space: false });
    const addParser = new CommandParser(); addParser.setExtended(true);
    let addResult: ReturnType<typeof addParser.feed> = { kind: 'pending' };
    for (const key of ['y', 's', 'i', 'w', 'b'] as const) addResult = addParser.feed(key, 'normal');
    expect(addResult).toMatchObject({ kind: 'command', command: { action: 'surround-add', arg: 'b' } });
    expect(apply('foo', surroundAdd(state('foo'), { from: 0, to: 3, linewise: false }, 'b'))).toBe('(foo)');
    const changeParser = new CommandParser(); changeParser.setExtended(true);
    let changeResult: ReturnType<typeof changeParser.feed> = { kind: 'pending' };
    for (const key of ['c', 's', ')', 'B'] as const) changeResult = changeParser.feed(key, 'normal');
    expect(changeResult).toMatchObject({ kind: 'command', command: { action: 'surround-change', arg: ')B' } });
    expect(apply('(x)', surroundChange(state('(x)'), 1, ')', 'B'))).toBe('{x}');
  });
  it('adds quote surround around a word', () => expect(apply('foo', surroundAdd(state('foo'), { from: 0, to: 3, linewise: false }, '"'))).toBe('"foo"'));
  it('adds linewise surround without indent or trailing blanks', () => expect(apply('  a b  ', surroundAdd(state('  a b  '), { from: 0, to: 7, linewise: true }, '"'))).toBe('  "a b"  '));
  it('deletes a spaced bracket pair', () => expect(apply('( a )', surroundDelete(state('( a )'), 2, '('))).toBe('a'));
  it('deletes a tight bracket pair when named by its closing character', () => expect(apply('(a)', surroundDelete(state('(a)'), 1, ')'))).toBe('a'));
  it('changes quotes', () => expect(apply('"x"', surroundChange(state('"x"'), 1, '"', "'"))).toBe("'x'"));
  it('deletes double quotes without consuming a trailing blank', () => {
    const outcome = surroundDelete(state('say "foo" bar'), 6, '"');
    expect(apply('say "foo" bar', outcome)).toBe('say foo bar');
    expect(outcome?.cursor).toBe(4);
  });
  it('deletes double quotes without consuming a leading blank', () =>
    expect(apply('x "foo"', surroundDelete(state('x "foo"'), 4, '"'))).toBe('x foo'));
  it('changes double quotes without consuming a trailing blank', () =>
    expect(apply('say "foo" bar', surroundChange(state('say "foo" bar'), 6, '"', "'"))).toBe("say 'foo' bar"));
  it('deletes single quotes while preserving adjacent blanks', () =>
    expect(apply("a 'b' c", surroundDelete(state("a 'b' c"), 3, "'"))).toBe('a b c'));
  it('changes tight brackets', () => expect(apply('(x)', surroundChange(state('(x)'), 1, ')', '['))).toBe('[ x ]'));
  it('changes spaced brackets to tight closing form', () => expect(apply('( x )', surroundChange(state('( x )'), 2, '(', ']'))).toBe('[x]'));
  it('returns null for unsupported pair characters', () => {
    expect(surroundAdd(state('x'), { from: 0, to: 1, linewise: false }, 'q')).toBeNull();
    expect(surroundDelete(state('(x)'), 1, 'q')).toBeNull();
  });
  it('returns null when the requested pair is absent', () => expect(surroundDelete(state('plain'), 2, '(')).toBeNull());
});
