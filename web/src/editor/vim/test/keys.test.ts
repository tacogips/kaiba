import { describe, expect, it } from 'vitest';
import { isPassThrough, isVimControlChord, normalizeKey } from '../keys';
import type { VimKeyInput } from '../types';

const input = (key: string, extras: Partial<VimKeyInput> = {}): VimKeyInput => ({ key, ctrlKey: false, metaKey: false, altKey: false, shiftKey: false, ...extras });

describe('normalizeKey', () => {
  it.each([
    ['Escape', '<Esc>'], ['Enter', '<CR>'], ['Backspace', '<BS>'], ['Delete', '<Del>'], ['Tab', '<Tab>'],
    ['ArrowLeft', '<Left>'], ['ArrowRight', '<Right>'], ['ArrowUp', '<Up>'], ['ArrowDown', '<Down>'],
    ['Home', '<Home>'], ['End', '<End>'], ['d', 'd'], ['D', 'D'], [':', ':'], ['é', 'é'], ['👩‍💻', '👩‍💻'],
    ['Shift', null], ['Control', null], ['Alt', null], ['Meta', null], ['CapsLock', null],
    ['Dead', '<Other>'], ['Unidentified', '<Other>'], ['Process', '<Other>'],
  ] as const)('normalizes %s', (key, expected) => expect(normalizeKey(input(key))).toBe(expected));

  it.each([
    [input('[', { ctrlKey: true }), '<Esc>'], [input('r', { ctrlKey: true }), '<C-r>'],
    [input('d', { ctrlKey: true }), '<C-d>'], [input('u', { ctrlKey: true }), '<C-u>'],
    [input('f', { ctrlKey: true }), '<C-f>'], [input('b', { ctrlKey: true }), '<C-b>'],
    [input('Unidentified', { ctrlKey: true, code: 'BracketLeft' }), '<Esc>'],
    [input('Unidentified', { ctrlKey: true, code: 'KeyR' }), '<C-r>'],
    [input('ƒ', { altKey: true }), '<Other>'], [input('x', { metaKey: true }), '<Other>'],
    [input('x', { ctrlKey: true }), '<Other>'], [input('Backspace', { ctrlKey: true }), '<Other>'],
    [input('ArrowLeft', { altKey: true }), '<Other>'],
  ] as const)('normalizes chord %s', (event, expected) => expect(normalizeKey(event)).toBe(expected));
});

describe('isPassThrough', () => {
  const passthrough = [
    input('Enter', { ctrlKey: true }), input('Enter', { metaKey: true }), input('Enter', { ctrlKey: true, shiftKey: true }),
    input('.', { ctrlKey: true }), input('.', { metaKey: true }), input('a', { ctrlKey: true }), input('z', { metaKey: true }),
    input('>', { ctrlKey: true, shiftKey: true, code: 'Period' }), input('>', { metaKey: true, shiftKey: true, code: 'Period' }),
    input('z', { ctrlKey: true, shiftKey: true }), input('y', { ctrlKey: true }), input('c', { ctrlKey: true }),
    input('v', { metaKey: true }), input('\\', { ctrlKey: true }),
  ];
  it.each(['apple', 'other'] as const)('passes shortcuts on %s', (platform) => {
    for (const event of passthrough) expect(isPassThrough(event, platform, () => false)).toBe(true);
  });
  it.each([
    input('r', { ctrlKey: true }), input('d', { ctrlKey: true }), input('Backspace', { altKey: true }),
    input('>', { shiftKey: true, code: 'Period' }),
    input('Backspace', { metaKey: true }), input('Backspace', { ctrlKey: true }), input('Tab', { shiftKey: true }), input('j'),
    input('v', { ctrlKey: true, altKey: true }),
  ])('does not pass Vim or unrelated keys', (event) => {
    expect(isPassThrough(event, 'other', () => false)).toBe(false);
  });
  it('passes an active default keymap', () => expect(isPassThrough(input('Ï', { altKey: true, shiftKey: true }), 'apple', () => true)).toBe(true));
});

describe('isVimControlChord', () => {
  it.each(['r', 'd', 'u', 'f', 'b', '['])('recognizes Ctrl-%s', (key) => expect(isVimControlChord(input(key, { ctrlKey: true }))).toBe(true));
  it.each([input('r'), input('r', { metaKey: true, ctrlKey: true }), input('r', { ctrlKey: true, altKey: true }), input('y', { ctrlKey: true })])('rejects non-Vim chord', (event) => expect(isVimControlChord(event)).toBe(false));
});
