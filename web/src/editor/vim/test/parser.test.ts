import { describe, expect, it } from 'vitest';
import { CommandParser, type ParseResult } from '../parser';
import type { VimKey, VimMode } from '../types';

function run(keys: VimKey[], mode: VimMode = 'normal'): ParseResult {
  const parser = new CommandParser();
  let result: ParseResult = { kind: 'pending' };
  for (const key of keys) result = parser.feed(key, mode);
  return result;
}
const motion = (kind: string, char?: string) => ({ kind: 'motion', motion: char === undefined ? { kind } : { kind, char } });
const command = (operator: string | null, target: unknown, count: number | null = null, register: string | null = null, action: string | null = null, arg: string | null = null) => ({ kind: 'command', command: { register, count, operator, target, action, arg } });

describe('CommandParser normal commands', () => {
  it.each([
    [['h'], command(null, motion('h'))], [['<Left>'], command(null, motion('h'))], [['<Right>'], command(null, motion('l'))],
    [['<Up>'], command(null, motion('k'))], [['<Down>'], command(null, motion('j'))], [['<Home>'], command(null, motion('0'))],
    [['<End>'], command(null, motion('$'))], [['<BS>'], command(null, motion('BS'))], [['<CR>'], command(null, motion('+'))],
    [['<C-d>'], command(null, motion('C-d'))], [['<C-u>'], command(null, motion('C-u'))], [['<C-f>'], command(null, motion('C-f'))],
    [['<C-b>'], command(null, motion('C-b'))], [['g', 'g'], command(null, motion('gg'))], [['g', 'e'], command(null, motion('ge'))],
    [['n'], command(null, { kind: 'search', which: 'n' })], [['N'], command(null, { kind: 'search', which: 'N' })],
    [['*'], command(null, { kind: 'search', which: '*' })], [['#'], command(null, { kind: 'search', which: '#' })],
    [['`', 'a'], command(null, { kind: 'mark', name: 'a', exact: true })], [["'", 'a'], command(null, { kind: 'mark', name: 'a', exact: false })],
    [["'", "'"], command(null, { kind: 'mark', name: "'", exact: false })], [['`', '`'], command(null, { kind: 'mark', name: '`', exact: true })],
    [['f', 'x'], command(null, motion('f', 'x'))], [['F', 'x'], command(null, motion('F', 'x'))], [['t', ')'], command(null, motion('t', ')'))], [['T', 'x'], command(null, motion('T', 'x'))],
    [['f', '<'], command(null, motion('f', '<'))], [['F', '<'], command(null, motion('F', '<'))], [['t', '<'], command(null, motion('t', '<'))], [['T', '<'], command(null, motion('T', '<'))],
    [['f', '<Tab>'], { kind: 'invalid', message: null }], [['f', '<Other>'], { kind: 'invalid', message: null }],
    [['0'], command(null, motion('0'))], [['1', '0', 'j'], command(null, motion('j'), 10)], [['9', '9', '9', '9', '9', 'j'], command(null, motion('j'), 10000)],
  ] as [VimKey[], unknown][])('parses %j', (keys, expected) => expect(run(keys)).toEqual(expected));

  it.each([
    [['d', 'd'], command('d', { kind: 'line' })], [['3', 'd', 'd'], command('d', { kind: 'line' }, 3)], [['d', '2', 'd'], command('d', { kind: 'line' }, 2)], [['2', 'd', '3', 'd'], command('d', { kind: 'line' }, 6)],
    [['d', '2', 'w'], command('d', motion('w'), 2)], [['2', 'd', '3', 'w'], command('d', motion('w'), 6)],
    [['d', 't', '<'], command('d', motion('t', '<'))], [['d', 't', ')'], command('d', motion('t', ')'))],
    [['"', 'A', 'y', 'y'], command('y', { kind: 'line' }, null, 'A')], [['"', '%'], { kind: 'invalid', message: 'E354 Invalid register name' }],
    [['g', 'U', 'i', 'w'], command('gU', { kind: 'textobject', spec: { around: false, kind: 'w' } })],
    [['g', '~', '~'], command('g~', { kind: 'line' })], [['g', '~', 'g', '~'], command('g~', { kind: 'line' })],
    [['g', 'u', 'u'], command('gu', { kind: 'line' })], [['g', 'u', 'g', 'u'], command('gu', { kind: 'line' })],
    [['g', 'U', 'U'], command('gU', { kind: 'line' })], [['g', 'U', 'g', 'U'], command('gU', { kind: 'line' })],
    [['c', 'i', '('], command('c', { kind: 'textobject', spec: { around: false, kind: '(' } })],
    [['c', 'i', 'b'], command('c', { kind: 'textobject', spec: { around: false, kind: '(' } })],
    [['d', 'a', '<'], command('d', { kind: 'textobject', spec: { around: true, kind: '<' } })],
    [['d', 'i', '}'], command('d', { kind: 'textobject', spec: { around: false, kind: '{' } })],
    [['y', 'a', 'W'], command('y', { kind: 'textobject', spec: { around: true, kind: 'W' } })],
    [['d', 'i', 'q'], { kind: 'invalid', message: null }], [['d', 'p'], { kind: 'invalid', message: null }],
    [['d', '/'], { kind: 'invalid', message: 'search prompt cannot follow an operator' }], [['d', '?'], { kind: 'invalid', message: 'search prompt cannot follow an operator' }],
    [['x'], command('d', motion('l'))], [['<Del>'], command('d', motion('l'))], [['X'], command('d', motion('h'))],
    [['s'], command('c', motion('l'))], [['S'], command('c', { kind: 'line' })], [['D'], command('d', motion('$'))],
    [['C'], command('c', motion('$'))], [['Y'], command('y', { kind: 'line' })],
  ] as [VimKey[], unknown][])('parses operator form %j', (keys, expected) => expect(run(keys)).toEqual(expected));

  it.each([
    [['i'], command(null, null, null, null, 'insert')], [['a'], command(null, null, null, null, 'append')],
    [['I'], command(null, null, null, null, 'insert-line-start')], [['A'], command(null, null, null, null, 'append-line-end')],
    [['o'], command(null, null, null, null, 'open-below')], [['O'], command(null, null, null, null, 'open-above')],
    [['R'], command(null, null, null, null, 'replace-mode')], [['v'], command(null, null, null, null, 'visual')],
    [['V'], command(null, null, null, null, 'visual-line')], [['p'], command(null, null, null, null, 'put-after')],
    [['P'], command(null, null, null, null, 'put-before')], [['~'], command(null, null, null, null, 'toggle-case')],
    [['J'], command(null, null, null, null, 'join')], [['u'], command(null, null, null, null, 'undo')],
    [['<C-r>'], command(null, null, null, null, 'redo')], [['.'], command(null, null, null, null, 'repeat')],
    [['r', '<CR>'], command(null, null, null, null, 'replace-char', '\n')], [['r', 'x'], command(null, null, null, null, 'replace-char', 'x')], [['r', '<'], command(null, null, null, null, 'replace-char', '<')],
    [['q', 'a'], command(null, null, null, null, 'record', 'a')], [['q', 'A'], command(null, null, null, null, 'record', 'A')],
    [['@', 'a'], command(null, null, null, null, 'play', 'a')], [['@', '@'], command(null, null, null, null, 'play', '@')],
    [['m', 'a'], command(null, null, null, null, 'set-mark', 'a')], [['q', '1'], { kind: 'invalid', message: null }],
    [[':',], command(null, null, null, null, 'prompt', ':')], [['/'], command(null, null, null, null, 'prompt', '/')], [['?'], command(null, null, null, null, 'prompt', '?')],
    [['f', '<Esc>'], { kind: 'invalid', message: null }], [['r', '<Esc>'], { kind: 'invalid', message: null }], [['d', '<Esc>'], command(null, null, null, null, 'escape')],
  ] as [VimKey[], unknown][])('parses action %j', (keys, expected) => expect(run(keys)).toEqual(expected));
});

