import { afterEach, describe, expect, it, vi } from 'vitest';
import { KeyMapper, type MapperSink } from '../mapper';
import { compileKeymap, type CompiledKeymap } from '../keymap-schema';
import type { VimKey } from '../types';

const compile = (maps: Record<string, unknown[]>, extra: Record<string, unknown> = {}): CompiledKeymap => {
  const result = compileKeymap(JSON.stringify({ version: 1, maps, ...extra }));
  if (!result.keymap) throw new Error(JSON.stringify(result.issues));
  return result.keymap;
};

function harness(keymap: CompiledKeymap, argumentAware = false) {
  const builtin: VimKey[] = [];
  const routed: VimKey[] = [];
  const actions: string[] = [];
  const errors: string[] = [];
  const ex: string[] = [];
  let prompts = 0;
  let awaitingArgument = false;
  let activeMode: 'n' | 'i' | 'x' | 'o' = 'n';
  const sink: MapperSink = {
    builtin(key) {
      builtin.push(key);
      if (argumentAware && ['g', 'z', 'm'].includes(key)) awaitingArgument = true;
    },
    route(key) {
      routed.push(key);
      if (argumentAware && awaitingArgument) { builtin.push(key); awaitingArgument = false; return; }
      const result = mapper.feed(key, activeMode);
      if (result === 'unmapped') sink.builtin(key);
    },
    action(id) { actions.push(id); },
    ex(command) { ex.push(command); },
    prompt() { prompts++; },
    error(message) { errors.push(message); },
    changed() {},
  };
  const mapper = new KeyMapper(keymap, (ms, callback) => {
    const id = setTimeout(callback, ms);
    return () => clearTimeout(id);
  }, sink);
  const type = (key: VimKey, mode: 'n' | 'i' | 'x' | 'o' = 'n') => {
    activeMode = mode;
    const result = mapper.feed(key, mode);
    if (result === 'unmapped') sink.builtin(key);
    return result;
  };
  return { mapper, type, builtin, routed, actions, errors, ex, get prompts() { return prompts; } };
}

afterEach(() => vi.useRealTimers());

