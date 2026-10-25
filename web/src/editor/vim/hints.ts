import { formatNotation } from './notation';
import type { CompiledKeymap, MapTarget } from './keymap-schema';
import type { HintEntry, HintView, VimKey } from './types';

type HintMode = 'n' | 'x' | 'o';
type Builtin = { key: string; desc: string };

const builtins: Readonly<Record<string, readonly Builtin[]>> = {
  g: [
    { key: 'g', desc: 'first line' }, { key: 'e', desc: 'end of previous word' },
    { key: '~', desc: 'toggle case' }, { key: 'u', desc: 'lowercase' }, { key: 'U', desc: 'uppercase' },
    { key: 'j', desc: 'line down' }, { key: 'k', desc: 'line up' }, { key: 'J', desc: 'join without spaces' },
    { key: ';', desc: 'older change' }, { key: ',', desc: 'newer change' },
  ],
  z: [{ key: 'z', desc: 'center line' }],
  m: [{ key: 'a-z', desc: 'set mark' }],
};

export function buildHints(keymap: CompiledKeymap, mode: HintMode, prefix: readonly VimKey[], extended: boolean): HintView {
  const entries = new Map<string, HintEntry>();
  const matching = keymap.maps[mode].filter((mapping) => startsWith(mapping.lhs, prefix) && mapping.lhs.length > prefix.length);
  const nextKeys = new Set(matching.map((mapping) => mapping.lhs[prefix.length]!));

  for (const key of builtinKeys(mode, prefix, extended)) {
    const exact = matching.find((mapping) => mapping.lhs.length === prefix.length + 1 && mapping.lhs[prefix.length] === key);
    if (exact?.target.kind === 'nop') continue;
    const descendants = matching.filter((mapping) => mapping.lhs[prefix.length] === key && mapping.lhs.length > prefix.length + 1);
    if (exact) entries.set(key, { key, desc: mappingDescription(exact.target, exact.desc), group: descendants.length > 0 });
    else entries.set(key, { key, desc: builtinDescription(mode, prefix, key, extended), group: descendants.length > 0 });
  }

  for (const key of nextKeys) {
    const mappings = matching.filter((mapping) => mapping.lhs[prefix.length] === key);
    const exact = mappings.find((mapping) => mapping.lhs.length === prefix.length + 1);
    const descendants = mappings.filter((mapping) => mapping.lhs.length > prefix.length + 1);
    if (exact?.target.kind === 'nop') {
      if (descendants.length) entries.set(key, { key, desc: `+${descendants.length} keys`, group: true });
      else entries.delete(key);
    } else if (exact) {
      entries.set(key, { key, desc: mappingDescription(exact.target, exact.desc), group: descendants.length > 0 });
    } else if (descendants.length) {
      entries.set(key, { key, desc: `+${descendants.length} keys`, group: true });
    }
  }

  const sorted = [...entries.values()].sort(compareEntries);
  const formattedPrefix = formatNotation(prefix);
  return { prefix: formattedPrefix, entries: sorted, summary: `${formattedPrefix}: ${sorted.length} next keys` };
}

export function isTrigger(keymap: CompiledKeymap, mode: HintMode, pending: readonly VimKey[]): boolean {
  return keymap.hints.enabled && keymap.hints.triggers[mode].some((trigger) => sameKeys(trigger, pending));
}

function builtinKeys(mode: HintMode, prefix: readonly VimKey[], extended: boolean): string[] {
  if (prefix.length !== 1) return [];
  const token = prefix[0];
  if (token === 'g') {
    if (mode === 'o') return extended ? ['g', 'e', 'j', 'k'] : ['g', 'e'];
    return extended ? builtins.g!.map(({ key }) => key) : ['g', 'e', '~', 'u', 'U'];
  }
  if (token === 'z' && mode !== 'o' && extended) return ['z'];
  if (token === 'm' && mode === 'n') return ['a-z'];
  return [];
}

function builtinDescription(mode: HintMode, prefix: readonly VimKey[], key: string, extended: boolean): string {
  if (prefix[0] === 'g' && (mode === 'o' || !extended) && (key === 'j' || key === 'k')) return key === 'j' ? 'line down' : 'line up';
  return builtins[prefix[0]!]?.find((entry) => entry.key === key)?.desc ?? 'set mark';
}

function mappingDescription(target: MapTarget, desc: string | null): string {
  if (desc) return desc;
  if (target.kind === 'action') return target.id;
  if (target.kind === 'nop') return '<Nop>';
  return target.segments.map((segment) => segment.kind === 'keys'
    ? formatNotation(segment.keys)
    : segment.kind === 'ex' ? `:${segment.command}<CR>` : ':').join('');
}

function startsWith(keys: readonly VimKey[], prefix: readonly VimKey[]): boolean {
  return keys.length >= prefix.length && prefix.every((key, index) => keys[index] === key);
}

function sameKeys(left: readonly VimKey[], right: readonly VimKey[]): boolean {
  return left.length === right.length && left.every((key, index) => key === right[index]);
}

function compareEntries(left: HintEntry, right: HintEntry): number {
  const classDiff = keyClass(left.key) - keyClass(right.key);
  if (classDiff !== 0) return classDiff;
  const keyDiff = compareCodePoint(sortKey(left.key), sortKey(right.key));
  return keyDiff || Number(left.group) - Number(right.group) || compareCodePoint(left.key, right.key);
}

function keyClass(key: string): number {
  if (key === 'a-z') return 0;
  if (/^[a-z]$/u.test(key)) return 0;
  if (/^[A-Z]$/u.test(key)) return 1;
  if (/^[0-9]$/u.test(key)) return 2;
  if (key.startsWith('<') || key === ' ') return 4;
  return 3;
}

function sortKey(key: string): string { return key === 'a-z' ? 'a' : key; }

function compareCodePoint(left: string, right: string): number {
  const a = Array.from(left, (char) => char.codePointAt(0) ?? 0);
  const b = Array.from(right, (char) => char.codePointAt(0) ?? 0);
  for (let index = 0; index < Math.min(a.length, b.length); index++) if (a[index] !== b[index]) return a[index]! - b[index]!;
  return a.length - b.length;
}
