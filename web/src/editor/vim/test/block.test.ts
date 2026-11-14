import { describe, expect, it } from 'vitest';
import { EditorState } from '@codemirror/state';
import { VimController } from '../controller';
import { visualBlockRanges } from '../block';
import { createTestHost } from './host';

function fixture(source: string) {
  const host = createTestHost(source), vim = new VimController(host);
  const press = (key: string, ctrlKey = false) => vim.handleKey({ key, code: ctrlKey ? `Key${key.toUpperCase()}` : undefined, ctrlKey, metaKey: false, altKey: false, shiftKey: key === 'V' });
  return { host, vim, press };
}

describe('Vim rectangular selection', () => {
  it('selects one exclusive range per line and clamps short lines', () => {
    const state = EditorState.create({ doc: 'abcd\nx\n12345' });
    expect(visualBlockRanges(state, 2, 11)).toEqual([
      { from: 2, to: 4, linewise: false }, { from: 6, to: 6, linewise: false }, { from: 9, to: 12, linewise: false },
    ]);
  });
  it('moves a rectangle with j/k and deletes only its columns as one undoable change', () => {
    const view = fixture('a|bcd\nefgh\nijkl');
    view.press('v', true); view.press('j'); view.press('l');
    expect(view.vim.snapshot.mode).toBe('visual-block');
    expect(view.vim.snapshot.blockRanges?.map((range) => view.host.state().doc.sliceString(range.from, range.to))).toEqual(['bc', 'fg']);
    view.press('d'); expect(view.host.state().doc.toString()).toBe('ad\neh\nijkl');
    expect(view.vim.snapshot.mode).toBe('normal');
    view.press('u'); expect(view.host.state().doc.toString()).toBe('abcd\nefgh\nijkl');
    view.vim.dispose();
  });
  it('yanks only the rectangle and preserves the source', () => {
    const view = fixture('a|bcd\nefgh\nijkl');
    view.press('v', true); view.press('j'); view.press('l'); view.press('y');
    expect(view.host.memoryClipboard.value).toBe('bc\nfg');
    expect(view.host.state().doc.toString()).toBe('abcd\nefgh\nijkl');
    expect(view.vim.snapshot.mode).toBe('normal'); view.vim.dispose();
  });
  it('switches between visual modes and preserves the moving end of a backwards selection', () => {
    const view = fixture('abcd\nef|gh');
    view.press('v', true); view.press('k'); view.press('h');
    expect(view.vim.snapshot.blockRanges?.map((range) => view.host.state().doc.sliceString(range.from, range.to))).toEqual(['bc', 'fg']);
    view.press('V'); expect(view.vim.snapshot.mode).toBe('visual-line');
    view.press('v', true); expect(view.vim.snapshot.mode).toBe('visual-block');
    view.press('Escape'); expect(view.vim.snapshot.mode).toBe('normal');
    expect(view.vim.snapshot.displayCursor).toBe(1); view.vim.dispose();
  });
  it('puts a rectangular yank back as columns rather than inserting new lines into a row', () => {
    const view = fixture('a|bcd\nefgh\nijkl');
    view.press('v', true); view.press('j'); view.press('l'); view.press('y'); view.press('P');
    expect(view.host.state().doc.toString()).toBe('abcbcd\nefgfgh\nijkl');
    view.vim.dispose();
  });
  it('replaces only rectangular cells, including a backwards selection', () => {
    const view = fixture('abcd\nef|gh');
    view.press('v', true); view.press('k'); view.press('h'); view.press('r'); view.press('X');
    expect(view.host.state().doc.toString()).toBe('aXXd\neXXh');
    view.vim.dispose();
  });
  it('does not split surrogate pairs or combining graphemes at rectangle edges', () => {
    const state = EditorState.create({ doc: 'ae\u0301z\nb👩‍💻x' });
    expect(visualBlockRanges(state, 1, 6).map((range) => state.doc.sliceString(range.from, range.to))).toEqual(['e\u0301', '👩‍💻']);
  });

  it('changes the rectangle on every selected line and undoes the entire change once', () => {
    const view = fixture('a|bcd\nefgh\nijkl');
    view.press('v', true); view.press('j'); view.press('l'); view.press('c');
    expect(view.vim.snapshot.mode).toBe('insert');
    view.host.typeText('XY'); view.press('Escape');
    expect(view.host.state().doc.toString()).toBe('aXYd\neXYh\nijkl');
    view.press('u'); expect(view.host.state().doc.toString()).toBe('abcd\nefgh\nijkl');
    view.vim.dispose();
  });

  it.each([['I', 'aXbcd\neXfgh'], ['A', 'abcXd\nefgXh']] as const)('inserts %s at the corresponding edge on each selected row', (key, expected) => {
    const view = fixture('a|bcd\nefgh');
    view.press('v', true); view.press('j'); view.press('l'); view.press(key);
    view.host.typeText('X'); view.press('Escape');
    expect(view.host.state().doc.toString()).toBe(expected);
    view.press('u'); expect(view.host.state().doc.toString()).toBe('abcd\nefgh');
    view.vim.dispose();
  });

});