describe('KeyMapper resolution', () => {
  it('emits noremap rhs keys directly to built-in handling', () => {
    const h = harness(compile({ n: [{ lhs: 'k', rhs: 'gk' }] }));
    expect(h.type('k')).toBe('consumed');
    expect(h.builtin).toEqual(['g', 'k']);
  });

  it('defers insert multi-key mappings until complete', () => {
    const h = harness(compile({ i: [{ lhs: 'kj', rhs: '<Esc>' }] }));
    expect(h.type('k', 'i')).toBe('consumed');
    expect(h.builtin).toEqual([]);
    h.type('j', 'i');
    expect(h.builtin).toEqual(['<Esc>']);
  });

  it('flushes an incomplete insert mapping on timeout', () => {
    vi.useFakeTimers();
    const h = harness(compile({ i: [{ lhs: 'kj', rhs: '<Esc>' }] }));
    h.type('k', 'i'); vi.advanceTimersByTime(1000);
    expect(h.builtin).toEqual(['k']);
  });

  it('routes a key that breaks an insert mapping after flushing the first key', () => {
    const h = harness(compile({ i: [{ lhs: 'kj', rhs: '<Esc>' }] }));
    h.type('k', 'i'); h.type('a', 'i');
    expect(h.builtin).toEqual(['k', 'a']);
    expect(h.routed).toEqual(['a']);
  });

  it('returns unmapped without touching the sink when no lhs starts with the key', () => {
    const h = harness(compile({ n: [{ lhs: 'ab', rhs: 'x' }] }));
    expect(h.mapper.feed('x', 'n')).toBe('unmapped');
    expect(h.builtin).toEqual([]);
    expect(h.routed).toEqual([]);
  });

  it('maps a two-key escape sequence to an ex command', () => {
    const h = harness(compile({ n: [{ lhs: '<Esc><Esc>', rhs: ':nohlsearch<CR>' }] }));
    h.type('<Esc>'); h.type('<Esc>');
    expect(h.ex).toEqual(['nohlsearch']);
  });

  it('resolves a single escape mapping after timeout', () => {
    vi.useFakeTimers();
    const h = harness(compile({ n: [{ lhs: '<Esc><Esc>', rhs: ':nohlsearch<CR>' }] }));
    h.type('<Esc>'); vi.advanceTimersByTime(1000);
    expect(h.builtin).toEqual(['<Esc>']);
  });

  it('uses the longest mapping prefix then routes every leftover key', () => {
    const h = harness(compile({ n: [{ lhs: 'a', rhs: 'x' }, { lhs: 'abc', rhs: 'y' }] }));
    h.type('a'); h.type('b'); h.type('d');
    expect(h.builtin).toEqual(['x', 'b', 'd']);
    expect(h.routed).toEqual(['b', 'd']);
  });

  it('re-enters remapped rhs keys through route', () => {
    const h = harness(compile({ n: [{ lhs: 'a', rhs: 'b', remap: true }, { lhs: 'b', rhs: 'c' }] }));
    h.type('a');
    expect(h.routed).toEqual(['b']);
    expect(h.builtin).toEqual(['c']);
  });

  it('bounds direct recursive remaps and reports E223 once', () => {
    const h = harness(compile({ n: [{ lhs: 'a', rhs: 'a', remap: true }] }));
    h.type('a');
    expect(h.errors).toEqual(['E223 recursive mapping']);
    expect(h.mapper.buffer()).toEqual([]);
  });

  it('stops a fan-out remap expansion after 1,000 emitted keys', () => {
    const h = harness(compile({ n: [{ lhs: 'a', rhs: 'b'.repeat(256), remap: true }, { lhs: 'b', rhs: 'cccc', remap: true }] }));
    h.type('a');
    expect(h.errors).toEqual(['E223 recursive mapping']);
    expect(h.mapper.buffer()).toEqual([]);
    expect(h.builtin.length).toBeGreaterThan(0);
    expect(h.builtin.length).toBeLessThan(1024);
    expect(h.builtin.every((key) => key === 'c')).toBe(true);
    h.type('a');
    expect(h.errors).toEqual(['E223 recursive mapping', 'E223 recursive mapping']);
    expect(h.mapper.buffer()).toEqual([]);
  });

  it('resets the emitted-key budget at each top-level feed', () => {
    const h = harness(compile({ n: [{ lhs: 'a', rhs: 'b'.repeat(200), remap: true }, { lhs: 'b', rhs: 'cc', remap: true }] }));
    h.type('a');
    expect(h.errors).toEqual([]);
    expect(h.mapper.buffer()).toEqual([]);
    expect(h.builtin).toHaveLength(400);
    expect(h.builtin.every((key) => key === 'c')).toBe(true);

    h.type('a');
    expect(h.errors).toEqual([]);
    expect(h.mapper.buffer()).toEqual([]);
    expect(h.builtin).toHaveLength(800);
    expect(h.builtin.every((key) => key === 'c')).toBe(true);
  });

  it('consumes Nop without emitting a key', () => {
    const h = harness(compile({ n: [{ lhs: 'Q', rhs: '<Nop>' }] }));
    expect(h.type('Q')).toBe('consumed');
    expect(h.builtin).toEqual([]);
  });

  it('runs action mappings', () => {
    const h = harness(compile({ n: [{ lhs: 'gj', action: 'hop.char1' }] }, { hop: { enabled: true } }));
    h.type('g'); h.type('j');
    expect(h.actions).toEqual(['hop.char1']);
  });

  it('opens the prompt for a trailing rhs colon', () => {
    const keymap = compile({ n: [{ lhs: 'a', rhs: ':' }] });
    expect(keymap.maps.n[0]!.target).toEqual({ kind: 'keys', segments: [{ kind: 'prompt' }], remap: false });
    const h = harness(keymap);
    h.type('a');
    expect(h.prompts).toBe(1);
  });

  it('suspends a pending timeout until the hint panel closes', () => {
    vi.useFakeTimers();
    const h = harness(compile({ n: [{ lhs: '<Space>g', rhs: 'x' }] }, { timeoutlen: 1000 }));
    h.type(' '); h.mapper.suspendTimeout(true); vi.advanceTimersByTime(5000);
    expect(h.mapper.pending()).toBe('<Space>');
    h.mapper.suspendTimeout(false); vi.advanceTimersByTime(1000);
    expect(h.builtin).toEqual([' ']);
  });

  it('does not time out during replay and resolves on explicit flush', () => {
    vi.useFakeTimers();
    const h = harness(compile({ n: [{ lhs: 'ab', rhs: 'x' }] }));
    h.mapper.setReplay(true); h.type('a'); vi.advanceTimersByTime(5000);
    expect(h.mapper.pending()).toBe('a');
    h.mapper.flush();
    expect(h.builtin).toEqual(['a']);
  });

  it('flushes a pending sequence before changing map mode', () => {
    const h = harness(compile({ i: [{ lhs: 'kj', rhs: '<Esc>' }], n: [{ lhs: 'x', rhs: 'y' }] }));
    h.type('k', 'i'); h.type('x', 'n');
    expect(h.builtin).toEqual(['k', 'y']);
    expect(h.builtin).toContain('y');
  });
});

