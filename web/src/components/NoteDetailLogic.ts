import { APIError } from '../api'
import type { Note } from '../notes/types'
import type { NoteLink, NoteLinkProposal } from '../notes/workspace'

// Pure helpers behind the note detail pane, mirroring RielaNoteEditHelpers.swift,
// RielaNoteLibraryViewModel+ReaderPaging.swift and the metadata pane's link and
// attachment presentation. Everything here is DOM-free so it can be unit tested.

export const readerPageSize = 25
export const readerEdgeThreshold = 2
export const searchPageSize = 20

/** Links are transported without an identifier, so the composite of both note
 * ids and the kind is the stable key (matching `NoteLink.stableId` in Swift). */
export function linkStableId(link: NoteLink): string {
  return `${link.fromNoteId}-${link.toNoteId}-${link.linkKind}`
}

export function counterpartNoteId(link: NoteLink, noteId: string): string {
  return link.fromNoteId === noteId ? link.toNoteId : link.fromNoteId
}

export function linkLabel(
  link: NoteLink,
  currentNoteId: string,
  linkedNotes: Record<string, Note>,
): string {
  const targetNoteId = counterpartNoteId(link, currentNoteId)
  return `${link.linkKind}: ${linkedNotes[targetNoteId]?.title ?? targetNoteId}`
}

/** The workspace accepts only these kinds; anything else falls back to related. */
export function allowedLinkKind(rawValue: string): string {
  const normalized = rawValue.trim()
  return normalized === 'related' || normalized === 'source-citation' ? normalized : 'related'
}

/** Proposals whose target is already linked are dropped so accepting one can
 * never produce a duplicate row. */
export function openLinkProposals(
  proposals: NoteLinkProposal[],
  links: NoteLink[],
  noteId: string,
): NoteLinkProposal[] {
  const linked = new Set(links.map((link) => `${counterpartNoteId(link, noteId)}:${link.linkKind}`))
  return proposals.filter((proposal) =>
    !linked.has(`${proposal.targetNote.noteId}:${allowedLinkKind(proposal.linkKind)}`)
      && proposal.targetNote.noteId !== noteId)
}

export interface SelectionRange {
  start: number
  end: number
}

export function selectionIsValid(range: SelectionRange | undefined, draft: string): boolean {
  if (!range) return false
  return range.start >= 0 && range.end <= draft.length && range.end > range.start
}

export function selectedText(draft: string, range: SelectionRange | undefined): string | undefined {
  return selectionIsValid(range, draft) ? draft.slice(range!.start, range!.end) : undefined
}

export function applyRewrite(
  draft: string,
  range: SelectionRange | undefined,
  replacement: string,
): { body: string; range: SelectionRange | undefined } {
  if (!selectionIsValid(range, draft)) return { body: replacement, range: undefined }
  const start = range!.start
  return {
    body: `${draft.slice(0, start)}${replacement}${draft.slice(range!.end)}`,
    range: { start, end: start + replacement.length },
  }
}

/** A rewrite result is only applied when the draft — and the selected text, when
 * the request was selection-scoped — is still exactly what was submitted. */
export function rewriteResultIsFresh(input: {
  currentDraft: string
  submittedDraft: string
  submittedRange?: SelectionRange
  submittedSelectedText?: string
}): boolean {
  if (input.currentDraft !== input.submittedDraft) return false
  if (!input.submittedRange) return true
  return selectedText(input.currentDraft, input.submittedRange) === input.submittedSelectedText
}

/** Agent-authored comment persisted for a selection question: the selection as a
 * blockquote (truncated to 400 characters), then the question and the answer. */
export function selectionQuestionComment(input: {
  selectedText: string
  question: string
  answerMarkdown: string
}): string {
  const characters = [...input.selectedText]
  const truncated = characters.length > 400 ? `${characters.slice(0, 400).join('')}…` : input.selectedText
  const quoted = truncated
    .split('\n')
    .map((line) => (line.length === 0 ? '>' : `> ${line}`))
    .join('\n')
  return `${quoted}\n\n**Q:** ${input.question.trim()}\n\n**A:** ${input.answerMarkdown.trim()}`
}

export interface ReaderWindow {
  notes: Note[]
  startOffset: number
  hasEarlier: boolean
  hasMore: boolean
}

export const emptyReaderWindow: ReaderWindow = {
  notes: [],
  startOffset: 0,
  hasEarlier: false,
  hasMore: false,
}

export function readerIndex(window: ReaderWindow, noteId: string): number {
  return window.notes.findIndex((note) => note.noteId === noteId)
}

export function adjacentNoteId(
  window: ReaderWindow,
  noteId: string,
  delta: number,
): string | undefined {
  const index = readerIndex(window, noteId)
  if (index < 0) return undefined
  return window.notes[index + delta]?.noteId
}

export function needsLaterPage(window: ReaderWindow, noteId: string, threshold = readerEdgeThreshold): boolean {
  const index = readerIndex(window, noteId)
  return window.hasMore && index >= 0 && window.notes.length - index <= threshold
}

export function needsEarlierPage(window: ReaderWindow, noteId: string, threshold = readerEdgeThreshold): boolean {
  const index = readerIndex(window, noteId)
  return window.hasEarlier && index >= 0 && index < threshold
}

/** Absolute offset of the next unread page after the loaded window. */
export function laterPageOffset(window: ReaderWindow): number {
  return window.startOffset + window.notes.length
}

export function earlierPageRequest(
  window: ReaderWindow,
  pageLimit: number,
): { offset: number; limit: number } | undefined {
  const limit = Math.min(pageLimit, window.startOffset)
  if (limit <= 0) return undefined
  return { offset: window.startOffset - limit, limit }
}

