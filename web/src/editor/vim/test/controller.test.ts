import { describe, expect, it } from 'vitest';
import { Transaction } from '@codemirror/state';
import { VimController } from '../controller';
import { createTestHost, show } from './host';

const input = (key: string) => ({ key, ctrlKey: false, metaKey: false, altKey: false, shiftKey: false });
function run(source: string, keys: readonly string[]) {
  const host = createTestHost(source), vim = new VimController(host);
  for (const key of keys) {
    if (vim.allowsTextInput() && key.length === 1) {
      const state = host.state(), pos = state.selection.main.head;
      const overwrite = vim.overwriteRange(key);
      host.dispatch({ changes: { from: overwrite?.from ?? pos, to: overwrite?.to ?? pos, insert: key }, selection: { anchor: (overwrite?.from ?? pos) + key.length }, annotations: Transaction.userEvent.of('input.type') });
    } else vim.handleKey(input(key));
  }
  return { host, vim, doc: host.state().doc.toString(), cursor: host.state().selection.main.head };
}

const scenarios = [
  ['h', 'ab|cd', ['h'], 'abcd', 1], ['j', 'ab|cd\nef', ['j'], 'abcd\nef', 6],
  ['k', 'ab\nef|gh', ['k'], 'ab\nefgh', 1], ['l', 'a|bc', ['l'], 'abc', 2],
  ['w', '|one two', ['w'], 'one two', 4], ['b', 'one |two', ['b'], 'one two', 0],
  ['e', '|one two', ['e'], 'one two', 2], ['W', '|one-two three', ['W'], 'one-two three', 8],
  ['B', 'one-two |three', ['B'], 'one-two three', 0], ['E', '|one-two three', ['E'], 'one-two three', 6],
  ['ge', 'one |two', ['g', 'e'], 'one two', 2], ['0', '  abc|', ['0'], '  abc', 0],
  ['^', '  |abc', ['^'], '  abc', 2], ['$ clamped', '|abc', ['$'], 'abc', 2],
  ['gg', 'a\nb|c', ['g', 'g'], 'a\nbc', 0], ['G', '|a\nbc', ['G'], 'a\nbc', 2],
  ['3G', '|a\nb\nc', ['3', 'G'], 'a\nb\nc', 4], ['f', '|a-b-a', ['f', 'a'], 'a-b-a', 4],
  ['F', 'a-b-|a', ['F', 'a'], 'a-b-a', 0], ['t', '|a-b', ['t', '-'], 'a-b', 0],
  ['T', 'a-b-|a', ['T', '-'], 'a-b-a', 4], [';', '|a-b-a', ['f', 'a', ';'], 'a-b-a', 4],
  [',', '|a-b-a', ['f', 'a', ','], 'a-b-a', 0], ['%', '|(x)', ['%'], '(x)', 2],
  ['}', '|a\n\nb', ['}'], 'a\n\nb', 2], ['{', 'a\n\n|b', ['{'], 'a\n\nb', 2],
  ['H', '|a\nb\nc', ['H'], 'a\nb\nc', 0], ['M', '|a\nb\nc', ['M'], 'a\nb\nc', 4],
  ['L', '|a\nb\nc', ['L'], 'a\nb\nc', 4], ['*', '|foo bar foo', ['*'], 'foo bar foo', 8],
  ['#', 'foo bar |foo', ['#'], 'foo bar foo', 0], ['counted l', '|abcdef', ['3', 'l'], 'abcdef', 3],
  ['j desired column', 'abcde|\nx\nabcde', ['j', 'j'], 'abcde\nx\nabcde', 12],
  ['k desired column', 'abcde\nx\nabc|de', ['k', 'k'], 'abcde\nx\nabcde', 3],
  ['d motion', '|one two', ['d', 'w'], 'two', 0], ['d text object', '|one two', ['d', 'i', 'w'], ' two', 0],
  ['dd', '|one\ntwo', ['d', 'd'], 'two', 0], ['c motion', '|one two', ['c', 'w'], ' two', 0],
  ['c text object', '|one two', ['c', 'i', 'w'], ' two', 0], ['cc', '|one\ntwo', ['c', 'c'], '\ntwo', 0],
  ['y motion then put', '|one two', ['y', 'w', 'p'], 'oone ne two', 4],
  ['y object then put', '|one two', ['y', 'i', 'w', 'p'], 'oonene two', 3],
  ['yy then put', '|one\ntwo', ['y', 'y', 'p'], 'one\none\ntwo', 4],
  ['> motion', '|one\ntwo', ['>', 'j'], '  one\n  two', 2],
  ['> object', '|one two', ['>', 'i', 'w'], '  one two', 2], ['>>', '|one\ntwo', ['>', '>'], '  one\ntwo', 2],
  ['visual-line indent last line', 'a\n|x', ['V', '>'], 'a\n  x', 4],
  ['visual indent single char doc', '|x', ['v', '>'], '  x', 2],
  ['< motion', '  |one\n  two', ['<', 'j'], 'one\ntwo', 0],
  ['< object', '  |one two', ['<', 'i', 'w'], 'one two', 0], ['<<', '  |one\ntwo', ['<', '<'], 'one\ntwo', 0],
  ['g~ motion', '|one two', ['g', '~', 'w'], 'ONE two', 0], ['g~ object', '|one two', ['g', '~', 'i', 'w'], 'ONE two', 0],
  ['g~~', '|one two', ['g', '~', 'g', '~'], 'ONE TWO', 0], ['gu motion', '|ONE two', ['g', 'u', 'w'], 'one two', 0],
  ['gu object', '|ONE two', ['g', 'u', 'i', 'w'], 'one two', 0], ['gugu', '|ONE two', ['g', 'u', 'g', 'u'], 'one two', 0],
  ['gU motion', '|one two', ['g', 'U', 'w'], 'ONE two', 0], ['gU object', '|one two', ['g', 'U', 'i', 'w'], 'ONE two', 0],
  ['gUgU', '|one two', ['g', 'U', 'g', 'U'], 'ONE TWO', 0], ['cw acts as ce', '|one two', ['c', 'w'], ' two', 0],
  ['cw one-grapheme word changes only that character', '|a bc', ['c', 'w', 'X', 'Escape'], 'X bc', 0],
  ['cw keeps a combining-mark grapheme intact', '|e\u0301 bc', ['c', 'w', 'X', 'Escape'], 'X bc', 0],
  ['cw from final grapheme stops at the current word end', 'a|b cd', ['c', 'w', 'X', 'Escape'], 'aX cd', 1],
  ['cw on punctuation run changes only that run', '|.. foo', ['c', 'w', 'X', 'Escape'], 'X foo', 0],
  ['cw on punctuation between words', 'a |=> b', ['c', 'w', 'X', 'Escape'], 'a X b', 2],
  ['cw on single punctuation grapheme', 'f|(x)', ['c', 'w', 'X', 'Escape'], 'fXx)', 1],
  ['counted operator', '|one two three', ['d', '2', 'w'], 'three', 0],
  ['x', 'a|bc', ['x'], 'ac', 1], ['X', 'ab|c', ['X'], 'ac', 1],
  ['s', 'a|bc', ['s', 'x', 'Escape'], 'axc', 1], ['S', 'a|bc', ['S', 'x', 'Escape'], 'x', 0],
  ['D', 'ab|cd', ['D'], 'ab', 2], ['C', 'ab|cd', ['C', 'x', 'Escape'], 'abx', 2],
  ['Y then put', '|one\ntwo', ['Y', 'p'], 'one\none\ntwo', 4], ['r', 'a|bc', ['r', 'X'], 'aXc', 1],
  ['~', '|one', ['~'], 'One', 1], ['J', '|one\ntwo', ['J'], 'one two', 3],
  ['p', 'one |two', ['y', 'w', 'p'], 'one ttwowo', 7], ['P', 'one |two', ['y', 'w', 'P'], 'one twotwo', 6],
  ['o', '|one', ['o', 'x', 'Escape'], 'one\nx', 4], ['O', '|one', ['O', 'x', 'Escape'], 'x\none', 0],
  ['a', 'a|bc', ['a', 'x', 'Escape'], 'abxc', 2], ['A', 'ab|\ncd', ['A', 'x', 'Escape'], 'abx\ncd', 2],
  ['i', 'a|bc', ['i', 'x', 'Escape'], 'axbc', 1], ['I', '  |abc', ['I', 'x', 'Escape'], '  xabc', 2],
  ['visual x', '|abcd', ['v', 'l', 'x'], 'cd', 0], ['visual X', '|abcd', ['v', 'l', 'X'], '', 0],
  ['visual s', '|abcd', ['v', 'l', 's', 'x', 'Escape'], 'xcd', 0], ['visual S', '|abcd', ['v', 'l', 'S', 'x', 'Escape'], 'x', 0],
  ['visual D', '|abcd', ['v', 'l', 'D'], '', 0], ['visual C', '|abcd', ['v', 'l', 'C', 'x', 'Escape'], 'x', 0],
  ['visual Y then put', '|one\ntwo', ['V', 'j', 'Y', 'p'], 'one\none\ntwo\ntwo', 4],
  ['visual r', '|abcd', ['v', 'l', 'r', 'X'], 'XXcd', 0], ['visual tilde', '|abc', ['v', 'l', '~'], 'ABc', 0],
  ['visual J', '|one\ntwo\nthree', ['V', 'j', 'J'], 'one two\nthree', 3],
  ['visual p', '|abcd', ['y', 'l', 'v', 'l', 'p'], 'abacd', 2], ['visual P', '|abcd', ['y', 'l', 'v', 'l', 'P'], 'aabcd', 1],
  ['visual o swap', '|abcd', ['v', 'l', 'o'], 'abcd', 0], ['visual inner-word delete', '|one two', ['v', 'i', 'w', 'd'], ' two', 0],
  ['visual around-word delete', '|one two', ['v', 'a', 'w', 'd'], 'two', 0], ['visual v exit', '|abc', ['v', 'l', 'v'], 'abc', 1],
  ['visual-line D range', '|a\nb\nc', ['V', 'j', 'D'], 'c', 0],
  ['visual-line V flow', '|abc\ndef', ['V', 'j', 'Escape'], 'abc\ndef', 4],
  ['named yank put', '|one two', ['"', 'a', 'y', 'w', '"', 'a', 'p'], 'oone ne two', 4],
  ['uppercase append', '|one two', ['"', 'a', 'y', 'w', '"', 'A', 'y', 'w', '"', 'a', 'p'], 'oone one ne two', 8],
  ['black hole preserves unnamed', '|one two', ['y', 'w', '"', '_', 'd', 'w', 'P'], 'one two', 3],
  ['zero register survives delete', '|one two', ['y', 'w', 'd', 'w', '"', '0', 'P'], 'one two', 3],
  ['` mark jump', '|abc\ndef', ['m', 'a', 'j', '`', 'a'], 'abc\ndef', 0],
  ['apostrophe mark line jump', '|abc\n  def', ['m', 'a', 'j', "'", 'a'], 'abc\n  def', 0],
  ['context mark', '|abc\ndef', ['j', 'G', "'", "'"], 'abc\ndef', 4],
  ['failed find cancels operator', '|abc', ['d', 'f', 'z'], 'abc', 0],
] as const;

