export type ActionId = 'kaiba.save' | 'kaiba.close'
  | 'hop.char1' | 'hop.char1Line' | 'hop.word' | 'hop.line';

export const ACTION_MODES: Readonly<Record<ActionId, readonly ('n' | 'i' | 'x' | 'o')[]>> = {
  'kaiba.save': ['n', 'x', 'i'],
  'kaiba.close': ['n', 'x', 'i'],
  'hop.char1': ['n', 'x', 'o'],
  'hop.char1Line': ['n', 'x', 'o'],
  'hop.word': ['n', 'x', 'o'],
  'hop.line': ['n', 'x', 'o'],
};

export function isActionId(value: string): value is ActionId {
  return Object.prototype.hasOwnProperty.call(ACTION_MODES, value);
}

export const isHopAction = (id: ActionId): boolean => id.startsWith('hop.');
