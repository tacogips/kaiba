import { Text } from '@codemirror/state';
import { describe, expect, it } from 'vitest';
import { charClass, classAt, clampNormal, firstNonBlank, graphemeColumn, nextGrapheme, posAtColumn, prevGrapheme } from '../words';

const doc = (value: string) => Text.of(value.split('\n'));

describe('word character classes', () => {
  it.each([[' ', 0], ['\t', 0], ['a', 1], ['7', 1], ['_', 1], ['あ', 1], ['!', 2], ['-', 2], ['é', 1]] as const)('classifies %j', (ch, expected) => expect(charClass(ch)).toBe(expected));
  it.each([['sound-kit', 5, 1], ['a-b', 1, 1], ['-ab', 0, 2], ['ab-', 2, 2], ['a--b', 1, 2], ['a - b', 2, 2], ['x-y', 1, 1], ['😀a-b', 3, 1]] as const)('classifies hyphen in %s at %i', (line, index, expected) => expect(classAt(line, index)).toBe(expected));
});

describe('grapheme movement and columns', () => {
  it.each([
    ['áb', 0, 2], ['áb', 1, 2], ['👩‍💻x', 0, 5], ['👩‍💻x', 2, 5], ['日本', 0, 1], ['a\nb', 1, 2], ['a\nb', 2, 3],
  ])('steps forward in %j', (value, from, expected) => expect(nextGrapheme(doc(value), from)).toBe(expected));
  it.each([
    ['áb', 2, 0], ['👩‍💻x', 5, 0], ['日本', 1, 0], ['a\nb', 2, 1], ['a\nb', 3, 2],
  ])('steps backward in %j', (value, from, expected) => expect(prevGrapheme(doc(value), from)).toBe(expected));
  it('counts graphemes from the line start and treats tabs as one column', () => {
    const value = doc('á\t👩‍💻z');
    expect(graphemeColumn(value, 2)).toBe(1);
    expect(graphemeColumn(value, 1)).toBe(0);
    expect(graphemeColumn(value, 3)).toBe(2);
    expect(graphemeColumn(value, value.length)).toBe(4);
  });
  it.each([[0, 0], [1, 2], [2, 3], [3, 3], [Infinity, 3]] as const)('maps desired column %s', (column, expected) => expect(posAtColumn(doc('ábc'), 1, column)).toBe(expected));
});

describe('normal cursor and indentation helpers', () => {
  it.each([['abc', 3, 2], ['abc', 2, 2], ['\nabc', 0, 0], ['abc\n', 4, 4], ['', 0, 0]] as const)('clamps %j', (value, pos, expected) => expect(clampNormal(doc(value), pos)).toBe(expected));
  it.each([['  x', 1, 2], ['\tx', 1, 1], [' \t ', 1, 3], ['  \nx', 1, 2], ['x', 1, 0]] as const)('finds first nonblank in %j', (value, line, expected) => expect(firstNonBlank(doc(value), line)).toBe(expected));
});
