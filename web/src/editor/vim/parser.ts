import { COUNT_LIMIT, type MotionKind, type MotionSpec, type OperatorKind, type TextObjectKind, type TextObjectSpec, type VimKey, type VimMode } from './types';
export type ActionKind = 'insert' | 'append' | 'insert-line-start' | 'append-line-end' | 'open-below' | 'open-above'
  | 'replace-mode' | 'visual' | 'visual-line' | 'visual-block' | 'visual-swap' | 'put-after' | 'put-before' | 'replace-char'
  | 'block-insert-before' | 'block-insert-after'
  | 'toggle-case' | 'join' | 'join-raw' | 'scroll-center' | 'scroll-line-down' | 'scroll-line-up'
  | 'surround-add' | 'surround-change' | 'surround-delete'
  | 'undo' | 'redo' | 'repeat' | 'record' | 'play' | 'set-mark' | 'prompt' | 'escape';
export type Target =
  | { kind: 'motion'; motion: MotionSpec }
  | { kind: 'textobject'; spec: TextObjectSpec }
  | { kind: 'search'; which: 'n' | 'N' | '*' | '#' }
  | { kind: 'mark'; name: string; exact: boolean }
  | { kind: 'position'; pos: number; inclusive: boolean }
  | { kind: 'line' };
