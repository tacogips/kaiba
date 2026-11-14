import { describe, expect, it } from 'vitest';
import { VimController } from '../controller';
import { compileKeymap } from '../keymap-schema';
import { KEYMAP_PRESETS } from '../presets';
import { createTestHost } from './host';

const preset = compileKeymap(KEYMAP_PRESETS[1]!.text).keymap!;
const input = (key: string) => key.startsWith('<C-')
  ? { key: key.slice(3, -1), ctrlKey: true, metaKey: false, altKey: false, shiftKey: false }
  : { key: key === '<Esc>' ? 'Escape' : key, ctrlKey: false, metaKey: false, altKey: false, shiftKey: false };
type Case = { name: string; source: string; keys: string[]; doc: string; cursor: number; mode: string };
const cases: Case[] = [
  { name: 'h', source: 'a|bc', keys: ['h'], doc: 'abc', cursor: 0, mode: 'normal' },
  { name: 'l', source: 'a|bc', keys: ['l'], doc: 'abc', cursor: 2, mode: 'normal' },
  { name: 'w', source: '|one two', keys: ['w'], doc: 'one two', cursor: 4, mode: 'normal' },
  { name: 'b', source: 'one |two', keys: ['b'], doc: 'one two', cursor: 0, mode: 'normal' },
  { name: 'e', source: '|one two', keys: ['e'], doc: 'one two', cursor: 2, mode: 'normal' },
  { name: 'gg', source: 'a\nb|c', keys: ['g', 'g'], doc: 'a\nbc', cursor: 0, mode: 'normal' },
  { name: 'G', source: '|a\nbc', keys: ['G'], doc: 'a\nbc', cursor: 2, mode: 'normal' },
  { name: '0', source: '  abc|', keys: ['0'], doc: '  abc', cursor: 0, mode: 'normal' },
  { name: '^', source: '  |abc', keys: ['^'], doc: '  abc', cursor: 2, mode: 'normal' },
  { name: '$', source: '|abc', keys: ['$'], doc: 'abc', cursor: 2, mode: 'normal' },
  { name: 'j', source: '|a\nb', keys: ['j'], doc: 'a\nb', cursor: 2, mode: 'normal' },
  { name: 'k', source: 'a\n|b', keys: ['k'], doc: 'a\nb', cursor: 0, mode: 'normal' },
  { name: 'f', source: '|a-b-a', keys: ['f', 'a'], doc: 'a-b-a', cursor: 4, mode: 'normal' },
  { name: 't', source: '|a-b', keys: ['t', '-'], doc: 'a-b', cursor: 0, mode: 'normal' },
  { name: '%', source: '|(x)', keys: ['%'], doc: '(x)', cursor: 2, mode: 'normal' },
  { name: 'dd', source: '|one\ntwo', keys: ['d', 'd'], doc: 'two', cursor: 0, mode: 'normal' },
  { name: 'dw', source: '|one two', keys: ['d', 'w'], doc: 'two', cursor: 0, mode: 'normal' },
  { name: 'x', source: 'a|bc', keys: ['x'], doc: 'ac', cursor: 1, mode: 'normal' },
  { name: 'X', source: 'ab|c', keys: ['X'], doc: 'ac', cursor: 1, mode: 'normal' },
  { name: 'D', source: 'ab|cd', keys: ['D'], doc: 'ab', cursor: 2, mode: 'normal' },
  { name: 'C', source: 'ab|cd', keys: ['C', 'x', '<Esc>'], doc: 'abx', cursor: 2, mode: 'normal' },
  { name: 'J', source: '|one\ntwo', keys: ['J'], doc: 'one two', cursor: 3, mode: 'normal' },
  { name: 'Yp', source: '|one\ntwo', keys: ['Y', 'p'], doc: 'one\none\ntwo', cursor: 4, mode: 'normal' },
  { name: 'visual move', source: '|abc', keys: ['v', 'l', '<Esc>'], doc: 'abc', cursor: 1, mode: 'normal' },
  { name: 'visual x', source: '|abcd', keys: ['v', 'l', 'x'], doc: 'cd', cursor: 0, mode: 'normal' },
  { name: 'insert', source: 'a|bc', keys: ['i', 'x', '<Esc>'], doc: 'axbc', cursor: 1, mode: 'normal' },
  { name: 'append', source: 'a|bc', keys: ['a', 'x', '<Esc>'], doc: 'abxc', cursor: 2, mode: 'normal' },
  { name: 'gJ remains baseline', source: '|one\ntwo', keys: ['g', 'J'], doc: 'one\ntwo', cursor: 0, mode: 'normal' },
  { name: 'gj remains baseline', source: '|a\nb', keys: ['g', 'j'], doc: 'a\nb', cursor: 0, mode: 'normal' },
  { name: 'zz remains baseline', source: '|one\ntwo', keys: ['z', 'z'], doc: 'one\ntwo', cursor: 0, mode: 'normal' },
  { name: 'surround remains baseline', source: '|one', keys: ['y', 's'], doc: 'one', cursor: 0, mode: 'normal' },
  { name: 'Ctrl-h remains baseline', source: '|abc', keys: ['<C-h>'], doc: 'abc', cursor: 0, mode: 'normal' },
  { name: 'Ctrl-e remains baseline', source: '|abc', keys: ['<C-e>'], doc: 'abc', cursor: 0, mode: 'normal' },
];

function run(source: string, keys: readonly string[], resetFirst: boolean) {
  const host = createTestHost(source), vim = new VimController(host);
  if (resetFirst) { vim.setKeymap(preset); vim.setKeymap(null); }
  for (const key of keys) {
    const consumed = vim.handleKey(input(key));
    if (!consumed && vim.allowsTextInput() && [...key].length === 1) host.typeText(key);
  }
  const result = { doc: host.state().doc.toString(), cursor: host.state().selection.main.head, mode: vim.snapshot.mode, pending: vim.snapshot.pending, message: vim.snapshot.message };
  vim.dispose();
  return result;
}

describe('K0 return-to-baseline parity', () => {
  it.each(cases)('$name matches merged Vim before and after keymap reset', (scenario) => {
    const expected = { doc: scenario.doc, cursor: scenario.cursor, mode: scenario.mode, pending: '', message: null };
    expect(run(scenario.source, scenario.keys, false)).toEqual(expected);
    expect(run(scenario.source, scenario.keys, true)).toEqual(expected);
  });
});
