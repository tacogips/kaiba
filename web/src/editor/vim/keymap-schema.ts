import { ACTION_MODES, isActionId, isHopAction, type ActionId } from './actions';
import { parseNotation } from './notation';
import type { VimKey } from './types';

// The keymap is stored inside the "web" app setting, which the server caps at 64KB.
export const KEYMAP_MAX_BYTES = 40_960;
export const KEYMAP_MAX_ENTRIES = 1_000;
export const DEFAULT_HOP_KEYS = 'fdjhklsagqwertyuiopzxcvbnm';
export type MapMode = 'n' | 'i' | 'x' | 'o' | 'c';
export type RhsSegment = { kind: 'keys'; keys: readonly VimKey[] } | { kind: 'ex'; command: string } | { kind: 'prompt' };
export type MapTarget = { kind: 'keys'; segments: readonly RhsSegment[]; remap: boolean } | { kind: 'nop' } | { kind: 'action'; id: ActionId };
export interface CompiledMapping { mode: 'n' | 'i' | 'x' | 'o'; lhs: readonly VimKey[]; target: MapTarget; desc: string | null; path: string }
export interface CompiledKeymap {
  leader: VimKey;
  timeoutlen: number;
  maps: Readonly<Record<'n' | 'i' | 'x' | 'o', readonly CompiledMapping[]>>;
  cmdline: ReadonlyMap<VimKey, VimKey>;
  hints: { enabled: boolean; delayMs: number; triggers: Readonly<Record<'n' | 'x' | 'o', readonly (readonly VimKey[])[]>> };
  hop: { enabled: boolean; keys: string; uppercaseLabels: boolean };
}
export interface KeymapIssue { path: string; severity: 'error' | 'warning'; message: string }

type JsonObject = Record<string, unknown>;
const object = (value: unknown): value is JsonObject => value !== null && typeof value === 'object' && !Array.isArray(value);
// eslint-disable-next-line no-control-regex
const printable = (key: string): boolean => Array.from(key).length > 0 && !/[\u0000-\u001f\u007f]/u.test(key) && key !== '<Other>';
const isPrintableKey = (key: VimKey): boolean => !key.startsWith('<') && printable(key);
const knownTop = new Set(['version', 'leader', 'timeoutlen', 'maps', 'hints', 'hop', 'unsupported']);
const knownEntry = new Set(['lhs', 'rhs', 'action', 'remap', 'desc']);
const knownHint = new Set(['enabled', 'delayMs', 'triggers']);
const knownHop = new Set(['enabled', 'keys', 'uppercaseLabels']);
const mapModes = ['n', 'i', 'x', 'v', 'o', 'c'] as const;
const forbidden = new Set(['<C-a>', '<C-z>', '<C-y>', '<C-c>', '<C-x>', '<C-v>']);
const cmdKeys = new Set(['<Esc>', '<CR>', '<Home>', '<End>', '<Left>', '<Right>', '<BS>', '<Del>']);

