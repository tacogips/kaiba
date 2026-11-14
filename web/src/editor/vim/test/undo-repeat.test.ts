import { describe, expect, it } from 'vitest';
import { Transaction } from '@codemirror/state';
import { VimController } from '../controller';
import { createTestHost } from './host';

const key = (value: string) => ({ key: value, ctrlKey: false, metaKey: false, altKey: false, shiftKey: false });
const type = (host: ReturnType<typeof createTestHost>, text: string) => {
  for (const char of text) { const pos = host.state().selection.main.head; host.dispatch({ changes: { from: pos, insert: char }, selection: { anchor: pos + char.length }, annotations: Transaction.userEvent.of('input.type') }); }
};

describe('Vim undo and dot repeat', () => {
  it('groups insert session into one undo unit despite separate input events', () => {
    const host = createTestHost('a|'), vim = new VimController(host);
    vim.handleKey(key('i')); type(host, 'xyz'); vim.handleKey(key('Escape'));
    expect(host.state().doc.toString()).toBe('axyz');
    vim.handleKey(key('u'));
    expect(host.state().doc.toString()).toBe('a');
  });
  it('repeats insert text and dot is one undo step', () => {
    const host = createTestHost('|'), vim = new VimController(host);
    vim.handleKey(key('3')); vim.handleKey(key('i')); type(host, 'h'); vim.handleKey(key('Escape'));
    expect(host.state().doc.toString()).toBe('hhh');
    vim.handleKey(key('.'));
    expect(host.state().doc.toString()).toBe('hhhhhh');
    expect(vim.snapshot.mode).toBe('normal');
    expect(vim.snapshot.pending).toBe('');
    vim.handleKey(key('u'));
    expect(host.state().doc.toString()).toBe('hhh');
  });
  it('repeats operator edits with their count', () => {
    const host = createTestHost('|one two three'), vim = new VimController(host);
    vim.handleKey(key('2')); vim.handleKey(key('d')); vim.handleKey(key('w'));
    expect(host.state().doc.toString()).toBe('three');
    vim.handleKey(key('.'));
    expect(host.state().doc.toString()).toBe('');
  });
  it('visual changes do not replace the previous normal redo record', () => {
    const host = createTestHost('|one two three'), vim = new VimController(host);
    vim.handleKey(key('d')); vim.handleKey(key('w'));
    vim.handleKey(key('v')); vim.handleKey(key('l')); vim.handleKey(key('d'));
    expect(host.state().doc.toString()).toBe('o three');
    expect(vim.snapshot.mode).toBe('normal');
    expect(vim.snapshot.pending).toBe('');
    vim.handleKey(key('.'));
    expect(vim.snapshot.mode).toBe('normal');
    expect(host.state().doc.toString()).toBe('three');
  });
  it('treats input events 600ms apart as one insert undo unit', () => {
    const host = createTestHost('|'), vim = new VimController(host), now = Date.now();
    vim.handleKey(key('i'));
    for (const [index, ch] of [...'abc'].entries()) {
      const pos = host.state().selection.main.head;
      host.dispatch({ changes: { from: pos, insert: ch }, selection: { anchor: pos + 1 }, annotations: [Transaction.userEvent.of('input.type'), Transaction.time.of(now + index * 600)] });
    }
    vim.handleKey(key('Escape')); expect(host.state().doc.toString()).toBe('abc');
    vim.handleKey(key('u')); expect(host.state().doc.toString()).toBe('');
  });
  it('groups cw and typed replacement into one undo unit', () => {
    const host = createTestHost('|foo bar'), vim = new VimController(host);
    vim.handleKey(key('c')); vim.handleKey(key('w')); type(host, 'baz'); vim.handleKey(key('Escape'));
    expect(host.state().doc.toString()).toBe('baz bar'); vim.handleKey(key('u'));
    expect(host.state().doc.toString()).toBe('foo bar');
  });
  it('undoes an external format-style edit as one history step', () => {
    const host = createTestHost('|abc'), vim = new VimController(host);
    host.dispatch({ changes: { from: 0, to: 3, insert: 'a b c' }, annotations: [Transaction.userEvent.of('input.format')] });
    expect(host.state().doc.toString()).toBe('a b c'); vim.handleKey(key('u'));
    expect(host.state().doc.toString()).toBe('abc');
  });
  it('repeats ciw replacement at the next word', () => {
    const host = createTestHost('|foo baz'), vim = new VimController(host);
    vim.handleKey(key('c')); vim.handleKey(key('i')); vim.handleKey(key('w')); type(host, 'bar'); vim.handleKey(key('Escape'));
    vim.handleKey(key('w')); vim.handleKey(key('.'));
    expect(host.state().doc.toString()).toBe('bar bar'); expect(host.state().selection.main.head).toBe(6);
  });
  it('repeats A insertion at the next line end', () => {
    const host = createTestHost('|a\nb'), vim = new VimController(host);
    vim.handleKey(key('A')); type(host, ';'); vim.handleKey(key('Escape')); vim.handleKey(key('j')); vim.handleKey(key('$')); vim.handleKey(key('.'));
    expect(host.state().doc.toString()).toBe('a;\nb;');
  });
  it('repeats counted x delete', () => {
    const host = createTestHost('|abcdefghij'), vim = new VimController(host);
    vim.handleKey(key('3')); vim.handleKey(key('x'));
    expect(host.state().doc.toString()).toBe('defghij'); vim.handleKey(key('2')); vim.handleKey(key('.'));
    expect(host.state().doc.toString()).toBe('fghij');
  });
  it('repeats dd on the following line', () => {
    const host = createTestHost('|one\ntwo\nthree'), vim = new VimController(host);
    vim.handleKey(key('d')); vim.handleKey(key('d')); vim.handleKey(key('.'));
    expect(host.state().doc.toString()).toBe('three');
  });
  it('repeats 3ihi insertion as one command', () => {
    const host = createTestHost('|'), vim = new VimController(host);
    vim.handleKey(key('3')); vim.handleKey(key('i')); type(host, 'hi'); vim.handleKey(key('Escape'));
    expect(host.state().doc.toString()).toBe('hihihi');
  });
  it('repeats cwX with the count supplied to dot', () => {
    const host = createTestHost('|one two three'), vim = new VimController(host);
    vim.handleKey(key('c')); vim.handleKey(key('w')); type(host, 'X'); vim.handleKey(key('Escape'));
    vim.handleKey(key('2')); vim.handleKey(key('.'));
    expect(host.state().doc.toString()).toBe('X three');
  });
  it('records and repeats a composed IME commit', () => {
    const host = createTestHost('|a'), vim = new VimController(host);
    vim.handleKey(key('i')); host.dispatch({ changes: { from: 0, insert: '漢' }, selection: { anchor: 1 }, annotations: Transaction.userEvent.of('input.type.compose.start') });
    vim.handleKey(key('Escape')); vim.handleKey(key('.'));
    expect(host.state().doc.toString()).toBe('漢漢a');
  });
  it('records a dot replay as one undo unit', () => {
    const host = createTestHost('|abc'), vim = new VimController(host);
    vim.handleKey(key('x')); vim.handleKey(key('.')); expect(host.state().doc.toString()).toBe('c');
    vim.handleKey(key('u')); expect(host.state().doc.toString()).toBe('bc');
    vim.handleKey(key('u')); expect(host.state().doc.toString()).toBe('abc');
  });
  it('repeats ciwbar after a word motion without inserting motion keys', () => {
    const host = createTestHost('|foo baz'), vim = new VimController(host);
    vim.handleKey(key('c')); vim.handleKey(key('i')); vim.handleKey(key('w')); type(host, 'bar'); vim.handleKey(key('Escape'));
    vim.handleKey(key('w')); expect(host.state().selection.main.head).toBe(4); vim.handleKey(key('.'));
    expect(host.state().doc.toString()).toBe('bar bar'); expect(vim.snapshot.mode).toBe('normal');
  });
  it('repeats counted insert then one undo removes only the repeated text', () => {
    const host = createTestHost('|'), vim = new VimController(host);
    vim.handleKey(key('3')); vim.handleKey(key('i')); type(host, 'hi'); vim.handleKey(key('Escape'));
    expect(host.state().doc.toString()).toBe('hihihi'); vim.handleKey(key('.'));
    expect(host.state().doc.toString()).toBe('hihihhihihii'); vim.handleKey(key('u')); expect(host.state().doc.toString()).toBe('hihihi');
  });
  it('visual-only change does not create a redo record on a fresh controller', () => {
    const host = createTestHost('|abc'), vim = new VimController(host);
    vim.handleKey(key('v')); vim.handleKey(key('j')); vim.handleKey(key('d')); const before = host.state().doc.toString();
    vim.handleKey(key('.')); expect(host.state().doc.toString()).toBe(before);
    expect(vim.snapshot.mode).toBe('normal'); expect(vim.snapshot.pending).toBe('');
  });
  it('visual changes preserve a prior normal delete redo record', () => {
    const host = createTestHost('|one two three'), vim = new VimController(host);
    vim.handleKey(key('d')); vim.handleKey(key('w')); vim.handleKey(key('v')); vim.handleKey(key('l')); vim.handleKey(key('d'));
    expect(host.state().doc.toString()).toBe('o three'); vim.handleKey(key('.'));
    expect(host.state().doc.toString()).toBe('three');
  });
  it('keeps w as a motion after ciwbar dot replay', () => {
    const host = createTestHost('|foo baz'), vim = new VimController(host);
    vim.handleKey(key('c')); vim.handleKey(key('i')); vim.handleKey(key('w')); type(host, 'bar'); vim.handleKey(key('Escape'));
    vim.handleKey(key('w')); expect(host.state().selection.main.head).toBe(4); vim.handleKey(key('.')); vim.handleKey(key('w'));
    expect(host.state().doc.toString()).toBe('bar bar'); expect(vim.snapshot.mode).toBe('normal');
  });
  it('tapMode ends an insert redo record with normal mode', () => {
    const host = createTestHost('|abc'), vim = new VimController(host);
    vim.tapMode(); type(host, 'x'); vim.tapMode(); vim.handleKey(key('.'));
    expect(host.state().doc.toString()).toBe('xxabc'); expect(vim.snapshot.mode).toBe('normal');
  });
  it('supports undo then redo through the ledger', () => {
    const host = createTestHost('abc|'), vim = new VimController(host);
    vim.handleKey(key('x')); expect(host.state().doc.toString()).toBe('ab');
    vim.handleKey(key('u')); expect(host.state().doc.toString()).toBe('abc');
    vim.handleKey({ ...key('r'), ctrlKey: true }); expect(host.state().doc.toString()).toBe('ab');
  });
  it('rebases insert edit tokens after arrow movement and starts a new dot record', () => {
    const host = createTestHost('|ab'), vim = new VimController(host);
    vim.handleKey(key('i')); type(host, 'x');
    expect(vim.handleKey(key('ArrowRight'))).toBe(false);
    host.dispatch({ selection: { anchor: 2 } });
    type(host, 'y'); vim.handleKey(key('Escape'));
    expect(host.state().doc.toString()).toBe('xayb');
    vim.handleKey(key('.'));
    expect(host.state().doc.toString()).toBe('xayyb');
  });
  it('repeats d3w once with the operator count preserved', () => {
    const host = createTestHost('|a b c d e f g h i j'), vim = new VimController(host);
    for (const value of ['d', '3', 'w', '.']) vim.handleKey(key(value));
    expect(host.state().doc.toString()).toBe('g h i j');
  });
  it('lets a dot count replace the count after an operator', () => {
    const host = createTestHost('|a b c d e f g h'), vim = new VimController(host);
    for (const value of ['d', '3', 'w', '2', '.']) vim.handleKey(key(value));
    expect(host.state().doc.toString()).toBe('f g h');
  });
  it('repeats a counted vertical operator without squaring its count', () => {
    const host = createTestHost('|a\nb\nc\nd\ne\nf\ng'), vim = new VimController(host);
    for (const value of ['d', '2', 'j', '.']) vim.handleKey(key(value));
    expect(host.state().doc.toString()).toBe('g');
  });
  it('preserves a count after a register prefix for dot replay', () => {
    const host = createTestHost('|abcdefghij'), vim = new VimController(host);
    for (const value of ['"', 'a', '3', 'x', '.']) vim.handleKey(key(value));
    expect(host.state().doc.toString()).toBe('ghij');
  });
  it('preserves a combined prefix and operator count for dot replay', () => {
    const host = createTestHost('|a b c d e f g h i j k l m n'), vim = new VimController(host);
    for (const value of ['2', 'd', '3', 'w', '.']) vim.handleKey(key(value));
    expect(host.state().doc.toString()).toBe('m n');
  });
  it('keeps find and replace argument digits in dot records', () => {
    const findHost = createTestHost('|ab3cd3'), findVim = new VimController(findHost);
    for (const value of ['d', 'f', '3', '.']) findVim.handleKey(key(value));
    expect(findHost.state().doc.toString()).toBe('');
    const replaceHost = createTestHost('|abcdef'), replaceVim = new VimController(replaceHost);
    for (const value of ['3', 'r', '3', '.']) replaceVim.handleKey(key(value));
    expect(replaceHost.state().doc.toString()).toBe('33333f');
  });
  it('preserves register zero and the zero motion in dot records', () => {
    const registerHost = createTestHost('|abc'), registerVim = new VimController(registerHost);
    for (const value of ['y', 'y', '"', '0', 'p', '.']) registerVim.handleKey(key(value));
    expect(registerHost.state().doc.toString()).toBe('abc\nabc\nabc');
    const motionHost = createTestHost('ab|cd'), motionVim = new VimController(motionHost);
    for (const value of ['d', '0', '.']) motionVim.handleKey(key(value));
    expect(motionHost.state().doc.toString()).toBe('cd');
  });
  it('does not replace the previous dot record with visual c input', () => {
    const host = createTestHost('|one two three'), vim = new VimController(host);
    for (const value of ['d', 'w', 'v', 'e', 'c']) vim.handleKey(key(value));
    type(host, 'X'); vim.handleKey(key('Escape')); vim.handleKey(key('w')); vim.handleKey(key('.'));
    expect(host.state().doc.toString()).toBe('X ');
    expect(vim.snapshot.mode).toBe('normal'); expect(vim.snapshot.pending).toBe('');
  });
  it('does not create a dot record for visual c when no prior change exists', () => {
    const host = createTestHost('|one two three'), vim = new VimController(host);
    for (const value of ['v', 'e', 'c']) vim.handleKey(key(value));
    type(host, 'X'); vim.handleKey(key('Escape'));
    const changed = host.state().doc.toString(); vim.handleKey(key('.'));
    expect(host.state().doc.toString()).toBe(changed);
    expect(vim.snapshot.mode).toBe('normal'); expect(vim.snapshot.pending).toBe('');
  });
});
