import { ChangeSet } from '@codemirror/state';
import { describe, expect, it } from 'vitest';
import { isMarkName, MarkTable } from '../marks';

describe('isMarkName', () => {
  it('accepts lowercase ASCII letters', () => {
    expect(isMarkName('a')).toBe(true);
    expect(isMarkName('z')).toBe(true);
  });

  it('rejects uppercase, digits and multi-character names', () => {
    expect(isMarkName('A')).toBe(false);
    expect(isMarkName('1')).toBe(false);
    expect(isMarkName('ab')).toBe(false);
    expect(isMarkName('')).toBe(false);
  });
});

describe('MarkTable', () => {
  it('stores and retrieves named marks', () => {
    const marks = new MarkTable();
    marks.set('a', 4);
    expect(marks.get('a')).toBe(4);
  });

  it('returns null for an unset mark', () => {
    expect(new MarkTable().get('b')).toBeNull();
  });

  it('maps marks and the context mark through an insertion before them', () => {
    const marks = new MarkTable();
    marks.set('a', 4);
    marks.setContext(5);
    marks.map(ChangeSet.of({ from: 2, insert: 'xx' }, 8));
    expect(marks.get('a')).toBe(6);
    expect(marks.context()).toBe(7);
  });

  it('keeps marks after an insertion that occurs after them', () => {
    const marks = new MarkTable();
    marks.set('a', 4);
    marks.map(ChangeSet.of({ from: 6, insert: 'x' }, 8));
    expect(marks.get('a')).toBe(4);
  });

  it('maps a mark inside a deleted range to the deletion start', () => {
    const marks = new MarkTable();
    marks.set('a', 4);
    marks.setContext(5);
    marks.map(ChangeSet.of({ from: 2, to: 6 }, 8));
    expect(marks.get('a')).toBe(2);
    expect(marks.context()).toBe(2);
  });

  it('maps marks on the deletion boundary with negative association', () => {
    const marks = new MarkTable();
    marks.set('a', 2);
    marks.map(ChangeSet.of({ from: 2, to: 5 }, 8));
    expect(marks.get('a')).toBe(2);
  });

  it('keeps context unset until assigned', () => {
    const marks = new MarkTable();
    expect(marks.context()).toBeNull();
    marks.setContext(3);
    expect(marks.context()).toBe(3);
  });
});