export function compileKeymap(text: string): { keymap: CompiledKeymap | null; issues: KeymapIssue[] } {
  const issues: KeymapIssue[] = [];
  const add = (path: string, severity: 'error' | 'warning', message: string) => issues.push({ path, severity, message });
  const fail = (path: string, message: string) => add(path, 'error', message);
  try {
    if (typeof text !== 'string') return { keymap: null, issues: [{ path: '$', severity: 'error', message: 'keymap must be JSON text' }] };
    if (new TextEncoder().encode(text).length > KEYMAP_MAX_BYTES) return { keymap: null, issues: [{ path: '$', severity: 'error', message: `keymap exceeds ${KEYMAP_MAX_BYTES} UTF-8 bytes` }] };
    let parsed: unknown;
    try { parsed = JSON.parse(text); } catch { return { keymap: null, issues: [{ path: '$', severity: 'error', message: 'invalid JSON' }] }; }
    if (!object(parsed)) return { keymap: null, issues: [{ path: '$', severity: 'error', message: 'keymap root must be an object' }] };
    if (!Number.isInteger(parsed.version) || parsed.version !== 1) return { keymap: null, issues: [{ path: 'version', severity: 'error', message: 'version must be the integer 1' }] };
    for (const key of Object.keys(parsed)) if (!knownTop.has(key)) add(key, 'warning', `unknown field ${key} is ignored`);

    let leader: VimKey = '\\';
    if (parsed.leader !== undefined) {
      const result = typeof parsed.leader === 'string' ? parseNotation(parsed.leader, null) : { error: 'leader must be notation text' };
      if ('error' in result || result.keys.length !== 1) fail('leader', 'leader must parse to exactly one key');
      else leader = result.keys[0]!;
    }
    let timeoutlen = 1000;
    if (parsed.timeoutlen !== undefined) {
      if (Number.isInteger(parsed.timeoutlen) && (parsed.timeoutlen as number) >= 50 && (parsed.timeoutlen as number) <= 10_000) timeoutlen = parsed.timeoutlen as number;
      else fail('timeoutlen', 'timeoutlen must be an integer from 50 to 10000');
    }

    let hintsEnabled = false;
    let delayMs = 200;
    const triggerLists: Record<'n' | 'x' | 'o', (readonly VimKey[])[]> = { n: [], x: [], o: [] };
    if (parsed.hints !== undefined) {
      if (!object(parsed.hints)) fail('hints', 'hints must be an object');
      else {
        const hints = parsed.hints;
        for (const key of Object.keys(hints)) if (!knownHint.has(key)) add(`hints.${key}`, 'warning', `unknown field ${key} is ignored`);
        if (hints.enabled !== undefined) {
          if (typeof hints.enabled === 'boolean') hintsEnabled = hints.enabled;
          else fail('hints.enabled', 'enabled must be a boolean');
        }
        if (hints.delayMs !== undefined) {
          if (Number.isInteger(hints.delayMs) && (hints.delayMs as number) >= 0 && (hints.delayMs as number) <= 5000) delayMs = hints.delayMs as number;
          else fail('hints.delayMs', 'delayMs must be an integer from 0 to 5000');
        }
        if (hints.triggers !== undefined) {
          if (!object(hints.triggers)) fail('hints.triggers', 'triggers must be an object');
          else {
            for (const key of Object.keys(hints.triggers)) {
              if (!['n', 'x', 'v', 'o'].includes(key)) { add(`hints.triggers.${key}`, 'warning', `unknown trigger mode ${key} is ignored`); continue; }
              const mode = key === 'v' ? 'x' : key as 'n' | 'x' | 'o';
              const items = hints.triggers[key];
              if (!Array.isArray(items)) { fail(`hints.triggers.${key}`, 'triggers for a mode must be an array'); continue; }
              if (items.length > 32) fail(`hints.triggers.${key}`, 'at most 32 triggers are allowed');
              items.slice(0, 32).forEach((item, index) => {
                const path = `hints.triggers.${key}[${index}]`;
                if (typeof item !== 'string') { fail(path, 'trigger must be a notation string'); return; }
                const result = parseNotation(item, leader);
                if ('error' in result || result.keys.length === 0) { fail(path, 'trigger must parse to at least one key'); return; }
                triggerLists[mode].push(result.keys);
              });
            }
          }
        }
      }
    }

    let hopEnabled = false;
    let hopKeys = DEFAULT_HOP_KEYS;
    let uppercaseLabels = false;
    if (parsed.hop !== undefined) {
      if (!object(parsed.hop)) fail('hop', 'hop must be an object');
      else {
        const hop = parsed.hop;
        for (const key of Object.keys(hop)) if (!knownHop.has(key)) add(`hop.${key}`, 'warning', `unknown field ${key} is ignored`);
        if (hop.enabled !== undefined) {
          if (typeof hop.enabled === 'boolean') hopEnabled = hop.enabled;
          else fail('hop.enabled', 'enabled must be a boolean');
        }
        if (hop.uppercaseLabels !== undefined) {
          if (typeof hop.uppercaseLabels === 'boolean') uppercaseLabels = hop.uppercaseLabels;
          else fail('hop.uppercaseLabels', 'uppercaseLabels must be a boolean');
        }
        if (hop.keys !== undefined) {
          const candidate = hop.keys;
          const chars = typeof candidate === 'string' ? Array.from(candidate) : [];
          const normalized = uppercaseLabels ? chars.map((char) => char.toLowerCase()) : chars;
          if (typeof candidate === 'string' && chars.length >= 2 && chars.length <= 64 && chars.every((char) => /^[\x21-\x7e]$/.test(char))
            && new Set(normalized).size === chars.length) hopKeys = candidate;
          else fail('hop.keys', `hop.keys must contain 2 to 64 unique printable ASCII characters without spaces${uppercaseLabels ? ' (case-insensitive)' : ''}`);
        }
      }
    }
    if (parsed.unsupported !== undefined && (!Array.isArray(parsed.unsupported) || parsed.unsupported.some((item) => !object(item))))
      add('unsupported', 'warning', 'unsupported must be an array of objects; it is ignored');

    const compiled: Record<'n' | 'i' | 'x' | 'o', CompiledMapping[]> = { n: [], i: [], x: [], o: [] };
    const cmdline = new Map<VimKey, VimKey>();
    const maps = parsed.maps;
    if (maps !== undefined && !object(maps)) fail('maps', 'maps must be an object');
    let total = 0;
    if (object(maps)) {
      for (const modeKey of Object.keys(maps)) {
        if (!(mapModes as readonly string[]).includes(modeKey)) { add(`maps.${modeKey}`, 'warning', `unknown mode ${modeKey} is ignored`); continue; }
        const value = maps[modeKey];
        if (!Array.isArray(value)) { fail(`maps.${modeKey}`, 'mode mappings must be an array'); continue; }
        const mode = modeKey === 'v' ? 'x' : modeKey as MapMode;
        for (let index = 0; index < value.length; index++) {
          const path = `maps.${modeKey}[${index}]`;
          if (total >= KEYMAP_MAX_ENTRIES) { if (total === KEYMAP_MAX_ENTRIES) fail('maps', `entries after ${KEYMAP_MAX_ENTRIES} are skipped`); total++; continue; }
          total++;
          const raw = value[index];
          if (!object(raw)) { fail(path, 'mapping entry must be an object'); continue; }
          for (const key of Object.keys(raw)) if (!knownEntry.has(key)) add(`${path}.${key}`, 'warning', `unknown field ${key} is ignored`);
          const hasRhs = Object.prototype.hasOwnProperty.call(raw, 'rhs');
          const hasAction = Object.prototype.hasOwnProperty.call(raw, 'action');
          if (hasRhs === hasAction) { fail(path, 'exactly one of rhs and action is required'); continue; }
          if (typeof raw.lhs !== 'string') { fail(`${path}.lhs`, 'lhs must be notation text'); continue; }
          const lhsResult = parseNotation(raw.lhs, leader);
          if ('error' in lhsResult || lhsResult.keys.length < 1 || lhsResult.keys.length > 16) { fail(`${path}.lhs`, 'lhs must parse to 1 to 16 keys'); continue; }
          if (forbidden.has(lhsResult.keys[0]!) && (mode !== 'c' || ['<C-c>', '<C-x>', '<C-v>'].includes(lhsResult.keys[0]!))) {
            fail(`${path}.lhs`, 'reserved for a platform or live-coding shortcut'); continue;
          }
          // eslint-disable-next-line no-control-regex
          if (raw.desc !== undefined && (typeof raw.desc !== 'string' || raw.desc.length > 80 || /[\u0000-\u001f\u007f]/u.test(raw.desc))) {
            fail(`${path}.desc`, 'desc must be at most 80 characters without control characters'); continue;
          }
          const desc = typeof raw.desc === 'string' ? raw.desc : null;
          if (mode === 'c') {
            if (lhsResult.keys.length !== 1) { fail(`${path}.lhs`, 'c-mode lhs must contain exactly one key'); continue; }
            if (!hasRhs) { fail(`${path}.action`, 'actions are not supported in c mode'); continue; }
            if (raw.remap !== undefined) { fail(`${path}.remap`, 'remap is not supported in c mode'); continue; }
            if (typeof raw.rhs !== 'string') { fail(`${path}.rhs`, 'rhs must be notation text'); continue; }
            const rhs = parseNotation(raw.rhs, leader);
            if ('error' in rhs || rhs.keys.length !== 1 || !(cmdKeys.has(rhs.keys[0]!) || isPrintableKey(rhs.keys[0]!))) {
              fail(`${path}.rhs`, 'c-mode rhs must be one allowed key'); continue;
            }
            cmdline.set(lhsResult.keys[0]!, rhs.keys[0]!);
            continue;
          }
          if (hasAction) {
            if (raw.remap !== undefined) { fail(`${path}.remap`, 'remap is only valid with a key-sequence rhs'); continue; }
            if (typeof raw.action !== 'string' || !isActionId(raw.action)) { fail(`${path}.action`, `unknown action id ${String(raw.action)}`); continue; }
            if (!ACTION_MODES[raw.action].includes(mode)) { fail(`${path}.action`, `action ${raw.action} is not allowed in mode ${mode}`); continue; }
            if (isHopAction(raw.action) && !hopEnabled) continue;
            const entry: CompiledMapping = { mode, lhs: lhsResult.keys, target: { kind: 'action', id: raw.action }, desc, path };
            replaceMapping(compiled[mode], entry);
            continue;
          }
          if (typeof raw.rhs !== 'string') { fail(`${path}.rhs`, 'rhs must be notation text'); continue; }
          if (raw.remap !== undefined && typeof raw.remap !== 'boolean') { fail(`${path}.remap`, 'remap must be a boolean'); continue; }
          const remap = raw.remap === true;
          if (raw.rhs === '<Nop>') {
            if (raw.remap !== undefined) { fail(`${path}.remap`, 'remap is not valid with <Nop>'); continue; }
            replaceMapping(compiled[mode], { mode, lhs: lhsResult.keys, target: { kind: 'nop' }, desc, path });
            continue;
          }
          const rhs = parseNotation(raw.rhs, leader);
          if ('error' in rhs || rhs.keys.length < 1 || rhs.keys.length > 256) { fail(`${path}.rhs`, 'rhs must parse to 1 to 256 keys'); continue; }
          if (mode === 'i' && rhs.keys.some((key) => !isPrintableKey(key) && !new Set(['<Esc>', '<BS>', '<Del>', '<CR>', '<Tab>', '<Left>', '<Right>', '<Up>', '<Down>', '<Home>', '<End>']).has(key))) {
            fail(`${path}.rhs`, 'insert-mode rhs contains a key that is not allowed'); continue;
          }
          const segments = mode === 'i' ? [{ kind: 'keys' as const, keys: rhs.keys }] : splitEx(rhs.keys, path, fail);
          if (segments === null) continue;
          replaceMapping(compiled[mode], { mode, lhs: lhsResult.keys, target: { kind: 'keys', segments, remap }, desc, path });
        }
      }
    }
    return { keymap: { leader, timeoutlen, maps: compiled, cmdline, hints: { enabled: hintsEnabled, delayMs, triggers: triggerLists }, hop: { enabled: hopEnabled, keys: hopKeys, uppercaseLabels } }, issues };
  } catch (error) {
    const message = error instanceof Error ? error.message : 'invalid keymap';
    return { keymap: null, issues: [{ path: '$', severity: 'error', message: `keymap compilation failed safely: ${message}` }] };
  }
}

