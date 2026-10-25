import { describe, expect, it } from 'vitest';
import { compileKeymap, DEFAULT_HOP_KEYS, KEYMAP_MAX_BYTES, KEYMAP_MAX_ENTRIES } from '../keymap-schema';

const compile = (value: unknown) => compileKeymap(JSON.stringify(value));
const entry = (lhs: string, rhs: string, extra: Record<string, unknown> = {}) => ({ lhs, rhs, ...extra });

describe('compileKeymap document validation', () => {
  it('rejects invalid JSON with one root issue', () => expect(compileKeymap('{')).toEqual({ keymap: null, issues: [{ path: '$', severity: 'error', message: 'invalid JSON' }] }));
  it.each(['null', '[]', '1', '"x"'])('rejects non-object JSON root %s', (text) => expect(compileKeymap(text).keymap).toBeNull());
  it.each([{}, { version: 2 }, { version: '1' }, { version: 1.5 }])('rejects invalid version %j', (value) => expect(compile(value).keymap).toBeNull());
  it('rejects oversized UTF-8 text', () => {
    const result = compileKeymap(`{"version":1,"x":"${'x'.repeat(262_145)}"}`);
    expect(result.keymap).toBeNull();
    expect(result.issues[0]!.path).toBe('$');
  });
  it('rejects a long rhs promptly while keeping a valid sibling mapping', () => {
    const text = JSON.stringify({ version: 1, maps: { n: [entry('x', 'a'.repeat(30_000)), entry('y', 'z')] } });
    expect(new TextEncoder().encode(text).length).toBeLessThanOrEqual(KEYMAP_MAX_BYTES);
    const result = compileKeymap(text);
    expect(result.keymap).not.toBeNull();
    expect(result.issues).toHaveLength(1);
    expect(result.issues[0]).toMatchObject({ path: 'maps.n[0].rhs', severity: 'error' });
    expect(result.keymap?.maps.n.map((mapping) => mapping.lhs)).toEqual([['y']]);
  }, 10_000);
  it('uses the pinned defaults without issues', () => {
    const result = compile({ version: 1 });
    expect(result.issues).toEqual([]);
    expect(result.keymap).toMatchObject({ leader: '\\', timeoutlen: 1000, hints: { enabled: false, delayMs: 200, triggers: { n: [], x: [], o: [] } }, hop: { enabled: false, keys: DEFAULT_HOP_KEYS, uppercaseLabels: false } });
  });
  it('falls back on an invalid leader', () => expect(compile({ version: 1, leader: 'ab' })).toMatchObject({ keymap: { leader: '\\' }, issues: [{ path: 'leader', severity: 'error' }] }));
  it.each([5, 10_001, 1.2, '500'])('defaults invalid timeoutlen %j', (timeoutlen) => expect(compile({ version: 1, timeoutlen })).toMatchObject({ keymap: { timeoutlen: 1000 }, issues: [{ path: 'timeoutlen' }] }));
  it('warns about unknown top-level fields', () => expect(compile({ version: 1, extra: true }).issues).toEqual([{ path: 'extra', severity: 'warning', message: 'unknown field extra is ignored' }]));
});

