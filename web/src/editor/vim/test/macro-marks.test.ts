import { describe, expect, it } from 'vitest';
import { Transaction } from '@codemirror/state';
import { VimController } from '../controller';
import { createTestHost } from './host';

const key = (value: string) => ({ key: value, ctrlKey: false, metaKey: false, altKey: false, shiftKey: false });
const type = (host: ReturnType<typeof createTestHost>, text: string) => { for (const ch of text) { const pos = host.state().selection.main.head; host.dispatch({ changes: { from: pos, insert: ch }, selection: { anchor: pos + ch.length }, annotations: Transaction.userEvent.of('input.type') }); } };

describe('Vim macros and marks', () => {
  it('records insert session with Esc and replays it', () => {
    const host = createTestHost('a|'), vim = new VimController(host);
    vim.handleKey(key('q')); vim.handleKey(key('a')); vim.handleKey(key('A')); type(host, ';'); vim.handleKey(key('Escape')); vim.handleKey(key('q'));
    expect(host.state().doc.toString()).toBe('a;');
    vim.handleKey(key('0')); vim.handleKey(key('@')); vim.handleKey(key('a'));
    expect(host.state().doc.toString()).toBe('a;;');
    expect(vim.snapshot.mode).toBe('normal');
  });
  it('sets and jumps to a mark and reports unset marks', () => {
    const host = createTestHost('abc|\ndef'), vim = new VimController(host);
    vim.handleKey(key('m')); vim.handleKey(key('a')); vim.handleKey(key('j'));
    vim.handleKey(key('`')); vim.handleKey(key('a'));
    expect(host.state().selection.main.head).toBe(2);
    vim.handleKey(key("'")); vim.handleKey(key('z'));
    expect(vim.snapshot.message).toContain('E20');
  });
  it('stops macros and keeps the last register playable with @@', () => {
    const host = createTestHost('|abc'), vim = new VimController(host);
    vim.handleKey(key('q')); vim.handleKey(key('a')); vim.handleKey(key('x')); vim.handleKey(key('q'));
    vim.handleKey(key('@')); vim.handleKey(key('a'));
    expect(host.state().doc.toString()).toBe('c');
    vim.handleKey(key('@')); vim.handleKey(key('@'));
    expect(host.state().doc.toString()).toBe('');
  });
  it('stops a self-recursive macro and permits a later independent replay attempt', () => {
    const host = createTestHost('|a'), vim = new VimController(host);
    vim.handleKey(key('q')); vim.handleKey(key('a')); vim.handleKey(key('@')); vim.handleKey(key('a')); vim.handleKey(key('q'));
    vim.handleKey(key('@')); vim.handleKey(key('a'));
    expect(vim.snapshot.message).toContain('E169');
    vim.handleKey(key('@')); vim.handleKey(key('a'));
    expect(vim.snapshot.message).toContain('E169');
    expect(vim.snapshot.mode).toBe('normal');
  });
  it('replays qaddq@a against the next word', () => {
    const host = createTestHost('|one two'), vim = new VimController(host);
    vim.handleKey(key('q')); vim.handleKey(key('a')); vim.handleKey(key('d')); vim.handleKey(key('w')); vim.handleKey(key('q'));
    expect(host.state().doc.toString()).toBe('two'); vim.handleKey(key('@')); vim.handleKey(key('a'));
    expect(host.state().doc.toString()).toBe('');
  });
  it('plays the previous macro with @@', () => {
    const host = createTestHost('|abcd'), vim = new VimController(host);
    vim.handleKey(key('q')); vim.handleKey(key('a')); vim.handleKey(key('x')); vim.handleKey(key('q'));
    vim.handleKey(key('@')); vim.handleKey(key('a')); vim.handleKey(key('@')); vim.handleKey(key('@'));
    expect(host.state().doc.toString()).toBe('d'); expect(host.state().selection.main.head).toBe(0);
  });
  it('replays a macro three times', () => {
    const host = createTestHost('|abcd'), vim = new VimController(host);
    vim.handleKey(key('q')); vim.handleKey(key('a')); vim.handleKey(key('x')); vim.handleKey(key('q'));
    vim.handleKey(key('3')); vim.handleKey(key('@')); vim.handleKey(key('a'));
    expect(host.state().doc.toString()).toBe('');
  });
  it('qA appends commands to an existing macro', () => {
    const host = createTestHost('|abcd'), vim = new VimController(host);
    vim.handleKey(key('q')); vim.handleKey(key('a')); vim.handleKey(key('x')); vim.handleKey(key('q'));
    vim.handleKey(key('q')); vim.handleKey(key('A')); vim.handleKey(key('x')); vim.handleKey(key('q'));
    vim.handleKey(key('@')); vim.handleKey(key('a'));
    expect(host.state().doc.toString()).toBe('');
  });
  it('puts macro text with its explicit Esc token', () => {
    const host = createTestHost('|abc'), vim = new VimController(host);
    vim.handleKey(key('q')); vim.handleKey(key('a')); vim.handleKey(key('i')); type(host, 'x'); vim.handleKey(key('Escape')); vim.handleKey(key('q'));
    vim.handleKey(key('0')); vim.handleKey(key('"')); vim.handleKey(key('a')); vim.handleKey(key('p'));
    expect(host.state().doc.toString()).toContain('<Esc>');
    expect(host.state().doc.toString()).toContain('i');
  });
  it('plays a yanked register as a macro', () => {
    const host = createTestHost('|x'), vim = new VimController(host);
    vim.handleKey(key('"')); vim.handleKey(key('a')); vim.handleKey(key('y')); vim.handleKey(key('w'));
    vim.handleKey(key('@')); vim.handleKey(key('a'));
    expect(host.state().doc.toString()).toBe('');
  });
  it('maps a mark when lines are inserted above it', () => {
    const host = createTestHost('first\n|target\nlast'), vim = new VimController(host);
    vim.handleKey(key('m')); vim.handleKey(key('a')); vim.handleKey(key('g')); vim.handleKey(key('g'));
    vim.handleKey(key('O')); type(host, 'new'); vim.handleKey(key('Escape')); vim.handleKey(key("'")); vim.handleKey(key('a'));
    expect(host.state().doc.toString()).toBe('new\nfirst\ntarget\nlast');
    expect(host.state().selection.main.head).toBe(10);
  });
  it('records insert exit and motion in qaA;<Esc>jq then gg@a', () => {
    const host = createTestHost('|a\nb'), vim = new VimController(host);
    vim.handleKey(key('q')); vim.handleKey(key('a')); vim.handleKey(key('A')); type(host, ';'); vim.handleKey(key('Escape')); vim.handleKey(key('j')); vim.handleKey(key('q'));
    expect(host.state().doc.toString()).toBe('a;\nb');
    vim.handleKey(key('g')); vim.handleKey(key('g')); vim.handleKey(key('@')); vim.handleKey(key('a'));
    expect(host.state().doc.toString()).toBe('a;;\nb');
    expect(vim.snapshot.mode).toBe('normal'); expect(host.state().selection.main.head).toBe(4);
  });
  it('ends a recorded insert through tapMode and replays its Esc', () => {
    const host = createTestHost('|a'), vim = new VimController(host);
    vim.handleKey(key('q')); vim.handleKey(key('a')); vim.handleKey(key('A')); type(host, ';'); vim.tapMode(); vim.handleKey(key('q'));
    vim.handleKey(key('0')); vim.handleKey(key('@')); vim.handleKey(key('a'));
    expect(host.state().doc.toString()).toBe('a;;'); expect(vim.snapshot.mode).toBe('normal');
  });
  it('keeps the macro recorder mode and document consistent for insert replay', () => {
    const host = createTestHost('|ab'), vim = new VimController(host);
    vim.handleKey(key('q')); vim.handleKey(key('a')); vim.handleKey(key('i')); type(host, 'z'); vim.handleKey(key('Escape')); vim.handleKey(key('q'));
    vim.handleKey(key('0')); vim.handleKey(key('@')); vim.handleKey(key('a'));
    expect(host.state().doc.toString()).toBe('zzab'); expect(vim.snapshot.mode).toBe('normal');
  });
  it('keeps the repeat cursor after macro playback at the last edit', () => {
    const host = createTestHost('|abc'), vim = new VimController(host);
    vim.handleKey(key('q')); vim.handleKey(key('a')); vim.handleKey(key('i')); type(host, 'x'); vim.handleKey(key('Escape')); vim.handleKey(key('q'));
    vim.handleKey(key('@')); vim.handleKey(key('a'));
    expect(host.state().doc.toString()).toBe('xxabc'); expect(host.state().selection.main.head).toBe(0);
  });
  it('keeps an unused register from changing the document during macro playback', () => {
    const host = createTestHost('|abc'), vim = new VimController(host);
    vim.handleKey(key('q')); vim.handleKey(key('a')); vim.handleKey(key('l')); vim.handleKey(key('q'));
    vim.handleKey(key('0')); vim.handleKey(key('@')); vim.handleKey(key('a'));
    expect(host.state().doc.toString()).toBe('abc'); expect(host.state().selection.main.head).toBe(1);
  });
  it('replays a charwise put in a macro exactly once', () => {
    const host = createTestHost('|ab'), vim = new VimController(host);
    for (const value of ['y', 'l', 'q', 'a', 'p', 'q']) vim.handleKey(key(value));
    expect(host.state().doc.toString()).toBe('aab');
    for (const value of ['0', '@', 'a']) vim.handleKey(key(value));
    expect(host.state().doc.toString()).toBe('aaab');
    expect(vim.snapshot.mode).toBe('normal'); expect(host.state().selection.main.head).toBe(1);
  });
  it('replays a linewise yyp macro exactly once', () => {
    const host = createTestHost('|one'), vim = new VimController(host);
    for (const value of ['q', 'a', 'y', 'y', 'p', 'q']) vim.handleKey(key(value));
    expect(host.state().doc.toString()).toBe('one\none');
    for (const value of ['@', 'a']) vim.handleKey(key(value));
    expect(host.state().doc.toString()).toBe('one\none\none');
    expect(vim.snapshot.mode).toBe('normal');
  });
  it('records a put key once in the macro register text', () => {
    const host = createTestHost('|ab'), vim = new VimController(host);
    for (const value of ['y', 'l', 'q', 'a', 'p', 'q', '0', '"', 'a', 'p']) vim.handleKey(key(value));
    expect(host.state().doc.toString()).toBe('apab');
    expect(vim.snapshot.mode).toBe('normal');
  });
});
