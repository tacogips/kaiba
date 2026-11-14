import type { MotionKind, RecordToken, VimKey } from './types';
import type { VimUpdate } from './types';

const namedKeys = new Set<VimKey>([
  '<Esc>', '<CR>', '<BS>', '<Del>', '<Tab>', '<Left>', '<Right>', '<Up>', '<Down>', '<Home>', '<End>',
  '<C-r>', '<C-d>', '<C-u>', '<C-f>', '<C-b>', '<Other>',
]);
const moveText: Partial<Record<MotionKind, string>> = {
  h: 'h', j: 'j', k: 'k', l: 'l', '0': '0', '$': '$',
};

export function editToken(update: VimUpdate, cursorBefore: number): RecordToken | null {
  if (!update.docChanged) return null;
  const ranges: { fromA: number; toA: number; fromB: number; toB: number }[] = [];
  update.changes.iterChangedRanges((fromA, toA, fromB, toB) => ranges.push({ fromA, toA, fromB, toB }));
  if (ranges.length !== 1) return null;
  const range = ranges[0]!;
  if (cursorBefore < range.fromA || cursorBefore > range.toA) return null;
  return {
    kind: 'edit',
    deleteBefore: cursorBefore - range.fromA,
    deleteAfter: range.toA - cursorBefore,
    insert: update.state.doc.sliceString(range.fromB, range.toB),
  };
}

export class RedoRecorder {
  private pending: RecordToken[] | null = null;
  private previous: readonly RecordToken[] | null = null;

  begin(first: RecordToken[]): void {
    if (this.pending) this.end();
    this.pending = first.map((token) => ({ ...token }));
  }

  push(token: RecordToken): void {
    this.pending?.push({ ...token });
  }

  end(): void {
    if (!this.pending) return;
    this.previous = this.pending.map((token) => ({ ...token }));
    this.pending = null;
  }

  abort(): void {
    this.pending = null;
  }

  get active(): boolean { return this.pending !== null; }

  last(): readonly RecordToken[] | null {
    return this.previous?.map((token) => ({ ...token })) ?? null;
  }
}

export class MacroRecorder {
  private current: { reg: string; tokens: RecordToken[] } | null = null;

  start(reg: string): void {
    this.current = { reg, tokens: [] };
  }

  push(token: RecordToken): void {
    this.current?.tokens.push({ ...token });
  }

  stop(): { reg: string; tokens: RecordToken[] } | null {
    if (!this.current) return null;
    const result = { reg: this.current.reg, tokens: this.current.tokens.map((token) => ({ ...token })) };
    const last = result.tokens.at(-1);
    if (last?.kind === 'key' && last.key === 'q') result.tokens.pop();
    this.current = null;
    return result;
  }

  get register(): string | null { return this.current?.reg ?? null; }
}

export function tokensToText(tokens: readonly RecordToken[]): string {
  return tokens.map((token) => {
    if (token.kind === 'key') return token.key;
    if (token.kind === 'edit') return '<BS>'.repeat(token.deleteBefore) + '<Del>'.repeat(token.deleteAfter) + token.insert;
    return moveText[token.motion] ?? token.motion;
  }).join('');
}

export function textToTokens(text: string): RecordToken[] {
  const tokens: RecordToken[] = [];
  const segments = new Intl.Segmenter(undefined, { granularity: 'grapheme' });
  for (let index = 0; index < text.length;) {
    if (text[index] === '\r' || text[index] === '\n') {
      if (text[index] === '\r' && text[index + 1] === '\n') index++;
      tokens.push({ kind: 'key', key: '<CR>' });
      index++;
      continue;
    }
    if (text[index] === '<') {
      const close = text.indexOf('>', index + 1);
      if (close >= 0) {
        const candidate = text.slice(index, close + 1);
        if (namedKeys.has(candidate)) {
          tokens.push({ kind: 'key', key: candidate });
          index = close + 1;
          continue;
        }
      }
    }
    const segment = segments.segment(text.slice(index))[Symbol.iterator]().next().value?.segment;
    if (!segment) break;
    tokens.push({ kind: 'key', key: segment });
    index += segment.length;
  }
  return tokens;
}