describe('compileKeymap map entries', () => {
  it('skips an entry with both rhs and action while keeping siblings', () => {
    const result = compile({ version: 1, maps: { n: [entry('a', 'b', { action: 'kaiba.save' }), entry('c', 'd')] } });
    expect(result.keymap?.maps.n.map((map) => map.lhs)).toEqual([['c']]);
    expect(result.issues[0]!.path).toBe('maps.n[0]');
  });
  it('compiles <Nop>', () => expect(compile({ version: 1, maps: { n: [entry('Q', '<Nop>')] } }).keymap?.maps.n[0]!.target).toEqual({ kind: 'nop' }));
  it('rejects remap with actions', () => expect(compile({ version: 1, maps: { n: [{ lhs: 'a', action: 'kaiba.save', remap: true }] } }).issues[0]!.path).toBe('maps.n[0].remap'));
  it('rejects remap with <Nop>', () => expect(compile({ version: 1, maps: { n: [entry('a', '<Nop>', { remap: false })] } }).issues[0]!.path).toBe('maps.n[0].remap'));
  it.each(['<C-a>', '<C-z>', '<C-y>', '<C-c>', '<C-x>', '<C-v>'])('rejects reserved normal lhs %s', (lhs) => expect(compile({ version: 1, maps: { n: [entry(lhs, 'x')] } }).issues[0]!.message).toContain('reserved'));
  it('allows <C-a> in command-line mode', () => expect(compile({ version: 1, maps: { c: [entry('<C-a>', '<Home>')] } }).keymap?.cmdline.get('<C-a>')).toBe('<Home>'));
  it('rejects reserved <C-v> in command-line mode', () => expect(compile({ version: 1, maps: { c: [entry('<C-v>', '<Home>')] } }).issues[0]!.message).toContain('reserved'));
  it('splits ex commands and prompt rhs segments', () => {
    const result = compile({ version: 1, maps: { n: [entry('a', ':nohlsearch<CR>'), entry('b', 'dd:')] } });
    expect(result.keymap?.maps.n.map((item) => item.target)).toEqual([
      { kind: 'keys', segments: [{ kind: 'ex', command: 'nohlsearch' }], remap: false },
      { kind: 'keys', segments: [{ kind: 'keys', keys: ['d', 'd'] }, { kind: 'prompt' }], remap: false },
    ]);
  });
  it('rejects an unterminated ex rhs', () => expect(compile({ version: 1, maps: { n: [entry('a', ':foo')] } }).issues[0]!.path).toBe('maps.n[0].rhs'));
  it('keeps colon literal in insert mode', () => expect(compile({ version: 1, maps: { i: [entry('a', ':x')] } }).keymap?.maps.i[0]!.target).toMatchObject({ kind: 'keys', segments: [{ kind: 'keys', keys: [':', 'x'] }] }));
  it('rejects unsupported insert rhs keys', () => expect(compile({ version: 1, maps: { i: [entry('a', '<C-x>')] } }).issues[0]!.path).toBe('maps.i[0].rhs'));
  it('rejects multi-key command-line lhs', () => expect(compile({ version: 1, maps: { c: [entry('ab', 'x')] } }).issues[0]!.path).toBe('maps.c[0].lhs'));
  it.each(['<Esc>', '<CR>', '<Home>', '<End>', '<Left>', '<Right>', '<BS>', '<Del>', 'x'])('accepts command-line rhs %s', (rhs) => expect(compile({ version: 1, maps: { c: [entry('a', rhs)] } }).issues).toEqual([]));
  it('rejects multi-key command-line rhs', () => expect(compile({ version: 1, maps: { c: [entry('a', 'xy')] } }).issues[0]!.path).toBe('maps.c[0].rhs'));
  it('uses the last duplicate mapping at its last position', () => {
    const result = compile({ version: 1, maps: { n: [entry('a', 'x'), entry('b', 'y'), entry('a', 'z')] } });
    expect(result.keymap?.maps.n.map((m) => [m.lhs[0], m.target.kind === 'keys' ? m.target.segments[0] : m.target.kind])).toEqual([
      ['b', { kind: 'keys', keys: ['y'] }], ['a', { kind: 'keys', keys: ['z'] }],
    ]);
  });
  it('appends v mappings to x', () => expect(compile({ version: 1, maps: { v: [entry('a', 'b')] } }).keymap?.maps.x).toHaveLength(1));
  it('drops hop action mappings when hop is disabled', () => expect(compile({ version: 1, maps: { n: [{ lhs: 'gj', action: 'hop.char1' }] } }).keymap?.maps.n).toEqual([]));
  it('keeps hop action mappings when enabled', () => expect(compile({ version: 1, hop: { enabled: true }, maps: { n: [{ lhs: 'gj', action: 'hop.char1' }] } }).keymap?.maps.n).toHaveLength(1));
  it('rejects unknown and mode-incompatible actions', () => {
    const result = compile({ version: 1, maps: { n: [{ lhs: 'a', action: 'missing' }, { lhs: 'b', action: 'kaiba.close', remap: false }] } });
    expect(result.issues).toHaveLength(2);
  });
  it('rejects an action that is not allowed in its mode', () => expect(compile({ version: 1, maps: { o: [{ lhs: 'a', action: 'kaiba.save' }] } }).issues[0]).toMatchObject({ path: 'maps.o[0].action', message: expect.stringContaining('not allowed') }));
  it('reports malformed entries with their JSON path', () => expect(compile({ version: 1, maps: { n: [null] } }).issues[0]!.path).toBe('maps.n[0]'));
  it('rejects reserved keys even when they appear after the first lhs key only when first', () => {
    const result = compile({ version: 1, maps: { n: [entry('a<C-a>', 'x')] } });
    expect(result.issues).toEqual([]);
  });
  it('rejects descriptions with controls or excessive length', () => {
    expect(compile({ version: 1, maps: { n: [entry('a', 'b', { desc: 'x\n' })] } }).issues[0]!.path).toBe('maps.n[0].desc');
    expect(compile({ version: 1, maps: { n: [entry('a', 'b', { desc: 'x'.repeat(81) })] } }).issues[0]!.path).toBe('maps.n[0].desc');
  });
  it('warns on unknown modes and entry fields', () => {
    const result = compile({ version: 1, maps: { z: [], n: [{ ...entry('a', 'b'), extra: 1 }] } });
    expect(result.issues.map((issue) => issue.severity)).toEqual(['warning', 'warning']);
  });
  it('caps total entries and reports one cap issue', () => {
    const entries = Array.from({ length: KEYMAP_MAX_ENTRIES + 1 }, (_, i) => entry(`a${i}`, 'x'));
    const result = compile({ version: 1, maps: { n: entries } });
    expect(result.keymap?.maps.n).toHaveLength(KEYMAP_MAX_ENTRIES);
    expect(result.issues.filter((issue) => issue.path === 'maps')).toHaveLength(1);
  });
});

