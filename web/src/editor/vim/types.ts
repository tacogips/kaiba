import type { ChangeSet, EditorState, TransactionSpec } from '@codemirror/state';

export type VimMode = 'normal' | 'insert' | 'replace' | 'visual' | 'visual-line' | 'visual-block' | 'operator-pending';
export type CursorShape = 'bar' | 'block' | 'underline';
export type Platform = 'apple' | 'other';
export interface VimKeyInput { key: string; code?: string; ctrlKey: boolean; metaKey: boolean; altKey: boolean; shiftKey: boolean }
export type VimKey = string;
export type OperatorKind = 'd' | 'c' | 'y' | '>' | '<' | 'g~' | 'gu' | 'gU';
export type MotionKind = 'h' | 'l' | 'j' | 'k' | '0' | '^' | '$' | 'w' | 'b' | 'e' | 'ge' | 'W' | 'B' | 'E' | 'gg' | 'G' | 'f' | 'F' | 't' | 'T' | ';' | ',' | '%' | '{' | '}' | 'H' | 'M' | 'L' | 'C-d' | 'C-u' | 'C-f' | 'C-b' | '+' | 'BS' | 'g;' | 'g,';
export type MapMode = 'n' | 'i' | 'x' | 'o' | 'c';
export interface HintEntry { key: string; desc: string; group: boolean }
export interface HintView { prefix: string; entries: readonly HintEntry[]; summary: string }
export interface HopLabel { pos: number; text: string }
export interface HopView { labels: readonly HopLabel[]; revision: number }
export interface MotionSpec { kind: MotionKind; char?: string }
export interface FindState { kind: 'f' | 'F' | 't' | 'T'; char: string }
export interface VimViewport { topLine: number; rows: number }
export interface MotionContext { count: number; explicitCount: boolean; desiredColumn: number | null; viewport: VimViewport; lastFind: FindState | null }
export interface MotionResult { pos: number; linewise: boolean; inclusive: boolean; desiredColumn: number | null; jump: boolean; scrollLines?: number; lastFind?: FindState }
export type TextObjectKind = 'w' | 'W' | '"' | "'" | '`' | '(' | '[' | '{' | '<';
export interface TextObjectSpec { around: boolean; kind: TextObjectKind }
export interface TextRange { from: number; to: number; linewise: boolean }
export interface Register { text: string; linewise: boolean; blockwise?: boolean; tokens?: readonly RecordToken[] }
export type RecordToken = { kind: 'key'; key: VimKey } | { kind: 'edit'; deleteBefore: number; deleteAfter: number; insert: string } | { kind: 'move'; motion: MotionKind };
export interface ClipboardAdapter { read(): Promise<string>; write(text: string): Promise<void> }
/** Editor commands reachable from keymap actions and ex commands (`:w`, `:q`). */
export interface VimActions { save(): void; close(): void }
export interface VimUpdate { state: EditorState; changes: ChangeSet; docChanged: boolean; selectionSet: boolean; userEvent: string | null }
export interface VimHost {
  state(): EditorState;
  dispatch(spec: TransactionSpec): void;
  subscribe(cb: (update: VimUpdate) => void): () => void;
  undo(): boolean;
  redo(): boolean;
  historyReduced(): boolean;
  viewport(): VimViewport;
  scrollLines(lines: number): void;
  scrollCaret(): void;
  clipboard: ClipboardAdapter;
  actions: VimActions;
  closePopupWithEscape(): boolean;
  announce(message: string, assertive?: boolean): void;
  platform: Platform;
  matchesDefaultKeymap(input: VimKeyInput): boolean;
  compositionActive(): boolean;
  typeText(text: string): void;
  defaultKey(key: VimKey): boolean;
  isVisible(pos: number): boolean;
  timer(ms: number, cb: () => void): () => void;
}
export type PromptKind = ':' | '/' | '?';
export interface VimSnapshot {
  mode: VimMode;
  label: string;
  pending: string;
  recording: string | null;
  search: string | null;
  message: string | null;
  messageKind: 'info' | 'error' | null;
  prompt: { kind: PromptKind; initial: string } | null;
  cursorShape: CursorShape;
  displayCursor: number;
  displayCursorEnd: number;
  blockRanges?: TextRange[];
  hints?: HintView | null;
  hop?: HopView | null;
}
export interface VimInputHook {
  handleKey(input: VimKeyInput): boolean;
  allowsTextInput(): boolean;
  overwriteRange(text: string): { from: number; to: number } | null;
  noteCompositionDiscarded(): void;
  flushPendingInput?(): void;
}
export const COUNT_LIMIT = 10_000;
export const SCAN_LIMIT = 65_536;
export const REPLAY_DEPTH_LIMIT = 100;
export const REPLAY_TOKEN_LIMIT = 100_000;
export const INDENT_UNIT = '  ';