describe('KeyMapper DR-K1 route re-entry', () => {
  const presetMaps = {
    n: [
      { lhs: 'gj', action: 'hop.char1' }, { lhs: 'gf', action: 'hop.char1Line' },
      { lhs: 'gn', rhs: 'x' }, { lhs: 'gp', rhs: 'x' }, { lhs: 'gq', rhs: 'x' }, { lhs: 'k', rhs: 'gk' },
      { lhs: 'mm', rhs: '%' }, { lhs: 'ms', rhs: 'x' }, { lhs: 'mr', rhs: 'x' },
      { lhs: 'md', rhs: 'x' }, { lhs: 'ma', rhs: 'x' }, { lhs: 'mi', rhs: 'x' },
      { lhs: 'zc', rhs: 'zz' }, { lhs: 'zj', rhs: '<C-e>' }, { lhs: 'zk', rhs: '<C-y>' },
      { lhs: 'za', rhs: 'x' }, { lhs: 'zA', rhs: 'x' }, { lhs: 'zo', rhs: 'x' },
      { lhs: 'a', rhs: 'mgj', remap: true },
    ],
  };

  it.each([
    ['gg', ['g', 'g']], ['zz', ['z', 'z']], ['mk', ['m', 'k']],
  ] as const)('routes unmatched %s so parser arguments bypass mapping', (input, expected) => {
    const h = harness(compile(presetMaps), true);
    for (const key of input) h.type(key);
    expect(h.builtin).toEqual(expected);
    expect(h.actions).toEqual([]);
    expect(h.mapper.pending()).toBe('');
  });

  it('routes mgj without remapping the mark argument or starting hop', () => {
    const h = harness(compile(presetMaps), true);
    for (const key of 'mgj') h.type(key);
    expect(h.builtin).toEqual(['m', 'g', 'j']);
    expect(h.actions).toEqual([]);
    expect(h.routed).toEqual(['g']);
  });

  it('routes parser arguments in visual mode before mapping lookup', () => {
    const h = harness(compile({
      x: [{ lhs: 'gj', action: 'hop.char1' }, { lhs: 'gf', action: 'hop.char1Line' }, { lhs: 'g~', rhs: 'x' }],
    }, { hop: { enabled: true } }), true);
    h.type('g', 'x'); h.type('g', 'x');
    expect(h.builtin).toEqual(['g', 'g']);
    expect(h.actions).toEqual([]);
  });

  it('routes remap rhs through argument bypass before mapping later keys', () => {
    const h = harness(compile(presetMaps), true);
    h.type('a');
    expect(h.builtin).toEqual(['m', 'g', 'j']);
    expect(h.actions).toEqual([]);
    expect(h.routed).toEqual(['m', 'g', 'g', 'j']);
  });
});
