import { describe, expect, it } from 'vitest';
import { ACTION_MODES, isActionId, isHopAction, type ActionId } from '../actions';

describe('action table', () => {
  it('matches the design mode registry exactly', () => expect(ACTION_MODES).toEqual({
    'kaiba.save': ['n', 'x', 'i'], 'kaiba.close': ['n', 'x', 'i'], 'hop.char1': ['n', 'x', 'o'], 'hop.char1Line': ['n', 'x', 'o'],
    'hop.word': ['n', 'x', 'o'], 'hop.line': ['n', 'x', 'o'],
  }));
  it.each(Object.entries(ACTION_MODES) as [ActionId, readonly ('n' | 'i' | 'x' | 'o')[]][])('exports modes for %s', (id, modes) => {
    expect(isActionId(id)).toBe(true);
    expect(modes.length).toBeGreaterThan(0);
    expect([...modes].every((mode) => ['n', 'i', 'x', 'o'].includes(mode))).toBe(true);
  });
  it.each(['kaiba.save', 'kaiba.close'])('does not classify %s as hop', (id) => expect(isHopAction(id as ActionId)).toBe(false));
  it.each(['hop.char1', 'hop.char1Line', 'hop.word', 'hop.line'])('classifies %s as hop', (id) => expect(isHopAction(id as ActionId)).toBe(true));
  it('rejects unknown action ids', () => expect(isActionId('nope')).toBe(false));
});
