import type { Platform, VimKey, VimKeyInput } from './types';

const namedKeys: Record<string, VimKey> = {
  Escape: '<Esc>', Enter: '<CR>', Backspace: '<BS>', Delete: '<Del>', Tab: '<Tab>',
  ArrowLeft: '<Left>', ArrowRight: '<Right>', ArrowUp: '<Up>', ArrowDown: '<Down>', Home: '<Home>', End: '<End>',
};
const modifiers = new Set(['Shift', 'Control', 'Alt', 'Meta', 'CapsLock']);
const controlKeys: Record<string, VimKey> = { v: '<C-v>', r: '<C-r>', d: '<C-d>', u: '<C-u>', f: '<C-f>', b: '<C-b>' };

export function normalizeKey(input: VimKeyInput, extended = false): VimKey | null {
  const { key } = input;
  if (modifiers.has(key)) return null;
  if (input.ctrlKey && !input.metaKey && !input.altKey) {
    if (key === '[' || input.code === 'BracketLeft') return '<Esc>';
    for (const [letter, normalized] of Object.entries(controlKeys)) {
      if (key === letter || input.code === `Key${letter.toUpperCase()}`) return normalized;
    }
    if (extended && /^[a-z]$/i.test(key)) return `<C-${key.toLowerCase()}>`;
    if (extended && /^Key[A-Z]$/.test(input.code ?? '')) return `<C-${input.code!.slice(3).toLowerCase()}>`;
  }
  if (input.ctrlKey || input.metaKey || input.altKey) return '<Other>';
  if (namedKeys[key]) return namedKeys[key];
  if (key === 'Dead' || key === 'Unidentified' || key === 'Process') return '<Other>';
  if (key && new Intl.Segmenter(undefined, { granularity: 'grapheme' }).segment(key)[Symbol.iterator]().next().value?.segment === key) return key;
  return '<Other>';
}

export function isPassThrough(input: VimKeyInput, _platform: Platform, matchesDefaultKeymap: (input: VimKeyInput) => boolean): boolean {
  if (matchesDefaultKeymap(input)) return true;
  const key = input.key.toLowerCase();
  const mod = input.metaKey || input.ctrlKey;
  if (mod && (['enter', '.', 'a', 'z'].includes(key) || (input.ctrlKey && key === 'y') || input.code === 'Period')) return true;
  return mod && !input.altKey && ['c', 'x', 'v', '\\'].includes(key);
}

export function isVimControlChord(input: VimKeyInput): boolean {
  if (!input.ctrlKey || input.metaKey || input.altKey) return false;
  if (input.key === '[' || input.code === 'BracketLeft') return true;
  return Object.keys(controlKeys).some((letter) => input.key === letter || input.code === `Key${letter.toUpperCase()}`);
}
