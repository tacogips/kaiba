import { describe, expect, it } from 'vitest';
import { CommandParser } from '../parser';
import type { VimKey, VimMode } from '../types';

function run(keys: VimKey[], extended = true, mode: VimMode = 'normal') {
  const parser = new CommandParser(); parser.setExtended(extended);
  let result = { kind: 'pending' as const } as ReturnType<typeof parser.feed>;
  for (const key of keys) result = parser.feed(key, mode);
  return result;
}
const motion = (kind: string) => ({ kind: 'command', command: { register: null, count: null, operator: null, target: { kind: 'motion', motion: { kind } }, action: null, arg: null } });
const action = (name: string, count: number | null = null, arg: string | null = null, target: unknown = null) => ({ kind: 'command', command: { register: null, count, operator: null, target, action: name, arg } });

describe('extended Vim grammar', () => {
  it.each(['gj', 'gk', 'g;', 'g,'])('leaves %s unchanged when extended is off', (notation) => {
    expect(run([...notation], false).kind).not.toBe('command');
  });
  it.each([[['g', 'j'], motion('j')], [['g', 'k'], motion('k')], [['g', ';'], motion('g;')], [['g', ','], motion('g,')]] as [VimKey[], unknown][])('parses extended motion %j', (keys, expected) => expect(run(keys)).toEqual(expected));
  it('parses operator and visual extended motions', () => {
    expect(run(['d', 'g', 'k'])).toMatchObject({ kind: 'command', command: { operator: 'd', target: { kind: 'motion', motion: { kind: 'k' } } } });
    expect(run(['g', 'j'], true, 'visual')).toMatchObject({ kind: 'command', command: { target: { kind: 'motion', motion: { kind: 'j' } } } });
  });
  it.each([[['g', 'J'], action('join-raw')], [['z', 'z'], action('scroll-center')], [['2', '<C-e>'], action('scroll-line-down', 2)], [['<C-y>'], action('scroll-line-up')]] as [VimKey[], unknown][])('parses extended action %j', (keys, expected) => expect(run(keys)).toEqual(expected));
  it('parses surround additions and line form', () => {
    expect(run(['y', 's', 'i', 'w', '('])).toMatchObject({ kind: 'command', command: { action: 'surround-add', arg: '(', target: { kind: 'textobject', spec: { kind: 'w', around: false } } } });
    expect(run(['y', 's', 's', '"'])).toMatchObject({ kind: 'command', command: { action: 'surround-add', target: { kind: 'line' }, arg: '"' } });
    expect(run(['y', 's', '2', 'w', '('])).toMatchObject({ kind: 'command', command: { action: 'surround-add', count: 2, arg: '(', target: { kind: 'motion', motion: { kind: 'w' } } } });
  });
  it.each([
    [['c', 's', '(', '['], 'surround-change', '(['],
    [['d', 's', "'"], 'surround-delete', "'"],
  ] as [VimKey[], string, string][])('parses surround operation %j', (keys, expectedAction, arg) => expect(run(keys)).toMatchObject({ kind: 'command', command: { action: expectedAction, arg } }));
  it.each([['f', 'normal'], ['m', 'normal'], ['"', 'normal'], ['g', 'normal'], ['z', 'normal'], ['d', 'g', 'normal'], ['d', 'i', 'normal'], ['i', 'visual'], ['y', 's', 'i', 'w', 'normal'], ['c', 's', 'normal'], ['c', 's', '(', 'normal'], ['d', 's', 'normal'], ['d', '2', 'f', 'normal'], ['d', '2', 'g', 'normal'], ['d', '2', 'i', 'normal'], ['2', 'd', '3', 't', 'normal'], ['g', '~', 'f', 'normal'], ['g', '~', 'g', 'normal'], ['g', '~', 'i', 'normal'], ['g', 'U', 'a', 'normal'], ['y', 's', 'f', 'normal'], ['y', 's', 'i', 'normal'], ['y', 's', 'a', 'normal'], ['y', 's', 'g', 'normal'], ['y', 's', '2', 'i', 'normal'], ['y', 's', 'i', 'w', 'normal']].map((row) => ({ keys: row.slice(0, -1), mode: row.at(-1) as VimMode })))('reports literal argument state after %j', ({ keys, mode }) => {
    const parser = new CommandParser(); parser.setExtended(true); keys.forEach((key) => parser.feed(key, mode));
    expect(parser.awaitingArgument()).toBe(true);
  });
  it.each([[], ['d'], ['d', '2'], ['g', '~'], ['y', 's'], ['y', 's', '2'], ['3']].map((keys) => ({ keys })))('does not report literal argument state after %j', ({ keys }) => {
    const parser = new CommandParser(); parser.setExtended(true); keys.forEach((key) => parser.feed(key, 'normal'));
    expect(parser.awaitingArgument()).toBe(false);
  });
  it('returns pending operator metadata and omits it during literal arguments', () => {
    const parser = new CommandParser(); parser.feed('"', 'normal'); parser.feed('a', 'normal'); parser.feed('2', 'normal'); parser.feed('d', 'normal');
    expect(parser.pendingOperator()).toEqual({ register: 'a', count: 2, operator: 'd' });
    parser.reset(); parser.feed('d', 'normal'); parser.feed('f', 'normal');
    expect(parser.pendingOperator()).toBeNull();
  });
  it.each([[['d', '3'], 3], [['2', 'd', '3'], 6]] as [VimKey[], number][])('combines operator counts for %j', (keys, count) => {
    const parser = new CommandParser(); keys.forEach((key) => parser.feed(key, 'normal'));
    expect(parser.pendingOperator()).toEqual({ register: null, count, operator: 'd' });
  });
  it('reports a pending g-operator', () => {
    const parser = new CommandParser(); parser.feed('g', 'normal'); parser.feed('~', 'normal');
    expect(parser.pendingOperator()).toEqual({ register: null, count: null, operator: 'g~' });
  });
  it('keeps old grammar results byte-for-byte when extended is off', () => {
    for (const keys of [['gj'], ['gJ'], ['zz'], ['ys'], ['ds('], ['<C-e>']]) expect(run(keys, false).kind).not.toBe('command');
  });
});
