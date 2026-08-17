import { tagClassId as asTagClassId, tagId as asTagId } from './ids'
import { describe, expect, test } from 'bun:test'
import { parseInlineSegments } from './markdown'
import {
  normalizeSelectionTagName,
  splitSegmentsByTagTerms,
  splitTextByTagTerms,
  tagTermsFromAssignments,
  type TagTerm,
} from './tagMatch'
import type { NoteTagAssignment } from './types'
import type { TagId } from './ids'

function assignment(
  tagId: TagId,
  name: string,
  overrides: Partial<NoteTagAssignment['tag']> = {},
): NoteTagAssignment {
  return {
    tag: {
      tagId,
      name,
      classId: null,
      parentTagId: null,
      isSystem: false,
      createdAt: '2026-01-01T00:00:00Z',
      ...overrides,
    },
    provenance: 'human',
    assignedBy: null,
    deletable: true,
    createdAt: '2026-01-01T00:00:00Z',
  }
}

describe('tagTermsFromAssignments', () => {
  test('dedupes across groups and excludes folders, system tags and short names', () => {
    const terms = tagTermsFromAssignments([
      [
        assignment(asTagId('tag-1'), '田中太郎', { classId: asTagClassId('person') }),
        assignment(asTagId('tag-2'), 'archive', { classId: asTagClassId('folder') }),
        assignment(asTagId('tag-3'), 'notebook-kind:user-memo', { isSystem: true }),
        assignment(asTagId('tag-4'), 'x'),
      ],
      [assignment(asTagId('tag-1'), '田中太郎', { classId: asTagClassId('person') }), assignment(asTagId('tag-5'), 'meiji')],
    ])
    expect(terms.map((term) => term.tagId).sort()).toEqual([asTagId('tag-1'), asTagId('tag-5')])
  })

  test('orders longest name first', () => {
    const terms = tagTermsFromAssignments([[assignment(asTagId('a'), 'meiji'), assignment(asTagId('b'), 'meiji era')]])
    expect(terms.map((term) => term.name)).toEqual([asTagId('meiji era'), asTagId('meiji')])
  })
})

describe('splitTextByTagTerms', () => {
  const terms: TagTerm[] = [
    { tagId: asTagId('era'), name: 'meiji era' },
    { tagId: asTagId('person'), name: '田中' },
    { tagId: asTagId('meiji'), name: 'meiji' },
  ]

  test('marks occurrences and keeps surrounding text', () => {
    const segments = splitTextByTagTerms('The meiji restoration and 田中 met.', terms)
    expect(segments).toEqual([
      { kind: 'text', text: 'The ' },
      { kind: 'tagTerm', text: 'meiji', tagId: asTagId('meiji') },
      { kind: 'text', text: ' restoration and ' },
      { kind: 'tagTerm', text: '田中', tagId: asTagId('person') },
      { kind: 'text', text: ' met.' },
    ])
  })

  test('prefers the longest tag at a shared position and matches case-insensitively', () => {
    const segments = splitTextByTagTerms('Meiji Era politics', terms)
    expect(segments[0]).toEqual({ kind: 'tagTerm', text: 'Meiji Era', tagId: asTagId('era') })
    expect(segments[1]).toEqual({ kind: 'text', text: ' politics' })
  })

  test('returns the text untouched when nothing matches', () => {
    expect(splitTextByTagTerms('nothing here', terms)).toEqual([
      { kind: 'text', text: 'nothing here' },
    ])
  })

  test('matches adjacent occurrences in Japanese text without delimiters', () => {
    const segments = splitTextByTagTerms('田中は田中です', [{ tagId: asTagId('p'), name: '田中' }])
    expect(segments).toEqual([
      { kind: 'tagTerm', text: '田中', tagId: asTagId('p') },
      { kind: 'text', text: 'は' },
      { kind: 'tagTerm', text: '田中', tagId: asTagId('p') },
      { kind: 'text', text: 'です' },
    ])
  })
})

describe('splitSegmentsByTagTerms', () => {
  test('splits only plain text segments', () => {
    const segments = parseInlineSegments('meiji **meiji** `meiji` [meiji](https://example.com)')
    const decorated = splitSegmentsByTagTerms(segments, [{ tagId: asTagId('meiji'), name: 'meiji' }])
    expect(decorated[0]).toEqual({ kind: 'tagTerm', text: 'meiji', tagId: asTagId('meiji') })
    expect(decorated.filter((segment) => segment.kind === 'tagTerm')).toHaveLength(1)
    expect(decorated.some((segment) => segment.kind === 'bold')).toBe(true)
    expect(decorated.some((segment) => segment.kind === 'code')).toBe(true)
    expect(decorated.some((segment) => segment.kind === 'link')).toBe(true)
  })

  test('passes segments through unchanged with no terms', () => {
    const segments = parseInlineSegments('plain text')
    expect(splitSegmentsByTagTerms(segments, [])).toEqual(segments)
  })
})

describe('normalizeSelectionTagName', () => {
  test('collapses whitespace and trims', () => {
    expect(normalizeSelectionTagName('  田中\n 太郎 ')).toBe('田中 太郎')
  })

  test('rejects empty, too-short and too-long selections', () => {
    expect(normalizeSelectionTagName('   ')).toBeUndefined()
    expect(normalizeSelectionTagName('x')).toBeUndefined()
    expect(normalizeSelectionTagName('a'.repeat(65))).toBeUndefined()
    expect(normalizeSelectionTagName('a'.repeat(64))).toBe('a'.repeat(64))
  })
})
