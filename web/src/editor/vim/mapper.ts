import { formatNotation } from './notation';
import type { ActionId } from './actions';
import type { CompiledKeymap, CompiledMapping, RhsSegment } from './keymap-schema';
import type { VimKey } from './types';

export interface MapperSink {
  builtin(key: VimKey): void;
  route(key: VimKey): void;
  action(id: ActionId): void;
  ex(command: string): void;
  prompt(): void;
  error(message: string): void;
  changed(): void;
}

export type FeedResult = 'consumed' | 'unmapped';
type Node = { children: Map<VimKey, Node>; mapping: CompiledMapping | null };
type Mode = 'n' | 'i' | 'x' | 'o';
const MAX_REMAP_DEPTH = 100;
const MAX_EMITTED_KEYS = 1_000;

function node(): Node { return { children: new Map(), mapping: null }; }

export class KeyMapper {
  private readonly roots: Record<Mode, Node> = { n: node(), i: node(), x: node(), o: node() };
  private keys: VimKey[] = [];
  private currentMode: Mode | null = null;
  private cancelTimer: (() => void) | null = null;
  private timeoutSuspended = false;
  private replay = false;
  private remapDepth = 0;
  private feedCallDepth = 0;
  private emittedKeys = 0;
  private recursionFailed = false;

  constructor(
    private readonly keymap: CompiledKeymap,
    private readonly timer: (ms: number, cb: () => void) => () => void,
    private readonly sink: MapperSink,
  ) {
    for (const mode of ['n', 'i', 'x', 'o'] as const) {
      for (const mapping of keymap.maps[mode]) {
        let current = this.roots[mode];
        for (const key of mapping.lhs) {
          let next = current.children.get(key);
          if (!next) { next = node(); current.children.set(key, next); }
          current = next;
        }
        current.mapping = mapping;
      }
    }
  }

  feed(key: VimKey, mode: Mode): FeedResult {
    const topLevel = this.feedCallDepth === 0;
    if (topLevel && this.remapDepth === 0) { this.emittedKeys = 0; this.recursionFailed = false; }
    this.feedCallDepth++;
    try {
      if (this.keys.length && this.currentMode !== mode) this.flush();
      if (this.keys.length === 0 && !this.roots[mode].children.has(key)) return 'unmapped';
      if (this.keys.length === 0) this.currentMode = mode;
      this.keys.push(key);
      const found = this.lookup(this.currentMode!, this.keys);
      if (found.node && found.node.mapping && found.node.children.size === 0) {
        const mapping = found.node.mapping;
        const consumed = this.takeBuffer();
        this.run(mapping);
        if (!this.recursionFailed) this.routeAll(consumed.slice(mapping.lhs.length));
        return 'consumed';
      }
      if (found.node) {
        this.startTimer();
        this.sink.changed();
        return 'consumed';
      }
      this.resolve();
      return 'consumed';
    } catch {
      this.cancelPendingTimer();
      this.keys = [];
      this.currentMode = null;
      return 'consumed';
    } finally {
      this.feedCallDepth--;
    }
  }

  flush(): void {
    if (this.keys.length) this.resolve();
  }

  pending(): string { return formatNotation(this.keys); }
  buffer(): readonly VimKey[] { return this.keys.slice(); }
  mode(): Mode | null { return this.currentMode; }

  suspendTimeout(on: boolean): void {
    if (this.timeoutSuspended === on) return;
    this.timeoutSuspended = on;
    if (on) this.cancelPendingTimer();
    else if (this.keys.length) this.startTimer();
  }

  setReplay(on: boolean): void {
    if (this.replay === on) return;
    this.replay = on;
    if (on) this.cancelPendingTimer();
    else if (this.keys.length && !this.timeoutSuspended) this.startTimer();
  }

  private lookup(mode: Mode, keys: readonly VimKey[]): { node: Node | null } {
    let current: Node | undefined = this.roots[mode];
    for (const key of keys) {
      current = current.children.get(key);
      if (!current) return { node: null };
    }
    return { node: current };
  }

  private startTimer(): void {
    this.cancelPendingTimer();
    if (this.timeoutSuspended || this.replay || !this.keys.length) return;
    this.cancelTimer = this.timer(this.keymap.timeoutlen, () => {
      this.cancelTimer = null;
      this.resolve();
    });
  }

  private cancelPendingTimer(): void {
    const cancel = this.cancelTimer;
    this.cancelTimer = null;
    if (cancel) cancel();
  }

  private takeBuffer(): VimKey[] {
    const keys = this.keys;
    this.keys = [];
    this.currentMode = null;
    this.cancelPendingTimer();
    this.sink.changed();
    return keys;
  }

  private resolve(): void {
    if (!this.keys.length || this.recursionFailed) return;
    const mode = this.currentMode!;
    const keys = this.takeBuffer();
    let current = this.roots[mode];
    let match: CompiledMapping | null = null;
    let matchedLength = 0;
    for (let i = 0; i < keys.length; i++) {
      const next = current.children.get(keys[i]!);
      if (!next) break;
      current = next;
      if (current.mapping) { match = current.mapping; matchedLength = i + 1; }
    }
    if (match) {
      this.run(match);
      if (!this.recursionFailed) this.routeAll(keys.slice(matchedLength));
    } else {
      this.sink.builtin(keys[0]!);
      this.routeAll(keys.slice(1));
    }
  }

  private run(mapping: CompiledMapping): void {
    const target = mapping.target;
    if (target.kind === 'nop') return;
    if (target.kind === 'action') { this.sink.action(target.id); return; }
    for (const segment of target.segments) {
      if (this.recursionFailed) return;
      if (segment.kind === 'ex') { this.sink.ex(segment.command); continue; }
      if (segment.kind === 'prompt') { this.sink.prompt(); continue; }
      if (target.remap) this.emitRemapped(segment);
      else for (const key of segment.keys) this.sink.builtin(key);
    }
  }

  private emitRemapped(segment: Extract<RhsSegment, { kind: 'keys' }>): void {
    this.remapDepth++;
    try {
      for (const key of segment.keys) {
        this.emittedKeys++;
        if (this.remapDepth > MAX_REMAP_DEPTH || this.emittedKeys > MAX_EMITTED_KEYS) {
          this.recursionFailed = true;
          this.cancelPendingTimer();
          this.keys = [];
          this.currentMode = null;
          this.sink.error('E223 recursive mapping');
          return;
        }
        this.sink.route(key);
        if (this.recursionFailed) return;
      }
    } finally {
      this.remapDepth--;
    }
  }

  private routeAll(keys: readonly VimKey[]): void {
    for (const key of keys) {
      if (this.recursionFailed) return;
      this.sink.route(key);
    }
  }
}
