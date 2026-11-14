import { describe, expect, it } from 'vitest';
import { KEYMAP_PRESETS } from '../presets';
import { compileKeymap } from '../keymap-schema';

const presets = new Map(KEYMAP_PRESETS.map((preset) => [preset.id, preset]));
const compile = (id: 'default' | 'mise-darwin') => {
  const result = compileKeymap(presets.get(id)!.text);
  expect(result.issues).toEqual([]);
  expect(result.keymap).not.toBeNull();
  return result.keymap!;
};
const mapping = (keymap: NonNullable<ReturnType<typeof compileKeymap>['keymap']>, mode: 'n' | 'i' | 'x', lhs: string) =>
  keymap.maps[mode].find((item) => item.lhs.join('') === lhs);

describe('keymap presets', () => {
  it('exports Default and mise-darwin in stable order', () => {
    expect(KEYMAP_PRESETS.map(({ id, label }) => [id, label])).toEqual([
      ['default', 'Default'], ['mise-darwin', 'mise-darwin'],
    ]);
  });

  it('compiles Default without issues, with which-key hints for g, z and m', () => {
    const keymap = compile('default');
    expect(keymap.maps.n).toEqual([]);
    expect(keymap.hints.enabled).toBe(true);
    expect(keymap.hints.delayMs).toBe(0);
    expect(keymap.hints.triggers.n).toEqual([['g'], ['z'], ['m']]);
    expect(keymap.hop.enabled).toBe(false);
    expect(keymap.leader).toBe('\\');
  });

  it('compiles mise-darwin without issues and enables its settings', () => {
    const keymap = compile('mise-darwin');
    expect(keymap.leader).toBe(' ');
    expect(keymap.timeoutlen).toBe(1000);
    expect(keymap.hints.enabled).toBe(true);
    expect(keymap.hop.enabled).toBe(true);
    expect(keymap.hop.keys).toBe('fdjhklsagqwertyuiopzxcvbnm');
    expect(keymap.hints.triggers.n).toEqual([[' '], ['g'], ['m'], ['z']]);
  });

  it('contains representative insert, visual, motion, surround and hop mappings', () => {
    const keymap = compile('mise-darwin');
    expect(mapping(keymap, 'i', 'kj')?.target).toMatchObject({ kind: 'keys', segments: [{ kind: 'keys', keys: ['<Esc>'] }] });
    expect(mapping(keymap, 'x', 'kj')?.target).toMatchObject({ kind: 'keys', segments: [{ kind: 'keys', keys: ['<Esc>'] }] });
    for (const lhs of ['k', 'J', '+', 'mm', 'zc', 'zj', 'zk', '<Esc><Esc>', 'ms', 'mr', 'md']) {
      expect(mapping(keymap, 'n', lhs), lhs).toBeDefined();
    }
    expect(mapping(keymap, 'n', 'gj')?.target).toEqual({ kind: 'action', id: 'hop.char1' });
    expect(mapping(keymap, 'x', 'gf')?.target).toEqual({ kind: 'action', id: 'hop.char1Line' });
  });

  it('maps leader write and quit to the kaiba editor actions', () => {
    const keymap = compile('mise-darwin');
    expect(mapping(keymap, 'n', ' w')?.target).toEqual({ kind: 'action', id: 'kaiba.save' });
    expect(mapping(keymap, 'n', ' q')?.target).toEqual({ kind: 'action', id: 'kaiba.close' });
    for (const lhs of ['gn', '<C-g>', 'gp', '<C-s>', ' R']) expect(mapping(keymap, 'n', lhs), lhs).toBeUndefined();
  });

  it('maps command-line controls and includes descriptions on every mapping', () => {
    const keymap = compile('mise-darwin');
    expect(keymap.cmdline.get('<C-g>')).toBe('<Esc>');
    expect(keymap.cmdline.get('<C-a>')).toBe('<Home>');
    const document = JSON.parse(presets.get('mise-darwin')!.text) as { maps: Record<string, { desc?: string }[]> };
    expect(Object.values(document.maps).flat().every((item) => typeof item.desc === 'string' && item.desc.length > 0)).toBe(true);
  });

  it('documents unsupported reference mappings including reserved Ctrl-v paste', () => {
    const document = JSON.parse(presets.get('mise-darwin')!.text) as { unsupported?: { lhs: string; reference: string }[] };
    expect(document.unsupported!.length).toBeGreaterThanOrEqual(4);
    expect(document.unsupported).toContainEqual(expect.objectContaining({ lhs: '<C-v>' }));
    expect(document.unsupported!.some(({ reference }) => reference.includes('LSP hover'))).toBe(true);
  });
});
