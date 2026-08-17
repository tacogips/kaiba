import type { InlineSegment } from './markdown'
import type { NoteTagAssignment } from './types'
import type { TagId } from './ids'

// Inline tag-term matching (design-docs/specs/tag-detail-pane.md, T1/T2).
// Given the tags attached to a note (and its notebook), plain text segments of
// the rendered markdown are split so occurrences of a tag's name become
// clickable underlined terms. Matching is literal substring, case-insensitive,
// longest-name-first, and never touches code, links, or styled segments.

export interface TagTerm {
  tagId: TagId
  name: string
}

export type TagAwareSegment = InlineSegment | { kind: 'tagTerm'; text: string; tagId: TagId }

/** Names shorter than this underline half the document; skip them. */
export const minimumTagTermLength = 2

/** The matchable terms for a note: its own tag assignments plus its notebook's,
 * deduped. Folder tags organize and system tags label infrastructure
 * (notebook kinds), so neither is a subject worth underlining. */
export function tagTermsFromAssignments(
  groups: ReadonlyArray<readonly NoteTagAssignment[] | undefined>,
): TagTerm[] {
  const byId = new Map<TagId, TagTerm>()
  for (const assignments of groups) {
    for (const assignment of assignments ?? []) {
      const tag = assignment.tag
      const name = tag.name.trim()
      if (tag.classId === 'folder' || tag.isSystem) continue
      if (name.length < minimumTagTermLength) continue
      if (!byId.has(tag.tagId)) byId.set(tag.tagId, { tagId: tag.tagId, name })
    }
  }
  // Longest first so the longest tag wins at a shared match position.
  return [...byId.values()].sort((left, right) =>
    right.name.length - left.name.length || left.name.localeCompare(right.name))
}

/** Splits only `text` segments; bold/italic/code/link segments pass through so
 * decoration never rewrites markup or code. */
export function splitSegmentsByTagTerms(
  segments: readonly InlineSegment[],
  terms: readonly TagTerm[],
): TagAwareSegment[] {
  if (terms.length === 0) return [...segments]
  const result: TagAwareSegment[] = []
  for (const segment of segments) {
    if (segment.kind !== 'text') {
      result.push(segment)
      continue
    }
    result.push(...splitTextByTagTerms(segment.text, terms))
  }
  return result
}

export function splitTextByTagTerms(
  text: string,
  terms: readonly TagTerm[],
): TagAwareSegment[] {
  const lowered = text.toLowerCase()
  const loweredTerms = terms
    .filter((term) => term.name.length >= minimumTagTermLength)
    .map((term) => ({ term, lower: term.name.toLowerCase() }))
  const segments: TagAwareSegment[] = []
  let cursor = 0
  while (cursor < text.length) {
    let best: { index: number; term: TagTerm; length: number } | undefined
    for (const { term, lower } of loweredTerms) {
      const index = lowered.indexOf(lower, cursor)
      if (index < 0) continue
      // Terms arrive longest-first, so a strict `<` keeps the longest match
      // at a shared position.
      if (!best || index < best.index) best = { index, term, length: lower.length }
    }
    if (!best) break
    if (best.index > cursor) segments.push({ kind: 'text', text: text.slice(cursor, best.index) })
    segments.push({
      kind: 'tagTerm',
      text: text.slice(best.index, best.index + best.length),
      tagId: best.term.tagId,
    })
    cursor = best.index + best.length
  }
  if (cursor < text.length) segments.push({ kind: 'text', text: text.slice(cursor) })
  if (segments.length === 0) segments.push({ kind: 'text', text })
  return segments
}

/** Validation for registering a drag selection as a tag (T8). */
export const maximumSelectionTagLength = 64

export function normalizeSelectionTagName(raw: string): string | undefined {
  const collapsed = raw.replace(/\s+/g, ' ').trim()
  if (collapsed.length < minimumTagTermLength) return undefined
  if (collapsed.length > maximumSelectionTagLength) return undefined
  return collapsed
}
