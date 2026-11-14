import { describe, expect, it } from 'vitest';
import { formatKey, formatNotation, parseNotation } from '../notation';

describe('parseNotation', () => {
  it.each([
    ['kj', ['k', 'j']], ['<Space>y', [' ', 'y']], ['<esc><ESC>', ['<Esc>', '<Esc>']],
    ['<C-H>', ['<C-h>']], ['<C-[>', ['<Esc>']], ['<lt>', ['<']], ['<Bar>', ['|']], ['<Bslash>', ['\\']],
    ['<Enter><Return>', ['<CR>', '<CR>']], ['<BS><Del><Tab>', ['<BS>', '<Del>', '<Tab>']],
    ['<Left><Right><Up><Down><Home><End>', ['<Left>', '<Right>', '<Up>', '<Down>', '<Home>', '<End>']],
    ['a<b', ['a', '<', 'b']], ['<', ['<']], ['a< b', ['a', '<', ' ', 'b']],
    ['e\u0301', ['e\u0301']], ['👩‍💻x', ['👩‍💻', 'x']], ['<leader>y', [' ', 'y']],
  ] as [string, string[]][])('parses %s', (notation, expected) => {
    const result = parseNotation(notation, ' ');
    expect(result).toEqual({ keys: expected });
  });
  it('requires a leader when the notation uses one', () => expect(parseNotation('<leader>y', null)).toEqual({ error: '<leader> needs a leader' }));
  it.each(['<M-x>', '<A-x>', '<D-x>', '<S-Tab>', '<F1>', '<C-1>', '<Nop>', '<NoSuch>'])('rejects unsupported token %s', (notation) => {
    const result = parseNotation(notation, null);
    expect('error' in result && result.error).toContain(notation);
  });
  it('returns an error for a non-string at runtime', () => expect(parseNotation(2 as unknown as string, null)).toEqual({ error: 'notation must be a string' }));
  it('parses a 200,000-character plain run in linear time', () => {
    const result = parseNotation('a'.repeat(200_000), null);
    expect('error' in result).toBe(false);
    if (!('error' in result)) expect([result.keys.length, result.keys[0], result.keys.at(-1)]).toEqual([200_000, 'a', 'a']);
  }, 10_000);
  it('parses a 200,000-character unmatched angle run as literal keys', () => {
    const result = parseNotation('<'.repeat(200_000), null);
    expect('error' in result).toBe(false);
    if (!('error' in result)) expect([result.keys.length, result.keys[0], result.keys.at(-1), result.keys.every((key) => key === '<')]).toEqual([200_000, '<', '<', true]);
  }, 10_000);
  it('segments a long run once before parsing a notation token', () => {
    const result = parseNotation(`${'x'.repeat(100_000)}<Esc>`, null);
    expect('error' in result).toBe(false);
    if (!('error' in result)) expect([result.keys.length, result.keys.at(-1)]).toEqual([100_001, '<Esc>']);
  }, 10_000);
});

describe('notation formatting', () => {
  it('formats literal spaces and less-than keys', () => expect(formatNotation([' ', 'y', '<'])).toBe('<Space>y<lt>'));
  it.each([
    [' ', '<Space>'], ['<', '<lt>'], ['x', 'x'], ['<Esc>', '<Esc>'], ['<C-a>', '<C-a>'], ['👩‍💻', '👩‍💻'],
  ])('formats key %s', (key, expected) => expect(formatKey(key)).toBe(expected));
  it('round-trips canonical notation rows', () => {
    for (const notation of ['kj', '<Space>y', '<Esc><C-h><CR>', '<lt><Bar><Bslash>', 'é👩‍💻']) {
      const parsed = parseNotation(notation, ' ');
      expect('error' in parsed ? parsed : parseNotation(formatNotation(parsed.keys), ' ')).toEqual(parsed);
    }
  });
});
