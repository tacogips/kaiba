import type { VimKey } from './types';

const named = new Map<string, VimKey>([
  ['space', ' '], ['lt', '<'], ['bar', '|'], ['bslash', '\\'],
  ['cr', '<CR>'], ['enter', '<CR>'], ['return', '<CR>'], ['esc', '<Esc>'], ['c-[', '<Esc>'],
  ['bs', '<BS>'], ['del', '<Del>'], ['tab', '<Tab>'], ['left', '<Left>'], ['right', '<Right>'],
  ['up', '<Up>'], ['down', '<Down>'], ['home', '<Home>'], ['end', '<End>'],
]);

const segmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' });
const graphemes = (text: string): string[] => Array.from(segmenter.segment(text), (part) => part.segment);

function tokenValue(token: string): VimKey | null {
  const lower = token.toLowerCase();
  const alias = named.get(lower);
  if (alias !== undefined) return alias;
  const control = /^c-([a-z])$/i.exec(token);
  return control ? `<C-${control[1]!.toLowerCase()}>` : null;
}

export function parseNotation(text: string, leader: VimKey | null): { keys: VimKey[] } | { error: string } {
  if (typeof text !== 'string') return { error: 'notation must be a string' };
  const keys: VimKey[] = [];
  let noClosingAngle = false;
  for (let i = 0; i < text.length;) {
    if (text[i] !== '<') {
      const nextAngle = text.indexOf('<', i);
      const end = nextAngle < 0 ? text.length : nextAngle;
      const segments = graphemes(text.slice(i, end));
      if (segments.length === 0) return { error: 'invalid notation' };
      for (const segment of segments) keys.push(segment);
      i = end;
      continue;
    }
    if (noClosingAngle) { keys.push('<'); i++; continue; }
    const end = text.indexOf('>', i + 1);
    if (end < 0) { noClosingAngle = true; keys.push('<'); i++; continue; }
    const body = text.slice(i + 1, end);
    if (!body || /\s/.test(body)) { keys.push('<'); i++; continue; }
    const token = text.slice(i, end + 1);
    if (body.toLowerCase() === 'leader') {
      if (leader === null) return { error: '<leader> needs a leader' };
      keys.push(leader);
    } else {
      const value = tokenValue(body);
      if (value === null) return { error: `unsupported notation token ${token}` };
      keys.push(value);
    }
    i = end + 1;
  }
  return { keys };
}

export function formatKey(key: VimKey): string {
  if (key === ' ') return '<Space>';
  if (key === '<') return '<lt>';
  return key;
}

export function formatNotation(keys: readonly VimKey[]): string {
  return keys.map(formatKey).join('');
}
