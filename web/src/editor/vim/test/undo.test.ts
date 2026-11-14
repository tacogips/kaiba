import { Transaction } from '@codemirror/state';
import { describe, expect, it, vi } from 'vitest';
import { UndoLedger } from '../undo';
import { createTestHost, show } from './host';

function typeAtEnd(host: ReturnType<typeof createTestHost>, text: string, time: number): void {
  const state = host.state();
  host.dispatch({
    changes: { from: state.doc.length, insert: text },
    annotations: [Transaction.time.of(time), Transaction.userEvent.of('input.type')],
  });
}

describe('UndoLedger', () => {
  it('undoes a multi-event unit in one command and redoes all of it', () => {
    const host = createTestHost('');
    const ledger = new UndoLedger();
    const entryDepth = 0;
    typeAtEnd(host, 'a', 1000);
    typeAtEnd(host, 'b', 1600);
    typeAtEnd(host, 'c', 2200);
    ledger.record({ entryDepth, exitDepth: 3, exitDoc: host.state().doc });
    ledger.undo(host);
    expect(host.state().doc.toString()).toBe('');
    ledger.redo(host);
    expect(host.state().doc.toString()).toBe('abc');
  });

  it('falls back for an external edit, then recognizes the recorded unit', () => {
    const host = createTestHost('');
    const ledger = new UndoLedger();
    typeAtEnd(host, 'a', 1000);
    typeAtEnd(host, 'b', 1600);
    ledger.record({ entryDepth: 0, exitDepth: 2, exitDoc: host.state().doc });
    typeAtEnd(host, 'x', 2200);
    ledger.undo(host);
    expect(host.state().doc.toString()).toBe('ab');
    ledger.undo(host);
    expect(host.state().doc.toString()).toBe('');
  });

  it('clears redo units after a non-history change', () => {
    const host = createTestHost('');
    const ledger = new UndoLedger();
    typeAtEnd(host, 'a', 1000);
    ledger.record({ entryDepth: 0, exitDepth: 1, exitDoc: host.state().doc });
    ledger.undo(host);
    ledger.noteChange(false);
    ledger.redo(host);
    expect(host.state().doc.toString()).toBe('a');
  });

  it('keeps redo units when notified of a history update', () => {
    const ledger = new UndoLedger();
    ledger.noteChange(true);
    const host = createTestHost('');
    typeAtEnd(host, 'a', 1000);
    ledger.record({ entryDepth: 0, exitDepth: 1, exitDoc: host.state().doc });
    ledger.undo(host);
    ledger.noteChange(true);
    ledger.redo(host);
    expect(host.state().doc.toString()).toBe('a');
  });

  it('ignores units without a new history event', () => {
    const host = createTestHost('abc|');
    const ledger = new UndoLedger();
    ledger.record({ entryDepth: 0, exitDepth: 0, exitDoc: host.state().doc });
    const undo = vi.spyOn(host, 'undo');
    ledger.undo(host);
    expect(undo).toHaveBeenCalledOnce();
  });

  it('clears recorded units and uses single-step undo', () => {
    const host = createTestHost('');
    const ledger = new UndoLedger();
    typeAtEnd(host, 'a', 1000);
    ledger.record({ entryDepth: 0, exitDepth: 1, exitDoc: host.state().doc });
    ledger.clear();
    ledger.undo(host);
    expect(host.state().doc.toString()).toBe('');
  });

  it('does not pop the ledger when the current doc fails its content guard', () => {
    const host = createTestHost('');
    const ledger = new UndoLedger();
    typeAtEnd(host, 'a', 1000);
    ledger.record({ entryDepth: 0, exitDepth: 1, exitDoc: host.state().doc });
    const state = host.state();
    host.dispatch({ changes: { from: 0, to: 1, insert: 'b' }, annotations: Transaction.time.of(1600) });
    ledger.undo(host);
    expect(host.state().doc.toString()).toBe('a');
    ledger.undo(host);
    expect(host.state().doc.toString()).toBe('');
    expect(state.doc.toString()).toBe('a');
  });

  it('stops if host undo returns false early', () => {
    const host = createTestHost('');
    typeAtEnd(host, 'a', 1000);
    typeAtEnd(host, 'b', 1600);
    const ledger = new UndoLedger();
    ledger.record({ entryDepth: 0, exitDepth: 2, exitDoc: host.state().doc });
    const spy = vi.spyOn(host, 'undo').mockImplementationOnce(() => false);
    ledger.undo(host);
    expect(spy).toHaveBeenCalledOnce();
    spy.mockRestore();
  });

  it('uses a normal history fallback when no unit is recorded', () => {
    const host = createTestHost('');
    typeAtEnd(host, 'x', 1000);
    const ledger = new UndoLedger();
    ledger.undo(host);
    expect(host.state().doc.toString()).toBe('');
  });

  it('maps state output through the existing history host', () => {
    const host = createTestHost('|abc');
    typeAtEnd(host, 'x', 1000);
    const ledger = new UndoLedger();
    ledger.record({ entryDepth: 0, exitDepth: 1, exitDoc: host.state().doc });
    ledger.undo(host);
    expect(show(host.state())).toBe('|abc');
  });
});