describe('VimController API and motions', () => {
  it('exposes snapshots and subscription lifecycle', () => {
    const host = createTestHost('abc|'), vim = new VimController(host), seen: string[] = [];
    const unsubscribe = vim.subscribe((snapshot) => seen.push(snapshot.mode));
    vim.handleKey(input('i'));
    expect(vim.snapshot.label).toBe('INSERT');
    expect(seen).toContain('insert');
    unsubscribe(); vim.dispose();
  });

  it.each(scenarios)('%s', (_name, doc, keys, expectDoc, expectCursor) => {
    const result = run(doc, keys);
    expect(result.doc).toBe(expectDoc);
    expect(result.cursor).toBe(expectCursor);
  });

  it('covers counted h independently of the motion matrix', () => {
    const result = run('abcdef|', ['$','2', 'h']);
    expect(result.doc).toBe('abcdef');
    expect(result.cursor).toBe(3);
  });

  it('deletes and yanks ranges, enters insert on change, and clamps normal cursor', () => {
    expect(run('|one two', ['d', 'w']).doc).toBe('two');
    expect(run('|one two', ['y', 'w']).doc).toBe('one two');
    const changed = run('|one two', ['c', 'w']);
    expect(changed.vim.snapshot.mode).toBe('insert');
    expect(show(changed.host.state())).toContain('| two');
    expect(run('abc|', ['$']).cursor).toBe(2);
  });

  it('supports visual selection, swap, exit and prompt entry', () => {
    const { vim, host } = run('abcd|', ['v', 'l']);
    expect(vim.snapshot.mode).toBe('visual');
    vim.handleKey(input('o'));
    expect(vim.snapshot.mode).toBe('visual');
    vim.handleKey(input('Escape'));
    expect(vim.snapshot.mode).toBe('normal');
    vim.handleKey(input(':'));
    expect(vim.snapshot.prompt?.kind).toBe(':');
    vim.cancelPrompt();
    expect(host.state().doc.toString()).toBe('abcd');
  });

  it('rejects numbered registers instead of silently dropping edits', () => {
    const { vim, host } = run('one two|', ['"', '1', 'd', 'd']);
    expect(host.state().doc.toString()).toBe('one two');
    expect(vim.snapshot.message).toContain('E354');
  });

  it('executes ex actions, navigation and substitutions', () => {
    const host = createTestHost('a a\nb|'), vim = new VimController(host);
    vim.handleKey(input(':')); vim.submitPrompt('%s/a/x/g');
    expect(host.state().doc.toString()).toBe('x x\nb');
    vim.handleKey(input(':')); vim.submitPrompt('2');
    expect(host.state().selection.main.head).toBe(4);
    vim.handleKey(input(':')); vim.submitPrompt('w');
    expect(host.actions.save).toHaveBeenCalledOnce();
    vim.handleKey(input(':')); vim.submitPrompt('wq');
    expect(host.actions.save).toHaveBeenCalledTimes(2);
    expect(host.actions.close).toHaveBeenCalledOnce();
  });

  it('uses counted text objects, explicit registers and marks', () => {
    const { host, vim } = run('|one two three', ['d', '2', 'a', 'w']);
    expect(host.state().doc.toString()).toBe('three');
    vim.handleKey(input('m')); vim.handleKey(input('a'));
    vim.handleKey(input('0')); vim.handleKey(input('"')); vim.handleKey(input('a')); vim.handleKey(input('y')); vim.handleKey(input('y'));
    expect(vim.snapshot.mode).toBe('normal');
  });
});
