import type { Text } from '@codemirror/state';
import type { HopLabel, HopView, VimKey, VimViewport } from './types';
import { classAt, firstNonBlank, graphemeColumn } from './words';

export type HopKind = 'char1' | 'char1Line' | 'word' | 'line';
export const HOP_TARGET_LIMIT = 4096;

export interface HopSource { doc: Text; cursor: number; viewport: VimViewport; isVisible(pos: number): boolean }
export interface HopSettings { keys: string; uppercaseLabels: boolean }
export type HopStep =
  | { kind: 'pending'; view: HopView | null; prompt: string }
  | { kind: 'jump'; pos: number }
  | { kind: 'cancel'; message: string | null };

const segmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' });

function lineGraphemes(line: string): { segment: string; index: number }[] {
  return Array.from(segmenter.segment(line), ({ segment, index }) => ({ segment, index }));
}

function visibleLineBounds(source: HopSource, kind: HopKind): [number, number] {
  const cursorLine = source.doc.lineAt(source.cursor).number;
  if (kind === 'char1Line') return [cursorLine, cursorLine];
  const top = Math.max(1, Math.min(source.doc.lines, Math.floor(source.viewport.topLine)));
  const rows = Math.max(0, Math.floor(source.viewport.rows));
  return [top, Math.min(source.doc.lines, top + rows - 1)];
}

// Sort keys are computed once per target; recomputing grapheme columns inside the comparator is quadratic on long lines.
function ordered(source: HopSource, positions: Map<number, { line: number; column: number }>): number[] {
  const cursorLine = source.doc.lineAt(source.cursor).number;
  const cursorColumn = graphemeColumn(source.doc, source.cursor);
  return [...positions].map(([pos, { line, column }]) => ({
    pos, lineDistance: Math.abs(line - cursorLine), columnDistance: Math.abs(column - cursorColumn), before: Number(pos < source.cursor),
  })).sort((a, b) => (a.lineDistance - b.lineDistance) || (a.columnDistance - b.columnDistance) || (a.before - b.before))
    .slice(0, HOP_TARGET_LIMIT).map(({ pos }) => pos);
}

function matches(candidate: string, typed: string): boolean {
  return candidate === typed || (/^[a-z]$/.test(typed) && candidate === typed.toUpperCase());
}

export function hopTargets(source: HopSource, kind: HopKind, char: string | null): number[] {
  const [first, last] = visibleLineBounds(source, kind);
  if (last < first) return [];
  const positions = new Map<number, { line: number; column: number }>();
  for (let number = first; number <= last; number++) {
    const line = source.doc.line(number);
    if (kind === 'line') {
      const pos = firstNonBlank(source.doc, number);
      if (pos < line.to && pos !== source.cursor && source.isVisible(pos)) positions.set(pos, { line: number, column: graphemeColumn(source.doc, pos) });
      continue;
    }
    const parts = lineGraphemes(line.text);
    if (kind === 'word') {
      let previousClass = 0;
      for (const [column, part] of parts.entries()) {
        const currentClass = classAt(line.text, part.index);
        const pos = line.from + part.index;
        if (currentClass !== 0 && currentClass !== previousClass && pos !== source.cursor && source.isVisible(pos)) positions.set(pos, { line: number, column });
        previousClass = currentClass;
      }
      continue;
    }
    if (char == null) continue;
    for (const [column, part] of parts.entries()) {
      const pos = line.from + part.index;
      if (matches(part.segment, char) && pos !== source.cursor && source.isVisible(pos)) positions.set(pos, { line: number, column });
    }
  }
  return ordered(source, positions);
}

export function assignLabels(count: number, keys: string): string[] {
  const alphabet = Array.from(keys);
  const targetCount = Math.min(HOP_TARGET_LIMIT, Math.max(0, Math.floor(count)));
  if (targetCount === 0) return [];
  if (alphabet.length < 2 || new Set(alphabet).size !== alphabet.length) throw new Error('hop keys must contain at least two unique characters');
  const labels = alphabet.slice();
  while (labels.length < targetCount) {
    const last = labels.pop();
    if (last == null) break;
    for (const key of alphabet) labels.push(last + key);
  }
  return labels.slice(0, targetCount);
}

function isSingleGrapheme(key: VimKey): boolean {
  if (!key || key.startsWith('<')) return false;
  if (/\p{C}/u.test(key)) return false;
  const parts = lineGraphemes(key);
  return parts.length === 1 && parts[0]!.segment === key;
}

export class HopSession {
  private readonly source: HopSource;
  private readonly settings: HopSettings;
  private waitingForCharacter: boolean;
  private labels: HopLabel[] = [];
  private typedPrefix = '';
  private revision = 0;

  constructor(private readonly kind: HopKind, settings: HopSettings, source: HopSource) {
    this.settings = settings;
    this.source = source;
    this.waitingForCharacter = kind === 'char1' || kind === 'char1Line';
  }

  start(): HopStep {
    if (this.waitingForCharacter) return { kind: 'pending', view: null, prompt: 'hop' };
    return this.buildView(null);
  }

  feed(key: VimKey): HopStep {
    if (key === '<Esc>') return { kind: 'cancel', message: null };
    if (this.waitingForCharacter) {
      if (!isSingleGrapheme(key)) return { kind: 'cancel', message: null };
      this.waitingForCharacter = false;
      return this.buildView(key);
    }
    this.typedPrefix += key;
    const prefix = this.settings.uppercaseLabels ? this.typedPrefix.toLowerCase() : this.typedPrefix;
    const matched = this.labels.filter((label) => {
      const text = this.settings.uppercaseLabels ? label.text.toLowerCase() : label.text;
      return text.startsWith(prefix);
    });
    const complete = matched.filter((label) => {
      const text = this.settings.uppercaseLabels ? label.text.toLowerCase() : label.text;
      return text === prefix;
    });
    if (complete.length === 1) return { kind: 'jump', pos: complete[0]!.pos };
    if (!matched.length) return { kind: 'cancel', message: null };
    this.revision++;
    const view: HopView = {
      revision: this.revision,
      labels: matched.map((label) => {
        const remainder = label.text.slice(this.typedPrefix.length);
        return { pos: label.pos, text: this.settings.uppercaseLabels ? remainder.toUpperCase() : remainder };
      }),
    };
    return { kind: 'pending', view, prompt: `hop: ${matched.length} targets` };
  }

  private buildView(char: string | null): HopStep {
    const targets = hopTargets(this.source, this.kind, char);
    if (!targets.length) return { kind: 'cancel', message: 'hop: no match' };
    const names = assignLabels(targets.length, this.settings.keys);
    this.labels = targets.map((pos, index) => ({ pos, text: this.settings.uppercaseLabels ? names[index]!.toUpperCase() : names[index]! }));
    this.revision++;
    const view: HopView = { labels: this.labels, revision: this.revision };
    return { kind: 'pending', view, prompt: `hop: ${targets.length} targets` };
  }
}
