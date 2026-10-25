import { describe, expect, it } from 'vitest';
import { editToken, MacroRecorder, RedoRecorder, textToTokens, tokensToText } from '../record';
import type { RecordToken } from '../types';
import { createTestHost } from './host';

function updateFor(text: string, from: number, to: number, insert: string) {
  const host = createTestHost(text);
  let update;
  host.subscribe((value) => { update = value; });
  host.dispatch({ changes: { from, to, insert } });
  if (!update) throw new Error('Expected a host update');
  return update;
}

describe('editToken', () => {
  it('records a typed character at the cursor', () => {
    const update = updateFor('ab', 1, 1, 'x');
    expect(editToken(update, 1)).toEqual({ kind: 'edit', deleteBefore: 0, deleteAfter: 0, insert: 'x' });
  });

  it('records Backspace before the cursor', () => {
    const update = updateFor('abc', 1, 2, '');
    expect(editToken(update, 2)).toEqual({ kind: 'edit', deleteBefore: 1, deleteAfter: 0, insert: '' });
  });

  it('records Delete after the cursor', () => {
    const update = updateFor('abc', 1, 2, '');
    expect(editToken(update, 1)).toEqual({ kind: 'edit', deleteBefore: 0, deleteAfter: 1, insert: '' });
  });

  it('records a completion replacement', () => {
    const update = updateFor('con', 0, 3, 'kick');
    expect(editToken(update, 3)).toEqual({ kind: 'edit', deleteBefore: 3, deleteAfter: 0, insert: 'kick' });
  });

  it('returns null when the change is away from the cursor', () => {
    expect(editToken(updateFor('abcd', 3, 4, ''), 0)).toBeNull();
  });

  it('returns null for multiple changed ranges', () => {
    const host = createTestHost('abcd');
    let update;
    host.subscribe((value) => { update = value; });
    host.dispatch({ changes: [{ from: 0, insert: 'x' }, { from: 4, insert: 'y' }] });
    expect(editToken(update!, 2)).toBeNull();
  });

  it('returns null for a selection-only update', () => {
    const host = createTestHost('abc');
    let update;
    host.subscribe((value) => { update = value; });
    host.dispatch({ selection: { anchor: 2 } });
    expect(editToken(update!, 0)).toBeNull();
  });
});

describe('RedoRecorder', () => {
  const key = (value: string): RecordToken => ({ kind: 'key', key: value });

  it('begins with a copy and appends tokens while active', () => {
    const initial = [key('c')];
    const redo = new RedoRecorder();
    redo.begin(initial);
    initial.push(key('x'));
    redo.push(key('w'));
    expect(redo.active).toBe(true);
    redo.end();
    expect(redo.last()).toEqual([key('c'), key('w')]);
  });

  it('abort drops pending tokens and preserves the previous record', () => {
    const redo = new RedoRecorder();
    redo.begin([key('x')]);
    redo.end();
    redo.begin([key('d')]);
    redo.abort();
    expect(redo.active).toBe(false);
    expect(redo.last()).toEqual([key('x')]);
  });

  it('a new begin ends an active record before replacing it', () => {
    const redo = new RedoRecorder();
    redo.begin([key('i')]);
    redo.begin([key('a')]);
    expect(redo.last()).toEqual([key('i')]);
    redo.end();
    expect(redo.last()).toEqual([key('a')]);
  });

  it('does not mutate the last record through returned arrays', () => {
    const redo = new RedoRecorder();
    redo.begin([key('x')]);
    redo.end();
    const exposed = redo.last() as RecordToken[];
    exposed.push(key('z'));
    expect(redo.last()).toEqual([key('x')]);
  });
});

describe('MacroRecorder', () => {
  it('records tokens and removes the trailing q stop key', () => {
    const macro = new MacroRecorder();
    macro.start('a');
    macro.push({ kind: 'key', key: 'i' });
    macro.push({ kind: 'key', key: 'x' });
    macro.push({ kind: 'key', key: 'q' });
    expect(macro.register).toBe('a');
    expect(macro.stop()).toEqual({ reg: 'a', tokens: [{ kind: 'key', key: 'i' }, { kind: 'key', key: 'x' }] });
    expect(macro.register).toBeNull();
  });

  it('returns null when stopped while idle', () => {
    expect(new MacroRecorder().stop()).toBeNull();
  });

  it('copies tokens passed while recording', () => {
    const macro = new MacroRecorder();
    const token: RecordToken = { kind: 'edit', deleteBefore: 0, deleteAfter: 0, insert: 'a' };
    macro.start('b');
    macro.push(token);
    token.insert = 'changed';
    expect(macro.stop()?.tokens[0]).toEqual({ kind: 'edit', deleteBefore: 0, deleteAfter: 0, insert: 'a' });
  });
});

describe('token text conversion', () => {
  it('round trips printable, named and line-break keys', () => {
    const tokens = textToTokens('ab<Esc><CR>é');
    expect(tokens).toEqual([
      { kind: 'key', key: 'a' }, { kind: 'key', key: 'b' }, { kind: 'key', key: '<Esc>' },
      { kind: 'key', key: '<CR>' }, { kind: 'key', key: 'é' },
    ]);
    expect(textToTokens(tokensToText(tokens))).toEqual(tokens);
  });

  it('keeps unknown angle-bracket text as individual graphemes', () => {
    expect(textToTokens('<Unknown>')).toEqual(Array.from('<Unknown>').map((key) => ({ kind: 'key', key })));
  });

  it('splits grapheme clusters as single keys', () => {
    expect(textToTokens('e\u0301👩‍💻')).toEqual([{ kind: 'key', key: 'e\u0301' }, { kind: 'key', key: '👩‍💻' }]);
  });

  it('encodes edit tokens with repeated backspace and delete keys', () => {
    expect(tokensToText([{ kind: 'edit', deleteBefore: 2, deleteAfter: 1, insert: 'xy' }])).toBe('<BS><BS><Del>xy');
  });

  it('encodes supported move tokens as Vim keys', () => {
    expect(tokensToText([{ kind: 'move', motion: 'h' }, { kind: 'move', motion: '0' }, { kind: 'move', motion: '$' }])).toBe('h0$');
  });
});
