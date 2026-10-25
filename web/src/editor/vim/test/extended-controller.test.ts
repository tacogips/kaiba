import { describe, expect, it } from 'vitest';
import { VimController } from '../controller';
import { compileKeymap } from '../keymap-schema';
import { KEYMAP_PRESETS } from '../presets';
import { createTestHost, show } from './host';

const preset = compileKeymap(KEYMAP_PRESETS[1]!.text).keymap!;
const input = (key: string) => key.startsWith('<C-')
  ? { key: key.slice(3, -1), ctrlKey: true, metaKey: false, altKey: false, shiftKey: false }
  : { key: key === '<Esc>' ? 'Escape' : key, ctrlKey: false, metaKey: false, altKey: false, shiftKey: false };
function run(source: string, keys: readonly string[], enabled = true, viewport?: { topLine: number; rows: number }) {
  const host = createTestHost(source, { viewport }), vim = new VimController(host);
  if (enabled) vim.setKeymap(preset);
  for (const key of keys) {
    const consumed = vim.handleKey(input(key));
    if (!consumed && vim.allowsTextInput() && [...key].length === 1) host.typeText(key);
  }
  return { host, vim };
}

describe('extended built-ins through the Vim controller', () => {
  it('executes gJ as one raw line join only with a keymap', () => {
    const { host, vim } = run('|one\ntwo', ['g', 'J']);
    expect(host.state().doc.toString()).toBe('onetwo');
    const baseline = run('|one\ntwo', ['g', 'J'], false);
    expect(baseline.host.state().doc.toString()).toBe('one\ntwo');
    vim.dispose(); baseline.vim.dispose();
  });

  it('scrolls by a count and keeps the cursor within the viewport', () => {
    const source = '|a\nb\nc\nd\ne\nf';
    const { host, vim } = run(source, ['3', '<C-e>'], true, { topLine: 1, rows: 2 });
    expect(host.scrolls).toEqual([3]);
    expect(host.state().doc.lineAt(host.state().selection.main.head).number).toBe(4);
    vim.dispose();
  });

  it('adds surround around the selected inner word', () => {
    const { host, vim } = run('|foo bar', ['y', 's', 'i', 'w', '(']);
    expect(host.state().doc.toString()).toBe('( foo ) bar');
    vim.dispose();
  });

  it('deletes and changes existing surround pairs', () => {
    const deleted = run('(|foo)', ['d', 's', '(']);
    expect(deleted.host.state().doc.toString()).toBe('foo');
    const changed = run('"|foo"', ['c', 's', '"', "'"]);
    expect(changed.host.state().doc.toString()).toBe("'foo'");
    deleted.vim.dispose(); changed.vim.dispose();
  });

  it('records a surround change for dot repeat', () => {
    const { host, vim } = run('|foo\nbar', ['y', 's', 'i', 'w', '(']);
    expect(host.state().doc.toString()).toBe('( foo )\nbar');
    vim.handleKey(input('j'));
    vim.handleKey(input('.'));
    expect(host.state().doc.toString()).toBe('( foo )\n( bar )');
    vim.dispose();
  });

  it('undoes a surround as one isolated edit', () => {
    const { host, vim } = run('|foo', ['y', 's', 'i', 'w', '(']);
    expect(host.state().doc.toString()).toBe('( foo )');
    vim.handleKey(input('u'));
    expect(host.state().doc.toString()).toBe('foo');
    vim.dispose();
  });

  it('does not enable extended behavior without a stored keymap', () => {
    const { host, vim } = run('|one\ntwo', ['g', 'J'], false);
    expect(show(host.state())).toBe('|one\ntwo');
    vim.dispose();
  });
});
