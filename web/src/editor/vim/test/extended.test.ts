import { ChangeSet, EditorState } from '@codemirror/state';
import { describe, expect, it } from 'vitest';
import { joinRaw, scrollCenterDelta, scrollLineResult } from '../extended';
import { ChangeList } from '../marks';

const state = (doc: string) => EditorState.create({ doc });
const apply = (doc: string, result: ReturnType<typeof joinRaw>) => result.outcome ? state(doc).update({ changes: result.outcome.changes }).state.doc.toString() : doc;
describe('extended pure helpers', () => {
  it('joins raw lines without changing spacing', () => expect(apply('a\n  b', joinRaw(state('a\n  b'), 0, 2, null))).toBe('a  b'));
  it('joins the requested count of lines', () => expect(apply('a\nb\nc\nd', joinRaw(state('a\nb\nc\nd'), 0, 3, null))).toBe('abc\nd'));
  it.each([1, 2])('joins at least two lines for count %i', (count) => expect(apply('a\nb\nc', joinRaw(state('a\nb\nc'), 0, count, null))).toBe('ab\nc'));
  it('joins visual lines and returns the line range', () => {
    const result = joinRaw(state('a\nb\nc'), 0, 1, { anchor: 0, head: 2 });
    expect(apply('a\nb\nc', result)).toBe('ab\nc'); expect(result.range).toEqual({ from: 0, to: 3, linewise: true });
  });
  it('joins a single visual line with the next line and returns its range', () => {
    const result = joinRaw(state('a\nb'), 0, 1, { anchor: 0, head: 0 });
    expect(apply('a\nb', result)).toBe('ab'); expect(result.range).toEqual({ from: 0, to: 3, linewise: true });
  });
  it('does not edit when raw join has no following line', () => expect(joinRaw(state('a'), 0, 2, null).outcome).toBeNull());
  it('does not edit when the cursor is on the last line', () => expect(joinRaw(state('a\nb'), 2, 1, null).outcome).toBeNull());
  it('centers cursor line within viewport rows', () => expect(scrollCenterDelta(state('a\nb\nc\nd\ne').doc, 4, { topLine: 1, rows: 4 })).toBe(0));
  it('scrolls while keeping a visible cursor', () => expect(scrollLineResult(state('1\n2\n3\n4\n5').doc, 4, { topLine: 1, rows: 3 }, 1, 0)).toEqual({ scrollLines: 1, cursor: null }));
  it('moves cursor to nearest visible line preserving desired column', () => expect(scrollLineResult(state('abc\ndef\nghi\njkl\nmno').doc, 0, { topLine: 1, rows: 2 }, 2, 1)).toEqual({ scrollLines: 2, cursor: 9 }));
  it('clamps scroll to the document bounds', () => expect(scrollLineResult(state('a\nb\nc').doc, 0, { topLine: 1, rows: 2 }, -10, 0)).toEqual({ scrollLines: 0, cursor: null }));
  it('records and walks changes with boundary errors', () => {
    const list = new ChangeList(), doc = state('a\nb\nc');
    expect(list.step(-1, 1)).toEqual({ error: 'E664 changelist is empty' });
    let update = doc.update({ changes: { from: 0, to: 1, insert: 'A' } });
    list.record(update.changes, update.state.doc);
    update = update.state.update({ changes: { from: 2, to: 3, insert: 'B' } });
    list.record(update.changes, update.state.doc);
    expect(list.step(-1, 1)).toBe(2); expect(list.step(-1, 1)).toBe(0);
    expect(list.step(-1, 1)).toEqual({ error: 'E662 At start of changelist' });
    expect(list.step(1, 1)).toBe(2); expect(list.step(1, 1)).toEqual({ error: 'E663 At end of changelist' });
  });
  it('maps prior changes and replaces a same-line newest entry', () => {
    const list = new ChangeList(), initial = state('abc\ndef');
    let update = initial.update({ changes: { from: 0, to: 0, insert: 'x' } }); list.record(update.changes, update.state.doc);
    update = update.state.update({ changes: { from: 2, to: 2, insert: 'y' } }); list.record(update.changes, update.state.doc);
    expect(list.step(-1, 1)).toBe(2);
    expect(list.step(-1, 1)).toEqual({ error: 'E662 At start of changelist' });
    update = update.state.update({ changes: { from: 6, to: 6, insert: 'z' } }); list.record(update.changes, update.state.doc);
    expect(list.step(-1, 1)).toBe(6);
  });
  it('caps its history at one hundred and supports clear', () => {
    const list = new ChangeList(); let doc = state(Array.from({ length: 150 }, () => 'x').join('\n'));
    for (let i = 0; i < 150; i++) { const at = doc.doc.line(i + 1).from; const update = doc.update({ changes: { from: at, to: at, insert: 'a' } }); doc = update.state; list.record(update.changes, doc.doc); }
    expect(list.step(-1, 100)).toEqual(expect.any(Number));
    expect(list.step(-1, 1)).toEqual({ error: 'E662 At start of changelist' });
    list.clear(); expect(list.step(1, 1)).toEqual({ error: 'E664 changelist is empty' });
  });
  it('uses the first changed range start in the new document', () => {
    const list = new ChangeList(), changes = ChangeSet.of([{ from: 1, to: 2, insert: 'xx' }, { from: 4, to: 4, insert: 'y' }], 5);
    list.record(changes, state('axxcy').doc); expect(list.step(-1, 1)).toBe(1);
  });
});