describe('compileKeymap settings', () => {
  it('validates hint defaults, trigger parsing and the v alias', () => {
    const result = compile({ version: 1, hints: { enabled: true, delayMs: 0, triggers: { v: ['<Space>', 'g'] } } });
    expect(result.keymap?.hints).toEqual({ enabled: true, delayMs: 0, triggers: { n: [], x: [[' '], ['g']], o: [] } });
  });
  it('rejects more than 32 hint triggers', () => expect(compile({ version: 1, hints: { triggers: { n: Array(33).fill('g') } } }).issues[0]!.path).toBe('hints.triggers.n'));
  it('rejects an empty hint trigger', () => expect(compile({ version: 1, hints: { triggers: { n: [''] } } }).issues[0]!.path).toBe('hints.triggers.n[0]'));
  it('defaults invalid hop keys', () => expect(compile({ version: 1, hop: { keys: 'aa' } })).toMatchObject({ keymap: { hop: { keys: DEFAULT_HOP_KEYS } }, issues: [{ path: 'hop.keys' }] }));
  it('rejects case-folded duplicate hop keys in uppercase mode', () => expect(compile({ version: 1, hop: { uppercaseLabels: true, keys: 'aA' } }).issues[0]!.path).toBe('hop.keys'));
  it('accepts valid hop keys', () => expect(compile({ version: 1, hop: { keys: 'asdf' } }).keymap?.hop.keys).toBe('asdf'));
  it('warns for malformed unsupported documentation', () => expect(compile({ version: 1, unsupported: [null] }).issues[0]!.severity).toBe('warning'));
  it('never throws for arbitrary JSON values', () => {
    for (const value of [true, 0, 'text', [], { version: 1, maps: { n: [false, {}, { lhs: [], rhs: null }] } }]) expect(() => compile(value)).not.toThrow();
  });
});
