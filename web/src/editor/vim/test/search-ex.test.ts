import { Text } from '@codemirror/state';
import { describe, expect, it } from 'vitest';
import { parseEx } from '../ex';
import { compilePattern, findMatch, substitute, wordPattern, wordUnderCursor } from '../search';

const doc = (value: string) => Text.of(value.split('\n'));
const ctx = (currentLine = 1, lastLine = 10, visual: { fromLine: number; toLine: number } | null = null) => ({ currentLine, lastLine, visual });
const change = (result: ReturnType<typeof substitute>, index = 0) => result.changes[index] as { from: number; to: number; insert: string };

describe('Vim search helpers', () => {
  it('compiles valid regex with Unicode mode', () => {
    const result = compilePattern('a+');
    expect(result.regex.flags).toContain('u');
    expect(result.regex.test('aaa')).toBe(true);
    expect(result.literal).toBe(false);
  });
  it('strips trailing case-insensitive marker', () => {
    const result = compilePattern('cat\\c');
    expect(result.regex.flags).toContain('i');
    expect(result.regex.test('CAT')).toBe(true);
  });
  it('uses empty regex for empty search', () => expect(compilePattern('').regex.source).toBe('(?:)'));
  it('falls back to escaped literal on invalid regex', () => {
    const result = compilePattern('((');
    expect(result.literal).toBe(true);
    expect(result.note).toBe('pattern compiled as literal text');
    expect(result.regex.test('((')).toBe(true);
  });
  it('finds next forward match', () => expect(findMatch(doc('a b a'), 0, /a/u, 1)).toEqual({ from: 4, to: 5, wrapped: false }));
  it('wraps forward search to first match', () => expect(findMatch(doc('a b a'), 5, /a/u, 1)).toEqual({ from: 0, to: 1, wrapped: true }));
  it('finds previous backward match', () => expect(findMatch(doc('a b a'), 5, /a/u, -1)).toEqual({ from: 4, to: 5, wrapped: false }));
  it('wraps backward search to last match', () => expect(findMatch(doc('a b a'), 0, /a/u, -1)).toEqual({ from: 4, to: 5, wrapped: true }));
  it('returns null when no match exists', () => expect(findMatch(doc('abc'), 0, /z/u, 1)).toBeNull());
  it('terminates zero-length search matches', () => expect(findMatch(doc('abc'), 0, /^/u, 1)).toEqual({ from: 0, to: 0, wrapped: true }));
  it('leaves caller regex lastIndex unchanged', () => {
    const regex = /a/gu; regex.lastIndex = 3;
    findMatch(doc('a a a'), 0, regex, 1);
    expect(regex.lastIndex).toBe(3);
  });
  it('reuses a document cache without changing match results', () => {
    const value = doc('x x');
    expect(findMatch(value, 0, /x/u, 1)).toEqual(findMatch(value, 0, /x/u, 1));
  });
  it('gets the word at the cursor', () => expect(wordUnderCursor(doc('one two'), 1)).toMatchObject({ from: 0, to: 3, text: 'one' }));
  it('gets the next word from a blank', () => expect(wordUnderCursor(doc('one two'), 3)?.text).toBe('two'));
  it('returns null when no word remains on the line', () => expect(wordUnderCursor(doc('one !'), 4)).toBeNull());
  it('matches a whole keyword', () => expect(wordPattern('kit').test('kit x')).toBe(true));
  it('does not match a word embedded after a keyword hyphen', () => expect(wordPattern('kit').test('sound-kit')).toBe(false));
  it('escapes regex syntax in wordPattern', () => expect(wordPattern('a.b').test('a.b ')).toBe(true));
  it('substitutes first occurrence on each line by default', () => {
    const result = substitute(doc('aa\naa'), 1, 2, /a/u, 'x', false);
    expect(result).toMatchObject({ count: 2, lines: 2 });
    expect(result.changes.map((c) => (c as { from: number }).from)).toEqual([0, 3]);
  });
  it('substitutes every occurrence with global flag', () => expect(substitute(doc('aaa'), 1, 1, /a/u, 'x', true).count).toBe(3));
  it('translates ampersand to whole match', () => expect(change(substitute(doc('cat'), 1, 1, /(a)/u, '&', false)).insert).toBe('a'));
  it('translates backslash zero to whole match', () => expect(change(substitute(doc('cat'), 1, 1, /(a)/u, '\\0', false)).insert).toBe('a'));
  it('translates numbered capture groups', () => expect(change(substitute(doc('cat'), 1, 1, /(a)/u, '<\\1>', false)).insert).toBe('<a>'));
  it('translates unmatched groups to empty', () => expect(change(substitute(doc('cat'), 1, 1, /(z)?a/u, '\\1x', false)).insert).toBe('x'));
  it('translates escaped ampersand to literal ampersand', () => expect(change(substitute(doc('a'), 1, 1, /a/u, '\\&', false)).insert).toBe('&'));
  it('keeps dollar replacement syntax literal', () => expect(change(substitute(doc('a'), 1, 1, /a/u, '$1', false)).insert).toBe('$1'));
  it('counts changed lines and changes across a range', () => expect(substitute(doc('a\nb\na'), 1, 3, /a/u, 'z', true)).toMatchObject({ count: 2, lines: 2 }));
  it('returns no changes for a nonmatching pattern', () => expect(substitute(doc('abc'), 1, 1, /z/u, 'x', false)).toEqual({ changes: [], count: 0, lines: 0 }));
  it('does not let a zero-width global substitution loop forever', () => expect(substitute(doc('ab'), 1, 1, /(?=.)/u, 'x', true).count).toBe(2));
});

