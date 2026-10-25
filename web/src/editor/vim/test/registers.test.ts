import { describe, expect, it } from 'vitest';
import { isRegisterName, RegisterStore } from '../registers';
import type { Register } from '../types';
import { textToTokens } from '../record';

const value = (text: string, linewise = false, tokens?: Register['tokens']): Register => ({ text, linewise, ...(tokens ? { tokens } : {}) });

describe('isRegisterName', () => {
  it.each(['a', 'z', 'A', 'Z', '0', '9', '_', '+', '*', '"'])('accepts %s', (name) => expect(isRegisterName(name)).toBe(true));
  it.each(['', 'ab', '-', '.', ':', ' ', 'é'])('rejects %s', (name) => expect(isRegisterName(name)).toBe(false));
});

describe('RegisterStore', () => {
  it('writes unnamed and yank register 0 for an implicit yank', () => {
    const store = new RegisterStore();
    store.write(null, value('y'), 'yank');
    expect(store.read('"')).toEqual(value('y'));
    expect(store.read('0')).toEqual(value('y'));
  });
  it('does not update register 0 for a delete', () => {
    const store = new RegisterStore();
    store.write(null, value('y'), 'yank');
    store.write(null, value('d'), 'delete');
    expect(store.read('"')).toEqual(value('d'));
    expect(store.read('0')).toEqual(value('y'));
  });
  it('writes an explicit unnamed yank to unnamed and register 0', () => {
    const store = new RegisterStore();
    store.write('"', value('explicit yank'), 'yank');
    expect(store.read('"')).toEqual(value('explicit yank'));
    expect(store.read('0')).toEqual(value('explicit yank'));
  });
  it('writes an explicit unnamed delete without changing register 0', () => {
    const store = new RegisterStore();
    store.write(null, value('previous yank'), 'yank');
    store.write('"', value('explicit delete'), 'delete');
    expect(store.read('"')).toEqual(value('explicit delete'));
    expect(store.read('0')).toEqual(value('previous yank'));
  });
  it('writes an explicit register 0 yank to register 0 and unnamed', () => {
    const store = new RegisterStore();
    store.write(null, value('old'), 'delete');
    store.write('0', value('explicit register 0'), 'yank');
    expect(store.read('0')).toEqual(value('explicit register 0'));
    expect(store.read('"')).toEqual(value('explicit register 0'));
  });
  it('stores a named register and unnamed value', () => {
    const store = new RegisterStore();
    store.write('a', value('first'), 'delete');
    expect(store.read('a')).toEqual(value('first'));
    expect(store.read('"')).toEqual(value('first'));
  });
  it('reads uppercase names as lowercase named registers', () => {
    const store = new RegisterStore();
    store.write('a', value('first'), 'delete');
    expect(store.read('A')).toEqual(value('first'));
  });
  it('appends charwise text and updates unnamed', () => {
    const store = new RegisterStore();
    store.write('a', value('foo'), 'delete');
    store.write('A', value('bar'), 'delete');
    expect(store.read('a')).toEqual(value('foobar'));
    expect(store.read('"')).toEqual(value('foobar'));
  });
  it('appends with a newline and becomes linewise when either value is linewise', () => {
    const store = new RegisterStore();
    store.write('a', value('foo'), 'delete');
    store.write('A', value('bar', true), 'delete');
    expect(store.read('a')).toEqual(value('foo\nbar', true));
  });
  it('appends linewise values with a newline', () => {
    const store = new RegisterStore();
    store.write('a', value('one', true), 'delete');
    store.write('A', value('two', true), 'delete');
    expect(store.read('a')).toEqual(value('one\ntwo', true));
  });
  it('appends existing macro tokens before newly recorded tokens', () => {
    const store = new RegisterStore();
    const first = [{ kind: 'key' as const, key: 'x' }];
    const second = [{ kind: 'key' as const, key: 'y' }];
    store.write('a', value('', false, first), 'yank');
    store.write('A', value('', false, second), 'yank');
    expect(store.read('a')?.tokens).toEqual([...first, ...second]);
  });
  it('tokenizes existing text when appending macro tokens', () => {
    const store = new RegisterStore();
    const appended = [{ kind: 'key' as const, key: 'x' }];
    store.write('a', value('prior text'), 'delete');
    store.write('A', value('', false, appended), 'yank');
    expect(store.read('a')?.tokens).toEqual([...textToTokens('prior text'), ...appended]);
  });
  it('tokenizes appended text when extending an existing macro', () => {
    const store = new RegisterStore();
    const recorded = [{ kind: 'key' as const, key: 'x' }];
    store.write('a', value('', false, recorded), 'yank');
    store.write('A', value('appended text'), 'delete');
    expect(store.read('a')?.tokens).toEqual([...recorded, ...textToTokens('appended text')]);
  });
  it('keeps text-only appends as text without creating macro tokens', () => {
    const store = new RegisterStore();
    store.write('a', value('prior text'), 'delete');
    store.write('A', value('appended text'), 'delete');
    expect(store.read('a')).toEqual(value('prior textappended text'));
    expect(store.read('a')?.tokens).toBeUndefined();
  });
  it('preserves an empty appended linewise part and updates unnamed', () => {
    const store = new RegisterStore();
    store.write('a', value('foo', true), 'yank');
    store.write('A', value('', true), 'yank');
    expect(store.read('a')).toEqual(value('foo\n', true));
    expect(store.read('"')).toEqual(value('foo\n', true));
  });
  it('preserves an empty existing linewise part when appending', () => {
    const store = new RegisterStore();
    store.write('b', value('', true), 'yank');
    store.write('B', value('foo', true), 'yank');
    expect(store.read('b')).toEqual(value('\nfoo', true));
    expect(store.read('"')).toEqual(value('\nfoo', true));
  });
  it('treats append to a missing target as a plain set', () => {
    const store = new RegisterStore();
    store.write('B', value('new'), 'delete');
    expect(store.read('b')).toEqual(value('new'));
  });
  it('leaves unnamed unchanged when writing the black-hole register', () => {
    const store = new RegisterStore();
    store.write(null, value('keep'), 'delete');
    store.write('_', value('discard'), 'delete');
    expect(store.read('"')).toEqual(value('keep'));
    expect(store.read('_')).toBeNull();
  });
  it('uses a shared clipboard mirror and updates unnamed on clipboard writes', () => {
    const store = new RegisterStore();
    store.write('+', value('copy'), 'yank');
    expect(store.read('+')).toEqual(value('copy'));
    expect(store.read('*')).toEqual(value('copy'));
    expect(store.read('"')).toEqual(value('copy'));
  });
  it('can update the clipboard mirror without changing unnamed', () => {
    const store = new RegisterStore();
    store.write(null, value('old'), 'delete');
    store.setMirror('external', true);
    expect(store.read('+')).toEqual(value('external', true));
    expect(store.read('*')).toEqual(value('external', true));
    expect(store.read('"')).toEqual(value('old'));
  });
  it('identifies clipboard register names', () => {
    const store = new RegisterStore();
    expect(store.isClipboard('+')).toBe(true);
    expect(store.isClipboard('*')).toBe(true);
    expect(store.isClipboard('a')).toBe(false);
  });
  it('keeps macro tokens as given', () => {
    const store = new RegisterStore();
    const tokens = [{ kind: 'key' as const, key: 'q' }];
    store.write('a', value('', false, tokens), 'yank');
    expect(store.read('a')?.tokens).toBe(tokens);
  });
  it('returns null for unset and black-hole registers', () => {
    const store = new RegisterStore();
    expect(store.read('a')).toBeNull();
    expect(store.read('_')).toBeNull();
  });
});
