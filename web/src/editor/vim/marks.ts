import type { ChangeSet, Text } from '@codemirror/state';

export function isMarkName(ch: string): boolean {
  return /^[a-z]$/.test(ch);
}

export class MarkTable {
  private marks = new Map<string, number>();
  private contextMark: number | null = null;

  set(name: string, pos: number): void {
    this.marks.set(name, pos);
  }

  get(name: string): number | null {
    return this.marks.get(name) ?? null;
  }

  setContext(pos: number): void {
    this.contextMark = pos;
  }

  context(): number | null {
    return this.contextMark;
  }

  map(changes: ChangeSet): void {
    for (const [name, pos] of this.marks) this.marks.set(name, changes.mapPos(pos, -1));
    if (this.contextMark !== null) this.contextMark = changes.mapPos(this.contextMark, -1);
  }
}

export class ChangeList {
  private positions: number[] = [];
  private index = 0;

  record(changes: ChangeSet, docAfter: Text): void {
    if (!changes.empty) {
      this.positions = this.positions.map((pos) => changes.mapPos(pos, -1));
      let start: number | null = null;
      changes.iterChanges((_fromA, _toA, fromB) => { if (start === null) start = fromB; });
      if (start !== null) {
        const line = docAfter.lineAt(start).number;
        const newest = this.positions[this.positions.length - 1];
        if (newest !== undefined && docAfter.lineAt(newest).number === line) this.positions[this.positions.length - 1] = start;
        else this.positions.push(start);
        if (this.positions.length > 100) this.positions.shift();
      }
    }
    this.index = this.positions.length;
  }

  step(direction: -1 | 1, count: number): number | { error: string } {
    if (!this.positions.length) return { error: 'E664 changelist is empty' };
    for (let n = 0; n < Math.max(1, Math.floor(count)); n++) {
      const next = this.index + direction;
      if (next < 0) return { error: 'E662 At start of changelist' };
      if (next >= this.positions.length) return { error: 'E663 At end of changelist' };
      this.index = next;
    }
    return this.positions[this.index]!;
  }

  clear(): void { this.positions = []; this.index = 0; }
}
