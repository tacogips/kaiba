import type { ActionId } from './actions';
import { buildHints, isTrigger } from './hints';
import { HopSession, type HopKind, type HopSource, type HopStep } from './hop';
import { KeyMapper, type FeedResult, type MapperSink } from './mapper';
import type { CompiledKeymap } from './keymap-schema';
import type { HintView, HopView, MapMode, VimHost, VimKey } from './types';

export interface RuntimeCallbacks {
  processKey(key: VimKey): void;
  routeKey(key: VimKey): void;
  runAction(id: ActionId): void;
  executeEx(command: string): void;
  openPrompt(): void;
  error(message: string): void;
  mapMode(): MapMode;
  parserPending(): string;
  hasCountOrRegister(): boolean;
  replaying(): boolean;
  promptOpen(): boolean;
  extended(): boolean;
  refresh(): void;
}

function hintMode(mode: MapMode): 'n' | 'x' | 'o' | null {
  return mode === 'n' || mode === 'x' || mode === 'o' ? mode : null;
}

export class KeymapRuntime {
  private readonly mapper: KeyMapper;
  private hintTimer: (() => void) | null = null;
  private hintValue: HintView | null = null;
  private hopSession: HopSession | null = null;
  private disposed = false;

  constructor(private readonly keymap: CompiledKeymap, private readonly host: VimHost, private readonly callbacks: RuntimeCallbacks) {
    const sink: MapperSink = {
      builtin: (key) => callbacks.processKey(key),
      route: (key) => callbacks.routeKey(key),
      action: (id) => callbacks.runAction(id),
      ex: (command) => callbacks.executeEx(command),
      prompt: () => callbacks.openPrompt(),
      error: (message) => callbacks.error(message),
      changed: () => { this.afterKey(); callbacks.refresh(); },
    };
    this.mapper = new KeyMapper(keymap, (ms, cb) => host.timer(ms, cb), sink);
  }

  feed(key: VimKey): FeedResult { return this.mapper.feed(key, runtimeModeFromMap(this.callbacks.mapMode())); }
  flush(): void { this.mapper.flush(); this.afterKey(); }
  pending(): string { return this.mapper.pending(); }
  pendingKeys(): readonly VimKey[] { return this.mapper.buffer(); }
  hints(): HintView | null { return this.hintValue; }
  hopActive(): boolean { return this.hopSession !== null; }
  hopView(): HopView | null { return this.hopSession ? this.currentHopView : null; }

  private currentHopView: HopView | null = null;

  closeHints(): void {
    this.cancelHintTimer();
    this.hintValue = null;
    this.mapper.suspendTimeout(false);
  }

  afterKey(): void {
    if (this.disposed) return;
    const mode = hintMode(this.callbacks.mapMode());
    const pending = [...this.callbacks.parserPending(), ...this.mapper.buffer()];
    const eligible = this.keymap.hints.enabled && mode !== null && !this.callbacks.hasCountOrRegister()
      && !this.callbacks.replaying() && !this.callbacks.promptOpen() && !this.hopSession;
    if (!eligible || !pending.length) { this.closeHints(); return; }

    if (this.hintValue) {
      const view = buildHints(this.keymap, mode, pending, this.callbacks.extended());
      if (view.entries.length) {
        this.hintValue = view;
        this.mapper.suspendTimeout(true);
      } else this.closeHints();
      return;
    }
    if (!isTrigger(this.keymap, mode, pending)) return;
    this.cancelHintTimer();
    const signature = pending.join('\u0000');
    this.hintTimer = this.host.timer(this.keymap.hints.delayMs, () => {
      this.hintTimer = null;
      const current = [...this.callbacks.parserPending(), ...this.mapper.buffer()];
      if (!this.disposed && current.join('\u0000') === signature && !this.callbacks.promptOpen() && !this.hopSession) {
        const view = buildHints(this.keymap, mode, current, this.callbacks.extended());
        if (view.entries.length) { this.hintValue = view; this.mapper.suspendTimeout(true); this.callbacks.refresh(); }
      }
    });
  }

  startHop(kind: HopKind, source: HopSource): HopStep {
    if (!this.keymap.hop.enabled) return { kind: 'cancel', message: null };
    this.closeHints();
    this.hopSession = new HopSession(kind, this.keymap.hop, source);
    return this.applyHop(this.hopSession.start());
  }

  feedHop(key: VimKey): HopStep {
    if (!this.hopSession) return { kind: 'cancel', message: null };
    return this.applyHop(this.hopSession.feed(key));
  }

  endHop(): void { this.hopSession = null; this.currentHopView = null; }

  setReplay(on: boolean): void { this.mapper.setReplay(on); }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.cancelHintTimer();
    this.mapper.suspendTimeout(false);
    this.mapper.flush();
    this.mapper.setReplay(false);
    this.hintValue = null;
    this.endHop();
  }

  private applyHop(step: HopStep): HopStep {
    if (step.kind === 'pending') this.currentHopView = step.view;
    else this.endHop();
    return step;
  }

  private cancelHintTimer(): void {
    const cancel = this.hintTimer;
    this.hintTimer = null;
    if (cancel) cancel();
  }
}

function runtimeModeFromMap(mode: MapMode): 'n' | 'i' | 'x' | 'o' {
  return mode === 'c' ? 'n' : mode;
}