export function appendReaderPage(
  window: ReaderWindow,
  page: Note[],
  requestedLimit: number,
): ReaderWindow {
  const known = new Set(window.notes.map((note) => note.noteId))
  const added = page.filter((note) => !known.has(note.noteId))
  return {
    notes: [...window.notes, ...added],
    startOffset: window.startOffset,
    hasEarlier: window.hasEarlier,
    hasMore: page.length >= requestedLimit && added.length > 0,
  }
}

export function prependReaderPage(
  window: ReaderWindow,
  page: Note[],
  requestOffset: number,
): ReaderWindow {
  const known = new Set(window.notes.map((note) => note.noteId))
  const added = page.filter((note) => !known.has(note.noteId))
  return {
    notes: [...added, ...window.notes],
    startOffset: requestOffset,
    hasEarlier: requestOffset > 0,
    hasMore: window.hasMore,
  }
}

/** Replaces the stored copy of an edited note so the reader strip and the note
 * counter stay consistent with the freshly saved body. */
export function replaceReaderNote(window: ReaderWindow, note: Note): ReaderWindow {
  if (readerIndex(window, note.noteId) < 0) return window
  return {
    ...window,
    notes: window.notes.map((current) => (current.noteId === note.noteId ? note : current)),
  }
}

export function readerPositionLabel(window: ReaderWindow, noteId: string): string | undefined {
  const index = readerIndex(window, noteId)
  if (index < 0) return undefined
  const total = window.hasMore || window.hasEarlier
    ? `${window.startOffset + window.notes.length}+`
    : `${window.notes.length}`
  return `${window.startOffset + index + 1} of ${total}`
}

export interface NoteAttachmentView {
  fileId: string
  mediaType: string
  byteSize: number
  originalFilename: string | null
  role: string | null
}

/** The REST payload nests the stored file under `file` while older callers used
 * a flat record; both shapes are accepted so an attachment is never dropped. */
export function attachmentView(raw: unknown): NoteAttachmentView | undefined {
  if (typeof raw !== 'object' || raw === null) return undefined
  const record = raw as Record<string, unknown>
  const nested = typeof record.file === 'object' && record.file !== null
    ? record.file as Record<string, unknown>
    : record
  const fileId = nested.fileId
  if (typeof fileId !== 'string' || fileId.length === 0) return undefined
  return {
    fileId,
    mediaType: typeof nested.mediaType === 'string' ? nested.mediaType : 'application/octet-stream',
    byteSize: typeof nested.byteSize === 'number' ? nested.byteSize : 0,
    originalFilename: typeof nested.originalFilename === 'string' ? nested.originalFilename : null,
    role: typeof record.role === 'string' ? record.role : null,
  }
}

export function isImageAttachment(attachment: NoteAttachmentView): boolean {
  return attachment.mediaType.startsWith('image/')
}

export function attachmentLabel(attachment: NoteAttachmentView): string {
  return attachment.originalFilename ?? attachment.fileId
}

/** Note tags ride along on the detail payload but are absent from the shared
 * `Note` type, so they are read defensively. */
export function noteTagNames(note: unknown): string[] {
  if (typeof note !== 'object' || note === null) return []
  const assignments = (note as Record<string, unknown>).tags
  if (!Array.isArray(assignments)) return []
  const names: string[] = []
  for (const assignment of assignments) {
    if (typeof assignment !== 'object' || assignment === null) continue
    const tag = (assignment as Record<string, unknown>).tag
    if (typeof tag !== 'object' || tag === null) continue
    const name = (tag as Record<string, unknown>).name
    if (typeof name === 'string' && name.length > 0) names.push(name)
  }
  return names
}

export function workspaceErrorMessage(error: unknown): string {
  if (error instanceof APIError) {
    switch (error.code) {
      case 'provider_not_configured':
        return 'This assistant feature needs its riela workflow provider configured on the host.'
      case 'provider_timeout':
        return 'The assistant workflow timed out. Try again.'
      case 'profile_conflict':
        return 'The active profile changed. Reload the page before continuing.'
      default:
        return error.message
    }
  }
  return error instanceof Error ? error.message : String(error)
}

/** Preview of the title the server will derive while composing: the first ATX
 * heading, else the first non-empty line, capped like `NoteTitleDerivation`. */
export function derivedNoteTitle(bodyMarkdown: string, defaultTitle = 'Untitled'): string {
  const lines = bodyMarkdown.split('\n').slice(0, 40)
  const heading = lines
    .map((line) => /^ {0,3}(#{1,6})\s+(.*)$/.exec(line)?.[2])
    .find((value) => value !== undefined && value.trim().length > 0)
  const candidate = heading ?? lines.find((line) => line.trim().length > 0 && !/^ {4,}/.test(line))
  const title = candidate?.replace(/\s+#+\s*$/, '').trim()
  if (!title) return defaultTitle
  return title.length > 120 ? `${title.slice(0, 120)}…` : title
}

export function noteDisplayTitle(note: Note): string {
  const title = note.title?.trim()
  return title && title.length > 0 ? title : `Note ${note.noteNumber}`
}

/** Slugged markdown-export filename mirroring `rielaNoteExportFilename`:
 * lowercase, non-alphanumerics collapsed to dashes, first 8 dash segments. */
export function noteExportFilename(title: string, fallback = 'note'): string {
  const slugged = title
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .split('-')
    .filter((segment) => segment.length > 0)
    .slice(0, 8)
    .join('-')
  return `${slugged.length > 0 ? slugged : fallback}.md`
}

export const imageZoomLevels = { min: 0.5, max: 3, step: 0.25 } as const

export function clampImageZoom(value: number): number {
  const stepped = Math.round(value / imageZoomLevels.step) * imageZoomLevels.step
  return Math.min(imageZoomLevels.max, Math.max(imageZoomLevels.min, stepped))
}
