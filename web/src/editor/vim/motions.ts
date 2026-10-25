import type { Text } from '@codemirror/state';
import { SCAN_LIMIT, type MotionContext, type MotionKind, type MotionResult, type MotionSpec } from './types';
import { charClass, classAt, clampNormal, firstNonBlank, graphemeColumn, nextGrapheme, posAtColumn, prevGrapheme } from './words';

const empty = (doc: Text, pos: number, kind: MotionKind): MotionResult => ({ pos, linewise: false, inclusive: false, desiredColumn: null, jump: kind === 'gg' || kind === 'G' || kind === '{' || kind === '}' || kind === '%' });
const clampLine = (doc: Text, line: number): number => Math.max(1, Math.min(doc.lines, line));
const linePos = (doc: Text, line: number, col: number): number => posAtColumn(doc, line, col);
const sameLineStep = (doc: Text, pos: number, forward: boolean): number => {
  const line = doc.lineAt(pos);
  if (forward) return pos >= line.to ? line.to : Math.min(nextGrapheme(doc, pos), line.to);
  return pos <= line.from ? line.from : Math.max(prevGrapheme(doc, pos), line.from);
};
const stepClass = (doc: Text, pos: number): string => {
  const line = doc.lineAt(pos);
  if (!line.length) return 'empty';
  if (pos === line.to) return '0';
  return String(classAt(line.text, Math.max(0, Math.min(pos - line.from, line.length - 1))));
};
const isBlank = (doc: Text, pos: number): boolean => {
  const line = doc.lineAt(pos);
  return pos === line.to || charClass(String.fromCodePoint(line.text.codePointAt(pos - line.from) ?? 32)) === 0;
};
function wordMove(doc: Text, start: number, kind: 'w' | 'b' | 'e' | 'ge' | 'W' | 'B' | 'E', count: number): number {
  let pos = start;
  const forward = kind === 'w' || kind === 'e' || kind === 'W' || kind === 'E';
  const endKind = kind === 'e' || kind === 'E';
  const big = kind === 'W' || kind === 'B' || kind === 'E';
  const cls = (p: number): string => {
    if (p >= doc.length) return 'end';
    if (big) return isBlank(doc, p) ? '0' : '1';
    const value = stepClass(doc, p);
    return (endKind || kind === 'ge') && value === 'empty' ? '0' : value;
  };
  for (let n = 0; n < count; n++) {
    const before = pos;
    if (forward && !endKind) {
      if (pos >= doc.length) break;
      const initial = cls(pos);
      do { pos = nextGrapheme(doc, pos); } while (pos < doc.length && cls(pos) === initial);
      while (pos < doc.length && cls(pos) === '0') pos = nextGrapheme(doc, pos);
    } else if (forward) {
      if (pos >= doc.length) break;
      pos = nextGrapheme(doc, pos);
      while (pos < doc.length && cls(pos) === '0') pos = nextGrapheme(doc, pos);
      if (pos < doc.length) {
        const initial = cls(pos);
        for (;;) {
          const next = nextGrapheme(doc, pos);
          if (next >= doc.length || next === pos || cls(next) !== initial) break;
          pos = next;
        }
      }
    } else if (kind === 'ge') {
      if (pos <= 0) break;
      if (pos >= doc.length) {
        pos = prevGrapheme(doc, pos);
      } else {
        const current = cls(pos);
        if (current !== '0') {
          while (pos > 0) {
            const prev = prevGrapheme(doc, pos);
            if (prev === pos || cls(prev) !== current) break;
            pos = prev;
          }
        }
        pos = prevGrapheme(doc, pos);
      }
      while (pos > 0 && cls(pos) === '0') pos = prevGrapheme(doc, pos);
    } else {
      if (pos <= 0) break;
      const prior = prevGrapheme(doc, pos);
      if (cls(pos) !== '0' && cls(prior) === cls(pos)) pos = prior;
      else { pos = prior; while (pos > 0 && cls(pos) === '0') pos = prevGrapheme(doc, pos); }
      while (pos > 0 && cls(pos) === '0') pos = prevGrapheme(doc, pos);
      if (pos > 0) {
        const initial = cls(pos);
        while (pos > 0) {
          const prev = prevGrapheme(doc, pos);
          if (prev === pos || cls(prev) !== initial) break;
          pos = prev;
        }
      }
    }
    if (pos === before) break;
  }
  return pos;
}
function findTarget(doc: Text, pos: number, kind: 'f' | 'F' | 't' | 'T', target: string): number | null {
  if (!target) return null;
  const line = doc.lineAt(pos);
  const forward = kind === 'f' || kind === 't';
  if (forward) {
    let at = pos;
    while (at < line.to) {
      at = nextGrapheme(doc, at);
      if (doc.sliceString(at, nextGrapheme(doc, at)) === target) return kind === 't' ? prevGrapheme(doc, at) : at;
    }
  } else {
    let at = pos;
    while (at > line.from) {
      at = prevGrapheme(doc, at);
      if (doc.sliceString(at, nextGrapheme(doc, at)) === target) return kind === 'T' ? nextGrapheme(doc, at) : at;
    }
  }
  return null;
}
function bracketMatch(doc: Text, pos: number): number | null {
  const pairs: Record<string, string> = { '(': ')', '[': ']', '{': '}' };
  const closes: Record<string, string> = { ')': '(', ']': '[', '}': '{' };
  const text = doc.toString();
  const line = doc.lineAt(pos);
  let at = pos;
  let scanned = 0;
  let found = false;
  while (at <= line.to && scanned < SCAN_LIMIT) {
    const ch = text[at]!;
    if (pairs[ch] || closes[ch]) { found = true; break; }
    if (at === line.to) return null;
    at++;
    scanned++;
  }
  if (!found) return null;
  const token = text[at] ?? '';
  const open = !!pairs[token];
  const match = open ? pairs[token] : closes[token];
  if (!match) return null;
  const step = open ? 1 : -1;
  let depth = 0;
  for (let cursor = at, scanned = 0; cursor >= 0 && cursor < text.length && scanned <= SCAN_LIMIT; cursor += step, scanned++) {
    const ch = text[cursor];
    if (ch === token) depth++;
    else if (ch === match && --depth === 0) return cursor;
  }
  return null;
}
function paragraph(doc: Text, pos: number, forward: boolean, count: number): number | null {
  let lineNo = doc.lineAt(pos).number;
  let cursor = pos;
  for (let n = 0; n < count; n++) {
    const initial = lineNo;
    let scanned = 0;
    if (forward) {
      lineNo++;
      let foundBoundary = false;
      while (lineNo <= doc.lines && scanned < SCAN_LIMIT) {
        const line = doc.line(lineNo);
        const lineWidth = line.length + (lineNo < doc.lines ? 1 : 0);
        if (scanned + lineWidth > SCAN_LIMIT) return null;
        scanned += lineWidth;
        cursor = line.from;
        if (!line.text.trim()) { foundBoundary = true; break; }
        lineNo++;
      }
      if (!foundBoundary && lineNo <= doc.lines && scanned >= SCAN_LIMIT) return null;
      if (lineNo > doc.lines) cursor = doc.length;
    } else {
      lineNo--;
      let foundBoundary = false;
      while (lineNo >= 1 && scanned < SCAN_LIMIT) {
        const line = doc.line(lineNo);
        const lineWidth = line.length + (lineNo < doc.lines ? 1 : 0);
        if (scanned + lineWidth > SCAN_LIMIT) return null;
        scanned += lineWidth;
        cursor = line.from;
        if (!line.text.trim()) { foundBoundary = true; break; }
        lineNo--;
      }
      if (!foundBoundary && lineNo >= 1 && scanned >= SCAN_LIMIT) return null;
      if (lineNo < 1) cursor = 0;
    }
    if (lineNo === initial) break;
  }
  return cursor;
}
function vertical(doc: Text, pos: number, lineDelta: number, ctx: MotionContext, _kind: MotionKind): MotionResult {
  const fromLine = doc.lineAt(pos).number;
  const toLine = clampLine(doc, fromLine + lineDelta);
  const column = ctx.desiredColumn == null ? graphemeColumn(doc, pos) : ctx.desiredColumn;
  return { pos: linePos(doc, toLine, column), linewise: true, inclusive: false, desiredColumn: column, jump: false };
}
function runOne(doc: Text, pos: number, spec: MotionSpec, ctx: MotionContext): MotionResult | null {
  const kind = spec.kind;
  const line = doc.lineAt(pos);
  let result = empty(doc, pos, kind);
  switch (kind) {
    case 'h': result.pos = pos; for (let i = 0; i < ctx.count; i++) result.pos = sameLineStep(doc, result.pos, false); break;
    case 'BS': {
      result.pos = pos;
      for (let i = 0; i < ctx.count; i++) {
        const current = doc.lineAt(result.pos);
        result.pos = result.pos <= current.from && current.number > 1
          ? clampNormal(doc, doc.line(current.number - 1).to)
          : sameLineStep(doc, result.pos, false);
      }
      break;
    }
    case 'l': result.pos = pos; for (let i = 0; i < ctx.count; i++) result.pos = clampNormal(doc, sameLineStep(doc, result.pos, true)); break;
    case '0': result.pos = line.from; break;
    case '^': result.pos = firstNonBlank(doc, line.number); break;
    case '$': {
      const target = clampLine(doc, line.number + (ctx.explicitCount ? ctx.count - 1 : 0));
      result.pos = clampNormal(doc, doc.line(target).to); result.inclusive = true; result.desiredColumn = Infinity; break;
    }
    case 'j': case 'k': case '+': {
      const delta = kind === 'j' ? ctx.count : kind === 'k' ? -ctx.count : ctx.count;
      const target = clampLine(doc, line.number + delta);
      if ((kind === 'j' || kind === 'k') && target === line.number) return null;
      if (kind === '+') result.pos = firstNonBlank(doc, target);
      else { const col = ctx.desiredColumn == null ? graphemeColumn(doc, pos) : ctx.desiredColumn; result.pos = linePos(doc, target, col); result.desiredColumn = col; }
      result.linewise = true; break;
    }
    case 'w': case 'b': case 'e': case 'ge': case 'W': case 'B': case 'E': result.pos = wordMove(doc, pos, kind, ctx.count); result.inclusive = kind === 'e' || kind === 'E' || kind === 'ge'; break;
    case 'gg': case 'G': {
      const target = clampLine(doc, kind === 'gg' ? (ctx.explicitCount ? ctx.count : 1) : (ctx.explicitCount ? ctx.count : doc.lines));
      result.pos = firstNonBlank(doc, target); result.linewise = true; result.jump = true; result.desiredColumn = ctx.desiredColumn; break;
    }
    case 'f': case 'F': case 't': case 'T': {
      if (spec.char == null) return null;
      let at = pos;
      for (let i = 0; i < ctx.count; i++) {
        if (i > 0 && (kind === 't' || kind === 'T')) at = sameLineStep(doc, at, kind === 't');
        const next = findTarget(doc, at, kind, spec.char); if (next == null) return null; at = next;
      }
      result.pos = at; result.inclusive = kind === 'f' || kind === 't'; result.lastFind = { kind, char: spec.char }; break;
    }
    case ';': case ',': {
      if (!ctx.lastFind) return null;
      const base = kind === ';' ? ctx.lastFind.kind : ({ f: 'F', F: 'f', t: 'T', T: 't' } as const)[ctx.lastFind.kind];
      let at = pos;
      for (let i = 0; i < ctx.count; i++) {
        if (kind === ';' && (base === 't' || base === 'T')) at = sameLineStep(doc, at, base === 't');
        const next = findTarget(doc, at, base, ctx.lastFind.char); if (next == null) return null; at = next;
      }
      result.pos = at; result.inclusive = base === 'f' || base === 't'; result.lastFind = { kind: base, char: ctx.lastFind.char }; break;
    }
    case '%': { const match = bracketMatch(doc, pos); if (match == null) return null; result.pos = match; result.inclusive = true; result.jump = true; break; }
    case '{': case '}': { const target = paragraph(doc, pos, kind === '}', ctx.count); if (target == null) return null; result.pos = target; result.jump = true; break; }
    case 'H': case 'M': case 'L': {
      const top = clampLine(doc, ctx.viewport.topLine);
      const target = kind === 'H' ? top + ctx.count - 1 : kind === 'L' ? top + Math.max(0, ctx.viewport.rows - ctx.count) : top + Math.floor((ctx.viewport.rows - 1) / 2);
      result.pos = firstNonBlank(doc, clampLine(doc, target)); result.linewise = true; result.jump = true; result.desiredColumn = ctx.desiredColumn; break;
    }
    case 'C-d': case 'C-u': case 'C-f': case 'C-b': {
      const page = kind === 'C-f' || kind === 'C-b';
      const amount = page ? Math.max(1, ctx.viewport.rows - 2) * ctx.count : (ctx.explicitCount ? ctx.count : Math.max(1, Math.floor(ctx.viewport.rows / 2)));
      const direction = kind === 'C-d' || kind === 'C-f' ? 1 : -1;
      result = vertical(doc, pos, amount * direction, ctx, kind); result.scrollLines = amount * direction; break;
    }
    default: return null;
  }
  result.pos = Math.max(0, Math.min(doc.length, result.pos));
  return result;
}
export function runMotion(doc: Text, pos: number, motion: MotionSpec, ctx: MotionContext): MotionResult | null {
  const start = clampNormal(doc, Math.max(0, Math.min(pos, doc.length)));
  const count = Math.max(1, Math.min(Math.floor(ctx.count) || 1, 10_000));
  const result = runOne(doc, start, motion, { ...ctx, count });
  if (result && !['j', 'k', 'C-d', 'C-u', 'C-f', 'C-b', 'gg', 'G', 'H', 'M', 'L'].includes(motion.kind) && motion.kind !== '$' && motion.kind !== '+') result.desiredColumn = null;
  return result;
}
