import type { RecordToken, VimMode, VimUpdate } from './types';
import { editToken } from './record';

export interface SessionHost {
  state(): { selection: { main: { head: number } } };
  dispatch(spec: { selection?: unknown; annotations?: unknown; userEvent?: string }): void;
}

export class InsertSession {
  mode: 'insert' | 'replace' | null = null;
  count = 1;
  entryDepth = 0;
  lastHead = 0;
  recordsDot = true;
  private edits: RecordToken[] = [];
  private overwritten: string[] = [];

  start(mode: 'insert' | 'replace', count: number, depth: number, cursor: number, recordsDot = true): void {
    this.mode = mode;
    this.count = Math.max(1, count);
    this.entryDepth = depth;
    this.lastHead = cursor;
    this.recordsDot = recordsDot;
    this.edits = [];
    this.overwritten = [];
  }

  track(update: VimUpdate): RecordToken | null {
    const token = editToken(update, this.lastHead);
    this.lastHead = update.state.selection.main.head;
    if (token) this.edits.push(token);
    return token;
  }

  recordToken(token: RecordToken): void { this.edits.push({ ...token }); }
  rebaseHead(head: number): void { this.lastHead = head; }

  tokens(): readonly RecordToken[] { return this.edits.map((token) => ({ ...token })); }
  popOverwrite(): string | null { return this.overwritten.pop() ?? null; }
  pushOverwrite(value: string): void { this.overwritten.push(value); }
  get overwriteDepth(): number { return this.overwritten.length; }
  clear(): void { this.mode = null; this.count = 1; this.recordsDot = true; this.edits = []; this.overwritten = []; }
}

export function isTextEvent(update: VimUpdate): boolean {
  return update.userEvent?.startsWith('input.type') === true || update.userEvent?.startsWith('delete') === true || update.userEvent === 'input.paste' || update.userEvent === 'input.complete';
}

export function modeAllowsText(mode: VimMode): boolean {
  return mode === 'insert' || mode === 'replace';
}