export interface ParsedCommand { register: string | null; count: number | null; operator: OperatorKind | null; target: Target | null; action: ActionKind | null; arg: string | null }
export type ParseResult = { kind: 'pending' } | { kind: 'invalid'; message: string | null } | { kind: 'command'; command: ParsedCommand };
const pending: ParseResult = { kind: 'pending' };
const invalid = (message: string | null = null): ParseResult => ({ kind: 'invalid', message });
const command = (register: string | null, count: number | null, operator: OperatorKind | null, target: Target | null, action: ActionKind | null = null, arg: string | null = null): ParseResult => ({ kind: 'command', command: { register, count, operator, target, action, arg } });
const motions: Record<string, MotionKind> = { h: 'h', l: 'l', j: 'j', k: 'k', '0': '0', '^': '^', '$': '$', w: 'w', b: 'b', e: 'e', W: 'W', B: 'B', E: 'E', G: 'G', '{': '{', '}': '}', '%': '%', H: 'H', M: 'M', L: 'L', ';': ';', ',': ',' };
const aliases: Record<string, MotionKind> = { '<Left>': 'h', '<Right>': 'l', '<Up>': 'k', '<Down>': 'j', '<Home>': '0', '<End>': '$', '<BS>': 'BS', '<CR>': '+', '<C-d>': 'C-d', '<C-u>': 'C-u', '<C-f>': 'C-f', '<C-b>': 'C-b' };
const printable = (key: VimKey): boolean => [...key].length === 1;
const registerName = (key: string): boolean => /^[a-zA-Z0-9_+*"]$/.test(key);
const alpha = (key: string): boolean => /^[a-zA-Z]$/.test(key);
const markName = (key: string): boolean => /^[a-z]$/.test(key);
const textObject: Record<string, TextObjectKind> = { w: 'w', W: 'W', '"': '"', "'": "'", '`': '`', '(': '(', ')': '(', b: '(', '[': '[', ']': '[', '{': '{', '}': '{', B: '{', '<': '<', '>': '<' };
const cap = (n: number): number => Math.min(COUNT_LIMIT, n);
const targetMotion = (kind: MotionKind, char?: string): Target => ({ kind: 'motion', motion: char === undefined ? { kind } : { kind, char } });

function parseTarget(keys: VimKey[], at: number, extended = false): { target?: Target; used?: number; wait?: boolean; error?: string | null } {
  const key = keys[at];
  if (key === undefined) return { wait: true };
  if (key === 'g' || key === 'i' || key === 'a' || key === 'f' || key === 'F' || key === 't' || key === 'T' || key === "'" || key === '`') {
    const next = keys[at + 1];
    if (next === undefined) return { wait: true };
    if (key === 'g') {
      if (next === 'g') return { target: targetMotion('gg'), used: 2 };
      if (next === 'e') return { target: targetMotion('ge'), used: 2 };
      if (extended && ['j', 'k', ';', ','].includes(next)) return { target: targetMotion(({ j: 'j', k: 'k', ';': 'g;', ',': 'g,' } as const)[next as 'j' | 'k' | ';' | ',']), used: 2 };
      return { error: null };
    }
    if (key === 'i' || key === 'a') {
      const kind = textObject[next];
      return kind ? { target: { kind: 'textobject', spec: { around: key === 'a', kind } }, used: 2 } : { error: null };
    }
    if (key === "'" || key === '`') {
      return /^[a-z]$/.test(next) || next === "'" || next === '`'
        ? { target: { kind: 'mark', name: next, exact: key === '`' }, used: 2 }
        : { error: null };
    }
    return printable(next) ? { target: targetMotion(key as MotionKind, next), used: 2 } : { error: null };
  }
  if (key === 'n' || key === 'N' || key === '*' || key === '#') return { target: { kind: 'search', which: key }, used: 1 };
  const motion = motions[key] ?? aliases[key];
  return motion ? { target: targetMotion(motion), used: 1 } : { error: null };
}

export class CommandParser {
  private keys: VimKey[] = [];
  private extended = false;
  setExtended(on: boolean): void { this.extended = on; }
  feed(key: VimKey, mode: VimMode): ParseResult {
    if (key === '<Esc>') {
      const last = this.keys[this.keys.length - 1];
      const cancelArgument = ['f', 'F', 't', 'T', 'r'].includes(last!);
      this.reset();
      return cancelArgument ? invalid() : command(null, null, null, null, 'escape');
    }
    this.keys.push(key);
    const result = this.parse(mode);
    if (result.kind !== 'pending') this.reset();
    return result;
  }
  reset(): void { this.keys = []; }
  pending(): string { return this.keys.join(''); }
  awaitingArgument(): boolean {
    const k = this.keys;
    if (!k.length) return false;
    let i = 0;
    while (i < k.length && /^[0-9]$/.test(k[i]!)) i++;
    if (k[i] === '"') { if (i + 1 >= k.length) return true; i += 2; }
    while (i < k.length && /^[0-9]$/.test(k[i]!)) i++;
    if (i >= k.length) return false;
    const first = k[i]!, opLength = first === 'g' && ['~', 'u', 'U'].includes(k[i + 1] ?? '') ? 2 : 1;
    const operator = opLength === 2 || ['d', 'c', 'y', '>', '<'].includes(first);
    if (this.extended && first === 'y' && k[i + 1] === 's') {
      let target = i + 2;
      if (/^[1-9]$/.test(k[target] ?? '')) { target++; while (/^[0-9]$/.test(k[target] ?? '')) target++; }
      if (target >= k.length) return false;
      const parsed = parseTarget(k, target, true);
      return parsed.wait === true || parsed.target !== undefined && target + (parsed.used ?? 0) >= k.length;
    }
    if (this.extended && (first === 'c' && k[i + 1] === 's' || first === 'd' && k[i + 1] === 's')) return first === 'c' ? k[i + 3] === undefined : k[i + 2] === undefined;
    if (operator) {
      let target = i + opLength;
      if (opLength === 1 && k[target] === first || opLength === 2 && (k[target] === k[i + 1] || k[target] === 'g' && k[target + 1] === k[i + 1])) return false;
      if (/^[1-9]$/.test(k[target] ?? '')) { target++; while (/^[0-9]$/.test(k[target] ?? '')) target++; }
      if (target >= k.length) return false;
      const key = k[target]!;
      if (key === 'g' || key === 'i' || key === 'a' || ['f', 'F', 't', 'T', "'", '`'].includes(key)) return target + 1 >= k.length;
    }
    if (['f', 'F', 't', 'T', 'r', 'm', 'q', '@', "'", '`', 'g'].includes(first)) return i + 1 >= k.length;
    if (this.extended && first === 'z') return i + 1 >= k.length;
    if (first === 'i' || first === 'a') return i + 1 >= k.length;
    return false;
  }
  pendingOperator(): { register: string | null; count: number | null; operator: OperatorKind } | null {
    const k = this.keys;
    if (!k.length) return null;
    let i = 0, count: number | null = null, register: string | null = null;
    const read = (): number | null => {
      if (!/^[1-9]$/.test(k[i] ?? '')) return null;
      let value = 0; while (/^[0-9]$/.test(k[i] ?? '')) { value = cap(value * 10 + Number(k[i])); i++; } return value;
    };
    count = read(); if (k[i] === '"') { register = k[i + 1] ?? null; if (!register) return null; i += 2; }
    const registerCount = read(); if (registerCount !== null) count = count === null ? registerCount : cap(count * registerCount);
    const first = k[i];
    const operator = first === 'g' && ['~', 'u', 'U'].includes(k[i + 1] ?? '') ? `g${k[i + 1]}` as OperatorKind : first as OperatorKind;
    if (!['d', 'c', 'y', '>', '<', 'g~', 'gu', 'gU'].includes(operator) || this.extended && first === 'y' && k[i + 1] === 's') return null;
    i += operator.startsWith('g') ? 2 : 1;
    const operatorCount = read(); if (operatorCount !== null) count = count === null ? operatorCount : cap(count * operatorCount);
    if (this.awaitingArgument()) return null;
    return { register, count, operator };
  }
  operatorPending(): boolean {
    const k = this.keys;
    let i = 0; while (i < k.length && /^[0-9]$/.test(k[i]!)) i++;
    if (k[i] === '"' || i === 0 && k[0] === '"') i += 2;
    while (i < k.length && /^[0-9]$/.test(k[i]!)) i++;
    const first = k[i]!;
    if (['d', 'c', 'y', '>', '<'].includes(first)) return !(this.extended && first === 'y' && k[i + 1] === 's');
    return first === 'g' && ['~', 'u', 'U'].includes(k[i + 1]!);
  }
  private parse(mode: VimMode): ParseResult {
    const k = this.keys;
    let i = 0;
    let register: string | null = null;
    let prefixCount: number | null = null;
    const readCount = (): number | null => {
      if (k[i] === undefined || !/^[1-9]$/.test(k[i]!)) return null;
      let value = 0;
      while (i < k.length && /^[0-9]$/.test(k[i]!)) { value = Math.min(COUNT_LIMIT, value * 10 + Number(k[i])); i++; }
      return cap(value);
    };
    prefixCount = readCount();
    if (k[i] === '"') {
      if (k[i + 1] === undefined) return pending;
      if (!registerName(k[i + 1]!)) return invalid('E354 Invalid register name');
      register = k[i + 1]!; i += 2;
    }
    const registerCount = readCount();
    if (registerCount !== null) prefixCount = prefixCount === null ? registerCount : cap(prefixCount * registerCount);
    if (i === k.length) return pending;
    const first = k[i]!;
    const visual = mode === 'visual' || mode === 'visual-line' || mode === 'visual-block';
    if (!visual && this.extended && first === 'y' && k[i + 1] === 's') return this.parseSurroundAdd(k, i, register, prefixCount);
    if (!visual && this.extended && first === 'c' && k[i + 1] === 's') return this.parseSurroundChange(k, i, register, prefixCount);
    if (!visual && this.extended && first === 'd' && k[i + 1] === 's') return this.parseSurroundDelete(k, i, register, prefixCount);
    let op: OperatorKind | null = null;
    let opCount: number | null = null;
    let opLength = 1;
    if (first === 'g') {
      if (k[i + 1] === undefined) return pending;
      const second = k[i + 1];
      if (second === '~' || second === 'u' || second === 'U') { op = `g${second}` as OperatorKind; opLength = 2; }
      else if (second === 'g' || second === 'e') {
        if (visual) return command(register, prefixCount, null, targetMotion(second === 'g' ? 'gg' : 'ge'));
        if (second === 'g') return command(register, prefixCount, null, targetMotion('gg'));
        return command(register, prefixCount, null, targetMotion('ge'));
      } else if (this.extended && second === 'J') {
        return command(register, prefixCount, null, null, 'join-raw');
      } else if (this.extended && (second === ';' || second === ',')) {
        return command(register, prefixCount, null, targetMotion(second === ';' ? 'g;' : 'g,'));
      } else if (this.extended && (second === 'j' || second === 'k')) {
        return command(register, prefixCount, null, targetMotion(second));
      } else return invalid();
    } else if (['d', 'c', 'y', '>', '<'].includes(first)) op = first as OperatorKind;

    if (mode === 'visual-block' && (first === 'I' || first === 'A')) return command(register, prefixCount, null, null, first === 'I' ? 'block-insert-before' : 'block-insert-after');
    if (visual) return this.parseVisual(k.slice(i), register, prefixCount, first);
    if (op) {
      i += opLength;
      opCount = readCount();
      if (opLength === 1 && k[i] === first || opLength === 2 && (k[i] === op[1] || k[i] === 'g' && k[i + 1] === op[1])) return command(register, prefixCount === null && opCount === null ? null : cap((prefixCount ?? 1) * (opCount ?? 1)), op, { kind: 'line' });
      if (i === k.length) return pending;
      if (k[i] === '/' || k[i] === '?') return invalid('search prompt cannot follow an operator');
      const parsed = parseTarget(k, i, this.extended);
      if (parsed.wait) return pending;
      if (parsed.error !== undefined) return invalid(parsed.error);
      const count = prefixCount === null && opCount === null ? null : cap((prefixCount ?? 1) * (opCount ?? 1));
      return command(register, count, op, parsed.target ?? null);
    }
    if (first === '0' && prefixCount === null) return command(register, null, null, targetMotion('0'));
    if (prefixCount !== null || /^[1-9]$/.test(first)) {
      // The count was consumed above; continue with the following command key.
      if (i >= k.length) return pending;
    }
    if (first === 'g') return pending;
    if (this.extended && first === 'z') {
      if (k[i + 1] === undefined) return pending;
      return k[i + 1] === 'z' ? command(register, prefixCount, null, null, 'scroll-center') : invalid();
    }
    if (this.extended && first === '<C-e>') return command(register, prefixCount, null, null, 'scroll-line-down');
    if (this.extended && first === '<C-y>') return command(register, prefixCount, null, null, 'scroll-line-up');
    if (first === 'f' || first === 'F' || first === 't' || first === 'T' || first === "'" || first === '`') {
      const parsed = parseTarget(k, i);
      if (parsed.wait) return pending;
      return parsed.error !== undefined ? invalid(parsed.error) : command(register, prefixCount, null, parsed.target ?? null);
    }
    if (first === 'i' || first === 'a') return command(register, prefixCount, null, null, first === 'i' ? 'insert' : 'append');
    if (first === 'x' || first === '<Del>') return command(register, prefixCount, 'd', targetMotion('l'));
    if (first === 'X') return command(register, prefixCount, 'd', targetMotion('h'));
    if (first === 's') return command(register, prefixCount, 'c', targetMotion('l'));
    if (first === 'S') return command(register, prefixCount, 'c', { kind: 'line' });
    if (first === 'D') return command(register, prefixCount, 'd', targetMotion('$'));
    if (first === 'C') return command(register, prefixCount, 'c', targetMotion('$'));
    if (first === 'Y') return command(register, prefixCount, 'y', { kind: 'line' });
    const direct: Record<string, ActionKind> = { I: 'insert-line-start', A: 'append-line-end', o: 'open-below', O: 'open-above', R: 'replace-mode', v: 'visual', V: 'visual-line', '<C-v>': 'visual-block', p: 'put-after', P: 'put-before', '~': 'toggle-case', J: 'join', u: 'undo', '<C-r>': 'redo', '.': 'repeat', ':': 'prompt', '/': 'prompt', '?': 'prompt' };
    if (direct[first]) return command(register, prefixCount, null, null, direct[first], first === ':' || first === '/' || first === '?' ? first : null);
    if (first === 'r' || first === 'q' || first === '@' || first === 'm') {
      if (k[i + 1] === undefined) return pending;
      const arg = k[i + 1]!;
      if (first === 'r') return printable(arg) || arg === '<CR>' ? command(register, prefixCount, null, null, 'replace-char', arg === '<CR>' ? '\n' : arg) : invalid();
      if (first === 'q' && alpha(arg)) return command(register, prefixCount, null, null, 'record', arg);
      if (first === '@' && (markName(arg) || arg === '@')) return command(register, prefixCount, null, null, 'play', arg);
      if (first === 'm' && markName(arg)) return command(register, prefixCount, null, null, 'set-mark', arg);
      return invalid();
    }
    const parsed = parseTarget(k, i, this.extended);
    if (parsed.wait) return pending;
    if (parsed.error !== undefined) return invalid(parsed.error);
    return parsed.target ? command(register, prefixCount, null, parsed.target) : invalid();
  }
  private parseSurroundAdd(keys: VimKey[], at: number, register: string | null, count: number | null): ParseResult {
    let targetAt = at + 2;
    if (keys[targetAt] === '0') return invalid();
    let surroundCount = 0;
    while (/^[0-9]$/.test(keys[targetAt] ?? '')) { surroundCount = cap(surroundCount * 10 + Number(keys[targetAt])); targetAt++; }
    const combinedCount = surroundCount ? cap((count ?? 1) * surroundCount) : count;
    if (keys[targetAt] === undefined) return pending;
    let target: Target, used: number;
    if (keys[targetAt] === 's') { target = { kind: 'line' }; used = 1; }
    else {
      const parsed = parseTarget(keys, targetAt, true);
      if (parsed.wait) return pending;
      if (parsed.error !== undefined || !parsed.target) return invalid(parsed.error ?? null);
      target = parsed.target; used = parsed.used ?? 1;
    }
    const pair = keys[targetAt + used];
    if (pair === undefined) return pending;
    return printable(pair) ? command(register, combinedCount, null, target, 'surround-add', pair) : invalid();
  }
  private parseSurroundChange(keys: VimKey[], at: number, register: string | null, count: number | null): ParseResult {
    const from = keys[at + 2], to = keys[at + 3];
    if (from === undefined || to === undefined) return pending;
    return printable(from) && printable(to) ? command(register, count, null, null, 'surround-change', from + to) : invalid();
  }
  private parseSurroundDelete(keys: VimKey[], at: number, register: string | null, count: number | null): ParseResult {
    const pair = keys[at + 2];
    if (pair === undefined) return pending;
    return printable(pair) ? command(register, count, null, null, 'surround-delete', pair) : invalid();
  }
  private parseVisual(keys: VimKey[], register: string | null, count: number | null, first: string): ParseResult {
    if (keys.length === 0) return pending;
    if (first === 'i' || first === 'a') {
      if (keys[1] === undefined) return pending;
      const kind = textObject[keys[1]];
      return kind ? command(register, count, null, { kind: 'textobject', spec: { around: first === 'a', kind } }) : invalid();
    }
    if (['d', 'x', '<Del>', 'c', 's', 'y', '>', '<', '~'].includes(first)) {
      const op: OperatorKind = first === 'x' || first === '<Del>' ? 'd' : first === 's' ? 'c' : first === '~' ? 'g~' : first as OperatorKind;
      return command(register, count, op, null);
    }
    const lineOps: Record<string, OperatorKind> = { D: 'd', X: 'd', C: 'c', S: 'c', R: 'c', Y: 'y' };
    if (lineOps[first]) return command(register, count, lineOps[first], { kind: 'line' });
    if (first === 'g') {
      if (keys[1] === undefined) return pending;
      if (keys[1] === '~' || keys[1] === 'u' || keys[1] === 'U') return command(register, count, `g${keys[1]}` as OperatorKind, null);
      if (this.extended && keys[1] === 'J') return command(register, count, null, null, 'join-raw');
      if (this.extended && keys[1] === ';') return command(register, count, null, targetMotion('g;'));
      if (this.extended && keys[1] === ',') return command(register, count, null, targetMotion('g,'));
      if (this.extended && (keys[1] === 'j' || keys[1] === 'k')) return command(register, count, null, targetMotion(keys[1]));
    }
    if (this.extended && first === 'z') {
      if (keys[1] === undefined) return pending;
      return keys[1] === 'z' ? command(register, count, null, null, 'scroll-center') : invalid();
    }
    if (this.extended && first === '<C-e>') return command(register, count, null, null, 'scroll-line-down');
    if (this.extended && first === '<C-y>') return command(register, count, null, null, 'scroll-line-up');
    if (first === 'r') {
      if (keys[1] === undefined) return pending;
      return printable(keys[1]) || keys[1] === '<CR>' ? command(register, count, null, null, 'replace-char', keys[1] === '<CR>' ? '\n' : keys[1]) : invalid();
    }
    const visualActions: Record<string, ActionKind> = { J: 'join', p: 'put-after', P: 'put-before', o: 'visual-swap', v: 'visual', V: 'visual-line', '<C-v>': 'visual-block', ':': 'prompt' };
    if (visualActions[first]) return command(register, count, null, null, visualActions[first], first === ':' ? ':' : null);
    const parsed = parseTarget(keys, 0, this.extended);
    if (parsed.wait) return pending;
    return parsed.error !== undefined ? invalid(parsed.error) : command(register, count, null, parsed.target ?? null);
  }
}
