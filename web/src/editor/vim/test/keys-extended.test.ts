import { describe, expect, it } from 'vitest';
import { normalizeKey } from '../keys';
import type { VimKeyInput } from '../types';

const input = (key: string, extras: Partial<VimKeyInput> = {}): VimKeyInput => ({ key, ctrlKey: false, metaKey: false, altKey: false, shiftKey: false, ...extras });
describe('extended Ctrl-letter normalization', () => {
  it('keeps unknown Ctrl letters out of the merged grammar by default', () => expect(normalizeKey(input('h', { ctrlKey: true }))).toBe('<Other>'));
  it.each(['a', 'c', 'e', 'g', 'h', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 's', 't', 'v', 'w', 'x', 'y', 'z'])('normalizes Ctrl-%s only when extended', (key) => {
    expect(normalizeKey(input(key, { ctrlKey: true }), true)).toBe(`<C-${key}>`);
  });
  it('preserves existing controls and excludes Meta or Alt', () => {
    expect(normalizeKey(input('r', { ctrlKey: true }), true)).toBe('<C-r>');
    expect(normalizeKey(input('h', { ctrlKey: true, metaKey: true }), true)).toBe('<Other>');
    expect(normalizeKey(input('h', { ctrlKey: true, altKey: true }), true)).toBe('<Other>');
  });
});
