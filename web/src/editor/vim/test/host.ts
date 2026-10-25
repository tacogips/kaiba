import { history, redo, undo } from '@codemirror/commands';
import { EditorState, Transaction, type TransactionSpec } from '@codemirror/state';
import { vi } from 'vitest';
import type { ClipboardAdapter, Platform, VimHost, VimKeyInput, VimUpdate, VimViewport } from '../types';

export interface TestClipboard extends ClipboardAdapter { fail: boolean; value: string }
export interface TestHost extends VimHost { messages: { message: string; assertive: boolean }[]; scrolls: number[]; typed: string[]; defaultKeys: string[]; memoryClipboard: TestClipboard }

export function createTestHost(text: string, opts: { platform?: Platform; viewport?: VimViewport; defaultKeymaps?: (input: VimKeyInput) => boolean; clipboard?: ClipboardAdapter; isVisible?: (pos: number) => boolean } = {}): TestHost {
  const marker = text.indexOf('|');
  if (marker !== text.lastIndexOf('|')) throw new Error('Test fixture must contain at most one cursor marker');
  const source = marker < 0 ? text : `${text.slice(0, marker)}${text.slice(marker + 1)}`;
  let state = EditorState.create({ doc: source, selection: marker < 0 ? undefined : { anchor: marker }, extensions: [history()] });
  const listeners = new Set<(update: VimUpdate) => void>();
  const messages: { message: string; assertive: boolean }[] = [];
  const scrolls: number[] = [];
  const typed: string[] = [];
  const defaultKeys: string[] = [];
  let dispatching = false;
  const memoryClipboard: TestClipboard = {
    value: '', fail: false,
    async read() { if (this.fail) throw new Error('Clipboard unavailable'); return this.value; },
    async write(value: string) { if (this.fail) throw new Error('Clipboard unavailable'); this.value = value; },
  };
  const clipboard = opts.clipboard ?? memoryClipboard;
  const host: TestHost = {
    state: () => state,
    dispatch(spec: TransactionSpec) {
      if (dispatching) throw new Error('Reentrant test host dispatch');
      dispatching = true;
      try {
        const tr = state.update(spec);
        state = tr.state;
        const update: VimUpdate = { state, changes: tr.changes, docChanged: tr.docChanged, selectionSet: tr.selection !== undefined, userEvent: tr.annotation(Transaction.userEvent) ?? null };
        for (const listener of [...listeners]) listener(update);
      } finally { dispatching = false; }
    },
    subscribe(cb) { listeners.add(cb); return () => listeners.delete(cb); },
    undo: () => undo({ state, dispatch: (tr) => host.dispatch(tr) }),
    redo: () => redo({ state, dispatch: (tr) => host.dispatch(tr) }),
    historyReduced: () => false,
    viewport: () => opts.viewport ?? { topLine: 1, rows: 10 },
    scrollLines: (lines) => { scrolls.push(lines); },
    scrollCaret: vi.fn(),
    clipboard,
    memoryClipboard,
    actions: {
      save: vi.fn(), close: vi.fn(),
    },
    closePopupWithEscape: () => false,
    announce(message, assertive = false) { messages.push({ message, assertive }); },
    platform: opts.platform ?? 'other',
    matchesDefaultKeymap: (input) => opts.defaultKeymaps?.(input) ?? false,
    compositionActive: () => false,
    typeText(value) {
      const from = state.selection.main.from;
      const to = state.selection.main.to;
      typed.push(value);
      host.dispatch({ changes: { from, to, insert: value }, selection: { anchor: from + value.length }, userEvent: 'input.type' });
    },
    defaultKey(key) {
      defaultKeys.push(key);
      const { from, to } = state.selection.main;
      if (key === '<BS>') {
        const start = from === to ? Math.max(0, from - 1) : from;
        host.dispatch({ changes: { from: start, to, insert: '' }, selection: { anchor: start }, userEvent: 'delete.backward' });
        return true;
      }
      if (key === '<Del>') {
        const end = from === to ? Math.min(state.doc.length, to + 1) : to;
        host.dispatch({ changes: { from, to: end, insert: '' }, selection: { anchor: from }, userEvent: 'delete.forward' });
        return true;
      }
      if (key === '<Left>' || key === '<Right>') {
        const pos = Math.max(0, Math.min(state.doc.length, state.selection.main.head + (key === '<Left>' ? -1 : 1)));
        host.dispatch({ selection: { anchor: pos }, userEvent: 'select' });
        return true;
      }
      if (key === '<CR>') {
        host.dispatch({ changes: { from, to, insert: '\n' }, selection: { anchor: from + 1 }, userEvent: 'input.type' });
        return true;
      }
      return false;
    },
    isVisible: (pos) => opts.isVisible?.(pos) ?? true,
    timer(ms, cb) {
      const id = setTimeout(cb, ms);
      return () => clearTimeout(id);
    },
    messages,
    scrolls,
    typed,
    defaultKeys,
  };
  return host;
}

export function show(state: EditorState): string {
  const pos = state.selection.main.head;
  return `${state.doc.sliceString(0, pos)}|${state.doc.sliceString(pos)}`;
}
