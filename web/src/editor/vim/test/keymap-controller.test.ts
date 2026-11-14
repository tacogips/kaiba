import { afterEach, describe, expect, it, vi } from 'vitest';
import { VimController } from '../controller';
import { compileKeymap } from '../keymap-schema';
import { KEYMAP_PRESETS } from '../presets';
import { createTestHost, show } from './host';

const preset = compileKeymap(KEYMAP_PRESETS[1]!.text).keymap!;
const input = (key: string) => key.startsWith('<C-')
  ? { key: key.slice(3, -1), ctrlKey: true, metaKey: false, altKey: false, shiftKey: false }
  : { key: key === '<Esc>' ? 'Escape' : key === '<CR>' ? 'Enter' : key === '<BS>' ? 'Backspace' : key, ctrlKey: false, metaKey: false, altKey: false, shiftKey: false };
function press(vim: VimController, host: ReturnType<typeof createTestHost>, key: string): void {
  const consumed = vim.handleKey(input(key));
  if (!consumed && vim.allowsTextInput() && [...key].length === 1) host.typeText(key);
}
function setup(text: string) {
  const host = createTestHost(text), vim = new VimController(host);
  vim.setKeymap(preset);
  return { host, vim };
}

afterEach(() => vi.useRealTimers());

describe('Vim keymap controller integration', () => {
  it('routes mise-darwin normal prefix arguments before mappings: gg and zz are immediate', () => {
    const { host, vim } = setup('a\nb|c\nd');
    press(vim, host, 'g'); press(vim, host, 'g');
    expect(host.state().selection.main.head).toBe(0);
    expect(vim.snapshot.pending).toBe('');
    press(vim, host, 'z'); press(vim, host, 'z');
    expect(host.scrolls.length).toBe(1);
    expect(vim.snapshot.pending).toBe('');
    vim.dispose();
  });

  it('keeps mark and find arguments literal after mapper prefixes', () => {
    const { host, vim } = setup('|a\nb\nc');
    press(vim, host, 'm'); press(vim, host, 'k');
    press(vim, host, 'j'); press(vim, host, '`'); press(vim, host, 'k');
    expect(host.state().selection.main.head).toBe(0);
    const literal = setup('|a-k');
    press(literal.vim, literal.host, 'f'); press(literal.vim, literal.host, 'k');
    expect(literal.host.state().selection.main.head).toBe(2);
    literal.vim.dispose();
    const till = setup('|a-k');
    press(till.vim, till.host, 't'); press(till.vim, till.host, 'k');
    expect(till.host.state().selection.main.head).toBe(1);
    till.vim.dispose();
    vim.dispose();
  });

  it('routes mark argument plus following motion without starting hop', () => {
    const { host, vim } = setup('|a\nb\nc');
    press(vim, host, 'm'); press(vim, host, 'g'); press(vim, host, 'j');
    expect(host.state().selection.main.head).toBe(2);
    expect(vim.snapshot.hop).toBeNull();
    vim.dispose();
  });

  it('yanks the inner word to the clipboard through the leader mapping', async () => {
    const { host, vim } = setup('|word rest');
    press(vim, host, ' '); press(vim, host, 'y'); press(vim, host, 'i'); press(vim, host, 'w');
    await Promise.resolve();
    expect(host.memoryClipboard.value).toBe('word');
    vim.dispose();
  });

  it('uses the preset mm mapping for matching brackets', () => {
    const { host, vim } = setup('|(a)');
    press(vim, host, 'm'); press(vim, host, 'm');
    expect(host.state().selection.main.head).toBe(2);
    vim.dispose();
  });

  it('uses plus to walk the change list from newest to older', () => {
    const { host, vim } = setup('|a\nb\nc');
    press(vim, host, 'i'); press(vim, host, 'X'); press(vim, host, '<Esc>');
    press(vim, host, 'j'); press(vim, host, 'i'); press(vim, host, 'Y'); press(vim, host, '<Esc>');
    press(vim, host, '+');
    expect(host.state().selection.main.head).toBe(3);
    press(vim, host, '+');
    expect(host.state().selection.main.head).toBe(0);
    vim.dispose();
  });

  it('clears search with double Escape and times out a single Escape', () => {
    vi.useFakeTimers();
    const { host, vim } = setup('|foo foo');
    press(vim, host, '/'); vim.submitPrompt('foo');
    expect(vim.snapshot.search).not.toBeNull();
    press(vim, host, '<Esc>'); press(vim, host, '<Esc>');
    expect(vim.snapshot.search).toBeNull();
    press(vim, host, '<Esc>'); vi.advanceTimersByTime(1000);
    expect(vim.snapshot.pending).toBe('');
    vim.dispose();
  });

  it('defers insert k for kj and exits without inserting either key', () => {
    const { host, vim } = setup('|');
    press(vim, host, 'i'); press(vim, host, 'a'); press(vim, host, 'b');
    press(vim, host, 'k');
    expect(show(host.state())).toBe('ab|');
    press(vim, host, 'j');
    expect(show(host.state())).toBe('a|b');
    expect(vim.snapshot.mode).toBe('normal');
    vim.dispose();
  });

  it('types a held insert k on timeout and allows a following key after mismatch', () => {
    vi.useFakeTimers();
    const { host, vim } = setup('|');
    press(vim, host, 'i'); press(vim, host, 'k'); vi.advanceTimersByTime(1000);
    expect(show(host.state())).toBe('k|');
    press(vim, host, 'x');
    expect(show(host.state())).toBe('kx|');
    vim.dispose();
  });

  it('types a non-matching key immediately after an insert mapping prefix', () => {
    const { host, vim } = setup('|');
    press(vim, host, 'i'); press(vim, host, 'k'); press(vim, host, 'x');
    expect(show(host.state())).toBe('kx|');
    expect(vim.snapshot.mode).toBe('insert');
    vim.dispose();
  });

  it('preserves words when insert k is followed by a non-matching key', () => {
    const { host, vim } = setup('|');
    press(vim, host, 'i'); press(vim, host, 'l'); press(vim, host, 'i'); press(vim, host, 'k'); press(vim, host, 'e');
    expect(show(host.state())).toBe('like|');
    vim.dispose();
  });

  it('delivers Enter immediately after an insert mapping prefix', () => {
    const { host, vim } = setup('|');
    press(vim, host, 'i'); press(vim, host, 'k'); press(vim, host, '<CR>');
    expect(show(host.state())).toBe('k\n|');
    expect(host.defaultKeys).toContain('<CR>');
    vim.dispose();
  });

  it('delivers Backspace immediately after an insert mapping prefix', () => {
    const { host, vim } = setup('|');
    press(vim, host, 'i'); press(vim, host, 'a'); press(vim, host, 'k'); press(vim, host, '<BS>');
    expect(show(host.state())).toBe('a|');
    expect(host.defaultKeys).toContain('<BS>');
    vim.dispose();
  });

  it('shows delayed leader hints and suspends timeout while visible', () => {
    vi.useFakeTimers();
    const { host, vim } = setup('|abc');
    press(vim, host, ' '); vi.advanceTimersByTime(200);
    expect(vim.snapshot.hints?.entries.some((entry) => entry.key === 'y' && entry.desc === 'Yank to clipboard')).toBe(true);
    vi.advanceTimersByTime(5000);
    expect(vim.snapshot.pending).toContain('<Space>');
    press(vim, host, 'y');
    expect(vim.snapshot.hints).toBeNull();
    vim.dispose();
  });

  it('closes hints on Escape and blur clears mapper and hop state', () => {
    vi.useFakeTimers();
    const { host, vim } = setup('|abc');
    press(vim, host, ' '); vi.advanceTimersByTime(200);
    press(vim, host, '<Esc>');
    expect(vim.snapshot.hints).toBeNull();
    press(vim, host, 'g');
    vim.blur();
    expect(vim.snapshot.hop).toBeNull();
    expect(vim.snapshot.pending).toBe('');
    vim.dispose();
  });

  it('starts char hop and moves to the selected label', () => {
    const { host, vim } = setup('|foo foo');
    press(vim, host, 'g'); press(vim, host, 'j');
    press(vim, host, 'o');
    expect(vim.snapshot.hop?.labels.length).toBeGreaterThan(0);
    const label = vim.snapshot.hop?.labels[0];
    press(vim, host, label?.text ?? '');
    expect(host.state().selection.main.head).toBe(label?.pos);
    expect(vim.snapshot.hop).toBeNull();
    vim.dispose();
  });

  it('cancels hop on Escape and clears its overlay', () => {
    const { host, vim } = setup('|foo foo');
    press(vim, host, 'g'); press(vim, host, 'j'); press(vim, host, '<Esc>');
    expect(vim.snapshot.hop).toBeNull();
    expect(vim.snapshot.pending).toBe('');
    vim.dispose();
  });

  it('extends visual selection through a hop target', () => {
    const { host, vim } = setup('|foo foo');
    press(vim, host, 'v'); press(vim, host, 'g'); press(vim, host, 'j');
    press(vim, host, 'o');
    const target = vim.snapshot.hop?.labels[0]!.pos;
    const label = vim.snapshot.hop?.labels[0]!.text;
    press(vim, host, label ?? '');
    expect(vim.snapshot.mode).toBe('visual');
    expect(host.state().selection.main.head).toBe(target);
    vim.dispose();
  });

  it('deletes inclusively for hop used as an operator target', () => {
    const text = JSON.stringify({ version: 1, hop: { enabled: true }, maps: { o: [{ lhs: 'gj', action: 'hop.char1' }] } });
    const { host, vim } = setup('|abc x'); vim.setKeymap(compileKeymap(text).keymap!);
    press(vim, host, 'd'); press(vim, host, 'g'); press(vim, host, 'j'); press(vim, host, 'x');
    press(vim, host, vim.snapshot.hop?.labels[0]!.text ?? '');
    expect(host.state().doc.toString()).toBe('');
    vim.dispose();
  });

  it('routes remapped rhs arguments through parser argument bypass', () => {
    const text = JSON.stringify({ version: 1, maps: { n: [{ lhs: 'X', rhs: 'fk', remap: true }] } });
    const { host, vim } = setup('|ak');
    vim.setKeymap(compileKeymap(text).keymap!);
    press(vim, host, 'X');
    expect(host.state().selection.main.head).toBe(1);
    vim.dispose();
  });

  it('replays a recorded hop sequence through the mapper', () => {
    const { host, vim } = setup('|foo foo');
    press(vim, host, 'q'); press(vim, host, 'a');
    press(vim, host, 'g'); press(vim, host, 'j'); press(vim, host, 'o');
    press(vim, host, 'f'); press(vim, host, 'q');
    expect(host.state().selection.main.head).toBe(1);
    press(vim, host, '@'); press(vim, host, 'a');
    expect(host.state().selection.main.head).toBe(2);
    vim.dispose();
  });

  it('makes hop mappings inert when hop is disabled', () => {
    const document = JSON.parse(KEYMAP_PRESETS[1]!.text);
    document.hop.enabled = false;
    const disabled = compileKeymap(JSON.stringify(document)).keymap!;
    const host = createTestHost('|a\nb'), vim = new VimController(host); vim.setKeymap(disabled);
    press(vim, host, 'g'); press(vim, host, 'j');
    expect(vim.snapshot.hop).toBeNull();
    expect(host.state().selection.main.head).toBe(2);
    vim.dispose();
  });

  it('runs the kaiba save and close actions from mappings', () => {
    const host = createTestHost('|abc'), vim = new VimController(host);
    vim.setKeymap(compileKeymap(JSON.stringify({ version: 1, maps: { n: [{ lhs: '<leader>w', action: 'kaiba.save' }, { lhs: '<leader>q', action: 'kaiba.close' }], i: [{ lhs: '<C-s>', action: 'kaiba.save' }] } })).keymap!);
    press(vim, host, '\\'); press(vim, host, 'w');
    expect(host.actions.save).toHaveBeenCalledOnce();
    press(vim, host, '\\'); press(vim, host, 'q');
    expect(host.actions.close).toHaveBeenCalledOnce();
    press(vim, host, 'i'); press(vim, host, '<C-s>');
    expect(host.actions.save).toHaveBeenCalledTimes(2);
    expect(host.state().doc.toString()).toBe('abc');
    vim.dispose();
  });

  it('activates extended scroll and surround execution only with a keymap', () => {
    const host = createTestHost('|one\ntwo', { viewport: { topLine: 1, rows: 1 } });
    const vim = new VimController(host); vim.setKeymap(preset);
    press(vim, host, 'z'); press(vim, host, 'j');
    expect(host.scrolls).toContain(1);
    const { host: noMap, vim: baseline } = setup('|one'); baseline.setKeymap(null);
    press(baseline, noMap, 'y'); press(baseline, noMap, 's');
    expect(noMap.state().doc.toString()).toBe('one');
    vim.dispose(); baseline.dispose();
  });

  it('executes center and directional z-scroll mappings', () => {
    const host = createTestHost('a\n|b\nc\nd\ne', { viewport: { topLine: 1, rows: 2 } });
    const vim = new VimController(host); vim.setKeymap(preset);
    press(vim, host, 'z'); press(vim, host, 'c');
    press(vim, host, 'z'); press(vim, host, 'j');
    press(vim, host, 'z'); press(vim, host, 'k');
    expect(host.scrolls).toEqual([0, 1, 0]);
    vim.dispose();
  });

  it('returns to merged K0 behavior when the keymap is removed', () => {
    const { host, vim } = setup('|a\nb');
    vim.setKeymap(null);
    press(vim, host, 'g'); press(vim, host, 'j');
    expect(host.state().selection.main.head).toBe(0);
    const insert = setup('|'); insert.vim.setKeymap(null);
    press(insert.vim, insert.host, 'i'); press(insert.vim, insert.host, 'k'); press(insert.vim, insert.host, 'j');
    expect(insert.host.state().doc.toString()).toBe('kj');
    insert.vim.dispose();
    vim.dispose();
  });
});