describe('CommandParser visual modes and pending state', () => {
  it.each([
    [['i', 'w'], { kind: 'command', command: { register: null, count: null, operator: null, target: { kind: 'textobject', spec: { around: false, kind: 'w' } }, action: null, arg: null } }],
    [['a', '"'], { kind: 'command', command: { register: null, count: null, operator: null, target: { kind: 'textobject', spec: { around: true, kind: '"' } }, action: null, arg: null } }],
    [['d'], command('d', null)], [['D'], command('d', { kind: 'line' })], [['X'], command('d', { kind: 'line' })],
    [['C'], command('c', { kind: 'line' })], [['S'], command('c', { kind: 'line' })], [['R'], command('c', { kind: 'line' })],
    [['Y'], command('y', { kind: 'line' })], [['s'], command('c', null)], [['~'], command('g~', null)], [['g', '~'], command('g~', null)],
    [['o'], command(null, null, null, null, 'visual-swap')], [['v'], command(null, null, null, null, 'visual')],
    [['V'], command(null, null, null, null, 'visual-line')], [['r', 'x'], command(null, null, null, null, 'replace-char', 'x')],
    [['r', '<'], command(null, null, null, null, 'replace-char', '<')],
    [['J'], command(null, null, null, null, 'join')], [['p'], command(null, null, null, null, 'put-after')],
    [['P'], command(null, null, null, null, 'put-before')], [[':'], command(null, null, null, null, 'prompt', ':')],
    [['"', 'a', 'y'], command('y', null, null, 'a')], [['2', 'd'], command('d', null, 2)],
  ] as [VimKey[], unknown][])('parses visual %j', (keys, expected) => expect(run(keys, 'visual')).toEqual(expected));

  it('keeps incomplete register/count/operator state and clears it after completion', () => {
    const parser = new CommandParser();
    expect(parser.feed('"', 'normal')).toEqual({ kind: 'pending' });
    expect(parser.feed('a', 'normal')).toEqual({ kind: 'pending' });
    expect(parser.feed('2', 'normal')).toEqual({ kind: 'pending' });
    expect(parser.pending()).toBe('"a2');
    expect(parser.operatorPending()).toBe(false);
    expect(parser.feed('d', 'normal')).toEqual({ kind: 'pending' });
    expect(parser.operatorPending()).toBe(true);
    expect(parser.feed('w', 'normal')).toEqual(command('d', motion('w'), 2, 'a'));
    expect(parser.pending()).toBe('');
    expect(parser.operatorPending()).toBe(false);
  });
  it('resets all pending state after invalid input', () => {
    const parser = new CommandParser();
    parser.feed('d', 'normal');
    expect(parser.feed('p', 'normal')).toEqual({ kind: 'invalid', message: null });
    expect(parser.pending()).toBe('');
    expect(parser.operatorPending()).toBe(false);
    expect(parser.feed('j', 'normal')).toEqual(command(null, motion('j')));
  });
  it('tracks operator pending after a count and register prefix', () => {
    const parser = new CommandParser();
    parser.feed('2', 'normal'); parser.feed('"', 'normal'); parser.feed('a', 'normal'); parser.feed('d', 'normal');
    expect(parser.operatorPending()).toBe(true);
  });
  it('distinguishes pending g, operator g-prefix, and Escape reset', () => {
    const parser = new CommandParser();
    parser.feed('g', 'normal');
    expect(parser.operatorPending()).toBe(false);
    parser.reset();
    parser.feed('g', 'normal'); parser.feed('u', 'normal');
    expect(parser.operatorPending()).toBe(true);
    expect(parser.feed('<Esc>', 'normal')).toEqual(command(null, null, null, null, 'escape'));
    expect(parser.pending()).toBe('');
  });
});
