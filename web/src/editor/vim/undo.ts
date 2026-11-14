import { redoDepth, undoDepth } from '@codemirror/commands';
import type { Text } from '@codemirror/state';
import type { VimHost } from './types';

type Unit = { entryDepth: number; exitDepth: number; exitDoc: Text };
type Undone = { redoEntry: number; redoExit: number; doc: Text; unit: Unit };

export class UndoLedger {
  private done: Unit[] = [];
  private undone: Undone[] = [];

  record(unit: Unit): void {
    if (unit.exitDepth <= unit.entryDepth) return;
    this.done.push({ ...unit });
  }

  undo(host: Pick<VimHost, 'state' | 'undo'>): void {
    const state = host.state();
    const depth = undoDepth(state);
    const top = this.done.at(-1);
    if (!top || top.exitDepth !== depth || !(state.doc === top.exitDoc || state.doc.eq(top.exitDoc))) {
      host.undo();
      return;
    }

    const redoEntry = redoDepth(state);
    for (let count = top.exitDepth - top.entryDepth; count > 0; count--) {
      if (!host.undo()) break;
    }
    this.done.pop();
    const after = host.state();
    this.undone.push({ redoEntry, redoExit: redoDepth(after), doc: after.doc, unit: top });
  }

  redo(host: Pick<VimHost, 'state' | 'redo'>): void {
    const state = host.state();
    const depth = redoDepth(state);
    const top = this.undone.at(-1);
    if (!top || top.redoExit !== depth || !(state.doc === top.doc || state.doc.eq(top.doc))) {
      host.redo();
      return;
    }

    for (let count = top.redoExit - top.redoEntry; count > 0; count--) {
      if (!host.redo()) break;
    }
    this.undone.pop();
    const after = host.state();
    this.done.push({ ...top.unit, exitDepth: undoDepth(after), exitDoc: after.doc });
  }

  noteChange(fromHistory: boolean): void {
    if (!fromHistory) this.undone = [];
  }

  clear(): void {
    this.done = [];
    this.undone = [];
  }
}
