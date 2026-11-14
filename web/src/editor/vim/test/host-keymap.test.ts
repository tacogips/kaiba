import { afterEach, describe, expect, it, vi } from 'vitest';
import { createTestHost, show } from './host';

describe('Vim keymap test host', () => {
  afterEach(() => vi.useRealTimers());

  it('types text and records the input transaction', () => {
    const host = createTestHost('x|y');
    let userEvent: string | null = null;
    host.subscribe((update) => { userEvent = update.userEvent; });
    host.typeText('ab');
    expect(show(host.state())).toBe('xab|y');
    expect(host.typed).toEqual(['ab']);
    expect(userEvent).toBe('input.type');
  });

  it('defaults Backspace to a backward deletion', () => {
    const host = createTestHost('ab|');
    expect(host.defaultKey('<BS>')).toBe(true);
    expect(show(host.state())).toBe('a|');
    expect(host.defaultKeys).toEqual(['<BS>']);
  });

  it('defaults Delete to a forward deletion', () => {
    const host = createTestHost('|ab');
    expect(host.defaultKey('<Del>')).toBe(true);
    expect(show(host.state())).toBe('|b');
  });

  it('returns false for an unsupported default key', () => {
    const host = createTestHost('ab|');
    expect(host.defaultKey('<F1>')).toBe(false);
    expect(show(host.state())).toBe('ab|');
  });

  it('moves the cursor for left and right defaults', () => {
    const host = createTestHost('ab|');
    expect(host.defaultKey('<Left>')).toBe(true);
    expect(show(host.state())).toBe('a|b');
    expect(host.defaultKey('<Right>')).toBe(true);
    expect(show(host.state())).toBe('ab|');
  });

  it('inserts a newline for the Enter default', () => {
    const host = createTestHost('ab|');
    expect(host.defaultKey('<CR>')).toBe(true);
    expect(show(host.state())).toBe('ab\n|');
  });

  it('runs a timer after its delay', () => {
    vi.useFakeTimers();
    const host = createTestHost('');
    const callback = vi.fn();
    host.timer(100, callback);
    vi.advanceTimersByTime(100);
    expect(callback).toHaveBeenCalledOnce();
  });

  it('cancels a timer', () => {
    vi.useFakeTimers();
    const host = createTestHost('');
    const callback = vi.fn();
    const cancel = host.timer(100, callback);
    cancel();
    vi.advanceTimersByTime(100);
    expect(callback).not.toHaveBeenCalled();
  });

  it('defaults visibility to true', () => {
    const host = createTestHost('');
    expect(host.isVisible(42)).toBe(true);
  });

  it('uses the supplied visibility predicate', () => {
    const host = createTestHost('', { isVisible: (pos) => pos < 10 });
    expect(host.isVisible(9)).toBe(true);
    expect(host.isVisible(10)).toBe(false);
  });
});
