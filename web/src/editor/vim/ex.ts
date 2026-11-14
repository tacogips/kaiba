export type ExCommand =
  | { kind: 'empty' }
  | { kind: 'goto'; line: number }
  | { kind: 'substitute'; fromLine: number; toLine: number; pattern: string; replacement: string; global: boolean; ignoreCase: boolean }
  | { kind: 'noh' }
  | { kind: 'action'; actions: readonly ('save' | 'close')[] };

export interface ExContext { currentLine: number; lastLine: number; visual: { fromLine: number; toLine: number } | null }

type Range = { from: number; to: number; end: number };
const invalidRange = 'E16 Invalid range';

function address(source: string, start: number, ctx: ExContext): { value: number; end: number } | null {
  let i = start;
  let base: number;
  if (source[i] === '.') { base = ctx.currentLine; i++; }
  else if (source[i] === '$') { base = ctx.lastLine; i++; }
  else {
    const digits = /^\d+/.exec(source.slice(i));
    if (!digits) return null;
    base = Number(digits[0]);
    i += digits[0].length;
  }
  const offset = /^([+-])(\d*)/.exec(source.slice(i));
  if (offset) {
    const amount = offset[2] ? Number(offset[2]) : 1;
    base += offset[1] === '+' ? amount : -amount;
    i += offset[0].length;
  }
  return { value: base, end: i };
}

function parseRange(source: string, ctx: ExContext): Range | { error: string } | null {
  if (source.startsWith("'<,'>")) {
    if (!ctx.visual) return { error: 'E20 Mark not set' };
    return { from: ctx.visual.fromLine, to: ctx.visual.toLine, end: 5 };
  }
  if (source[0] === '%') return { from: 1, to: ctx.lastLine, end: 1 };
  const first = address(source, 0, ctx);
  if (!first) return null;
  let from = first.value;
  let to = from;
  let end = first.end;
  if (source[end] === ',') {
    const second = address(source, end + 1, ctx);
    if (!second) return { error: invalidRange };
    to = second.value;
    end = second.end;
    if (from > to) [from, to] = [to, from];
  }
  return { from, to, end };
}

function readDelimited(source: string, start: number, delimiter: string): { value: string; end: number; closed: boolean } {
  let value = '';
  let i = start;
  while (i < source.length) {
    if (source[i] === '\\') {
      if (source[i + 1] === delimiter) { value += delimiter; i += 2; continue; }
      if (i + 1 < source.length) { value += source.slice(i, i + 2); i += 2; continue; }
    }
    if (source[i] === delimiter) return { value, end: i + 1, closed: true };
    value += source[i++];
  }
  return { value, end: i, closed: false };
}

function parseSubstitute(source: string, range: Range, ctx: ExContext): ExCommand | { error: string } {
  let i = range.end;
  const command = /^(?:substitute|s)/.exec(source.slice(i));
  if (!command) return { error: `E492 Not an editor command: ${source.slice(i)}` };
  i += command[0].length;
  const delimiter = source[i];
  if (!delimiter || /[\p{L}\p{N}\\"]/u.test(delimiter)) return { error: 'E488 Trailing characters' };
  const patternPart = readDelimited(source, i + 1, delimiter);
  i = patternPart.end;
  let replacement = '';
  if (patternPart.closed && i < source.length) {
    const replacementPart = readDelimited(source, i, delimiter);
    replacement = replacementPart.value;
    i = replacementPart.end;
  }
  const flags = source.slice(i).trim();
  if (/[^gi]/.test(flags) || new Set(flags).size !== flags.length) return { error: 'E488 Trailing characters' };
  const fromLine = range.from;
  const toLine = range.to;
  if (fromLine < 1 || toLine > ctx.lastLine || fromLine > ctx.lastLine) return { error: invalidRange };
  return { kind: 'substitute', fromLine, toLine, pattern: patternPart.value, replacement, global: flags.includes('g'), ignoreCase: flags.includes('i') };
}

export function parseEx(text: string, ctx: ExContext): ExCommand | { error: string } {
  const source = text.trim().replace(/^:/, '').trim();
  if (!source) return { kind: 'empty' };
  const parsedRange = parseRange(source, ctx);
  if (parsedRange && 'error' in parsedRange) return parsedRange;
  const range = parsedRange ?? { from: ctx.currentLine, to: ctx.currentLine, end: 0 };
  const rest = source.slice(range.end).trim();
  if (!rest) return { kind: 'goto', line: Math.max(1, Math.min(range.to, ctx.lastLine)) };
  if (/^(?:substitute|s)(?=$|[^\p{L}\p{N}])/u.test(rest)) {
    const result = parseSubstitute(rest, { ...range, end: 0 }, ctx);
    // parseSubstitute receives the command without its address; retain the computed range.
    if ('kind' in result && result.kind === 'substitute') return { ...result, fromLine: range.from, toLine: range.to };
    return result;
  }
  if (range.end !== 0) return { error: `E492 Not an editor command: ${rest}` };
  if (rest.length >= 3 && 'nohlsearch'.startsWith(rest)) return { kind: 'noh' };
  const actions: Record<string, ExCommand> = {
    w: { kind: 'action', actions: ['save'] },
    'w!': { kind: 'action', actions: ['save'] },
    write: { kind: 'action', actions: ['save'] },
    q: { kind: 'action', actions: ['close'] },
    'q!': { kind: 'action', actions: ['close'] },
    quit: { kind: 'action', actions: ['close'] },
    wq: { kind: 'action', actions: ['save', 'close'] },
    'wq!': { kind: 'action', actions: ['save', 'close'] },
    x: { kind: 'action', actions: ['save', 'close'] },
  };
  return Object.hasOwn(actions, rest) ? actions[rest]! : { error: `E492 Not an editor command: ${rest}` };
}
