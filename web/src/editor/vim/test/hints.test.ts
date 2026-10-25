import { describe, expect, it } from 'vitest';
import { compileKeymap } from '../keymap-schema';
import { buildHints, isTrigger } from '../hints';
import { parseNotation } from '../notation';
import type { VimKey } from '../types';

type HintMode = 'n' | 'x' | 'o';

function keymap(value: Record<string, unknown>) {
  const result = compileKeymap(JSON.stringify({ version: 1, ...value }));
  if (!result.keymap) throw new Error(JSON.stringify(result.issues));
  return result.keymap;
}

function keys(value: string): VimKey[] {
  const result = parseNotation(value, ' ');
  if ('error' in result) throw new Error(result.error);
  return result.keys;
}

function entries(value: Record<string, unknown>, mode: HintMode, prefix: string, extended = false) {
  return buildHints(keymap(value), mode, keys(prefix), extended).entries;
}

describe('Vim next-key hints', () => {
  it('lists leader mappings with descriptions and a formatted summary', () => {
    const hints = buildHints(keymap({ leader: '<Space>', maps: { n: [
      { lhs: '<leader>y', rhs: '"+y', desc: 'yank to clipboard' }, { lhs: '<leader>p', rhs: '"+p' },
    ] } }), 'n', keys('<Space>'), false);
    expect(hints.entries).toEqual([
      { key: 'p', desc: '"+p', group: false },
      { key: 'y', desc: 'yank to clipboard', group: false },
    ]);
    expect(hints.summary).toBe('<Space>: 2 next keys');
  });

  it('counts mappings below a multi-level prefix', () => {
    expect(entries({ maps: { n: [{ lhs: '<Space>ga', rhs: 'a' }, { lhs: '<Space>gb', rhs: 'b' }] } }, 'n', '<Space>'))
      .toEqual([{ key: 'g', desc: '+2 keys', group: true }]);
    expect(entries({ maps: { n: [{ lhs: '<Space>ga', rhs: 'a' }, { lhs: '<Space>gb', rhs: 'b' }] } }, 'n', '<Space>g'))
      .toEqual([{ key: 'a', desc: 'a', group: false }, { key: 'b', desc: 'b', group: false }]);
  });

  it('shows the standard g built-ins without extended commands', () => {
    expect(entries({}, 'n', 'g').map(({ key, desc }) => [key, desc])).toEqual([
      ['e', 'end of previous word'], ['g', 'first line'], ['u', 'lowercase'], ['U', 'uppercase'], ['~', 'toggle case'],
    ]);
  });

  it('uses the same g table in visual mode and omits the normal-only mark range', () => {
    expect(entries({}, 'x', 'g').map(({ key }) => key)).toEqual(['e', 'g', 'u', 'U', '~']);
    expect(entries({}, 'x', 'm')).toEqual([]);
  });

  it('adds the extended g built-ins in the specified order', () => {
    expect(entries({}, 'n', 'g', true).map(({ key }) => key)).toEqual(['e', 'g', 'j', 'k', 'u', 'J', 'U', ',', ';', '~']);
  });

  it('limits operator-pending built-ins to g, e, j and k', () => {
    expect(entries({}, 'o', 'g', true).map(({ key }) => key)).toEqual(['e', 'g', 'j', 'k']);
  });

  it('lets an exact mapping override a built-in description', () => {
    expect(entries({ maps: { n: [{ lhs: 'gj', rhs: 'x', desc: 'custom line action' }] } }, 'n', 'g', true))
      .toContainEqual({ key: 'j', desc: 'custom line action', group: false });
  });

  it('removes a built-in when an exact mapping is Nop', () => {
    expect(entries({ maps: { n: [{ lhs: 'g~', rhs: '<Nop>' }] } }, 'n', 'g')).not.toContainEqual(expect.objectContaining({ key: '~' }));
  });

  it('marks an exact mapping as a group when longer mappings share its key', () => {
    expect(entries({ maps: { n: [{ lhs: 'gj', rhs: 'x' }, { lhs: 'gja', rhs: 'y' }, { lhs: 'gjb', rhs: 'z' }] } }, 'n', 'g', true))
      .toContainEqual({ key: 'j', desc: 'x', group: true });
  });

  it('sorts lowercase, uppercase, digits, punctuation and special keys by class', () => {
    expect(entries({ maps: { n: [
      { lhs: 'a<Down>', rhs: 'x' }, { lhs: 'a ', rhs: 'x' }, { lhs: 'a!', rhs: 'x' },
      { lhs: 'a2', rhs: 'x' }, { lhs: 'aB', rhs: 'x' }, { lhs: 'ab', rhs: 'x' },
    ] } }, 'n', 'a').map(({ key }) => key)).toEqual(['b', 'B', '2', '!', ' ', '<Down>']);
  });

  it('includes the mark range beside explicit mark mappings', () => {
    expect(entries({ maps: { n: [{ lhs: 'mm', rhs: 'm' }, { lhs: 'ms', rhs: 's' }] } }, 'n', 'm').map(({ key }) => key))
      .toEqual(['a-z', 'm', 's']);
  });

  it('shows the z built-in only when extended commands are enabled', () => {
    expect(entries({}, 'n', 'z')).toEqual([]);
    expect(entries({}, 'n', 'z', true)).toEqual([{ key: 'z', desc: 'center line', group: false }]);
  });

  it('uses action ids as descriptions when no desc is set', () => {
    expect(entries({ maps: { n: [{ lhs: 'ga', action: 'hop.char1' }] }, hop: { enabled: true } }, 'n', 'g', true))
      .toContainEqual({ key: 'a', desc: 'hop.char1', group: false });
  });

  it('does not include hop mappings dropped by a disabled hop config', () => {
    expect(entries({ maps: { n: [{ lhs: 'gj', action: 'hop.char1' }] } }, 'n', 'g', true).map(({ key }) => key)).toEqual(['e', 'g', 'j', 'k', 'u', 'J', 'U', ',', ';', '~']);
  });

  it('recognizes configured triggers by exact keys and enabled state', () => {
    const config = keymap({ hints: { enabled: true, triggers: { n: ['<Space>', 'g'] } } });
    expect(isTrigger(config, 'n', keys('<Space>'))).toBe(true);
    expect(isTrigger(config, 'n', keys('g'))).toBe(true);
    expect(isTrigger(config, 'n', keys('z'))).toBe(false);
    expect(isTrigger(keymap({ hints: { enabled: false, triggers: { n: ['g'] } } }), 'n', keys('g'))).toBe(false);
  });
});