function replaceMapping(list: CompiledMapping[], entry: CompiledMapping): void {
  const index = list.findIndex((item) => item.lhs.length === entry.lhs.length && item.lhs.every((key, i) => key === entry.lhs[i]));
  if (index >= 0) list.splice(index, 1);
  list.push(entry);
}

function splitEx(keys: readonly VimKey[], path: string, fail: (path: string, message: string) => void): RhsSegment[] | null {
  const result: RhsSegment[] = [];
  for (let i = 0; i < keys.length;) {
    if (keys[i] !== ':') {
      const start = i++;
      while (i < keys.length && keys[i] !== ':') i++;
      result.push({ kind: 'keys', keys: keys.slice(start, i) });
      continue;
    }
    if (i === keys.length - 1) { result.push({ kind: 'prompt' }); i++; continue; }
    const end = keys.indexOf('<CR>', i + 1);
    if (end < 0) { fail(`${path}.rhs`, 'ex command after : must end with <CR>'); return null; }
    const commandKeys = keys.slice(i + 1, end);
    if (commandKeys.some((key) => !isPrintableKey(key))) { fail(`${path}.rhs`, 'ex command contains a non-printable key'); return null; }
    result.push({ kind: 'ex', command: commandKeys.join('') });
    i = end + 1;
  }
  return result;
}