describe('Ex command parser', () => {
  it.each([
    ['99', { kind: 'goto', line: 10 }],
    ['%', { kind: 'goto', line: 10 }],
    ['.', { kind: 'goto', line: 4 }],
    ['$ ', { kind: 'goto', line: 10 }],
    ['.+2', { kind: 'goto', line: 6 }],
    ['.-2', { kind: 'goto', line: 2 }],
    ['3,1', { kind: 'goto', line: 3 }],
    [':', { kind: 'empty' }],
  ])('parses range or empty command %s', (input, expected) => expect(parseEx(input, ctx(4))).toEqual(expected));
  it('parses a numeric address within the document', () => expect(parseEx('12', ctx(4, 20))).toEqual({ kind: 'goto', line: 12 }));
  it('parses whole-document substitution and flags', () => expect(parseEx('%s/a/b/gi', ctx())).toEqual({ kind: 'substitute', fromLine: 1, toLine: 10, pattern: 'a', replacement: 'b', global: true, ignoreCase: true }));
  it('parses visual marks when a visual range exists', () => expect(parseEx("'<,'>s/x/y/", ctx(1, 10, { fromLine: 2, toLine: 5 }))).toMatchObject({ kind: 'substitute', fromLine: 2, toLine: 5 }));
  it('errors for unset visual marks', () => expect(parseEx("'<,'>s/x/y/", ctx())).toEqual({ error: 'E20 Mark not set' }));
  it('supports a non-slash delimiter', () => expect(parseEx('s#a/b#c#', ctx())).toMatchObject({ kind: 'substitute', pattern: 'a/b', replacement: 'c' }));
  it('supports underscore as a substitute delimiter', () => expect(parseEx('s_a_b_', ctx())).toMatchObject({ kind: 'substitute', pattern: 'a', replacement: 'b' }));
  it('supports empty replacement and default dot to last range', () => expect(parseEx('.,$s/a//', ctx(4))).toMatchObject({ kind: 'substitute', fromLine: 4, toLine: 10, replacement: '' }));
  it('swaps reversed substitution ranges', () => expect(parseEx('3,1s/a/b/', ctx())).toMatchObject({ kind: 'substitute', fromLine: 1, toLine: 3 }));
  it('unescapes an escaped delimiter in fields', () => expect(parseEx('s#a\\#b#c\\#d#', ctx())).toMatchObject({ kind: 'substitute', pattern: 'a#b', replacement: 'c#d' }));
  it('preserves non-delimiter escapes in fields', () => expect(parseEx('s/a\\d/b/', ctx())).toMatchObject({ kind: 'substitute', pattern: 'a\\d' }));
  it('preserves an escaped backslash in the pattern and recognizes following flags', () => {
    const slash = '/';
    const backslash = String.fromCharCode(92);
    const result = parseEx(`s/${backslash}${backslash}/${backslash}${slash}/g`, ctx());
    expect(result).toMatchObject({ kind: 'substitute', pattern: backslash.repeat(2), replacement: slash, global: true });
  });
  it('preserves an escaped backslash in the replacement before flags', () => {
    const backslash = String.fromCharCode(92);
    const result = parseEx(`s/a/x${backslash}${backslash}/g`, ctx());
    expect(result).toMatchObject({ kind: 'substitute', pattern: 'a', replacement: `x${backslash}${backslash}`, global: true });
  });
  it('rejects unknown substitute flags', () => expect(parseEx('s/a/b/z', ctx())).toEqual({ error: 'E488 Trailing characters' }));
  it('accepts noh abbreviation', () => expect(parseEx('noh', ctx())).toEqual({ kind: 'noh' }));
  it('accepts nohlsearch', () => expect(parseEx('nohlsearch', ctx())).toEqual({ kind: 'noh' }));
  it.each([
    ['w', ['save']], ['w!', ['save']], ['write', ['save']], ['q', ['close']], ['q!', ['close']], ['quit', ['close']],
    ['wq', ['save', 'close']], ['wq!', ['save', 'close']], ['x', ['save', 'close']],
  ])('maps action %s', (name, actions) => expect(parseEx(name as string, ctx())).toEqual({ kind: 'action', actions }));
  it.each(['constructor', '__proto__', 'toString'])('does not resolve %s through the prototype', (name) => expect(parseEx(name, ctx())).toEqual({ error: `E492 Not an editor command: ${name}` }));
  it('reports unknown commands', () => expect(parseEx('foo', ctx())).toEqual({ error: 'E492 Not an editor command: foo' }));
  it('rejects substitute ranges past the document', () => expect(parseEx('20s/a/b/', ctx())).toEqual({ error: 'E16 Invalid range' }));
  it('accepts leading whitespace and colon', () => expect(parseEx('  :  2  ', ctx())).toEqual({ kind: 'goto', line: 2 }));
});
