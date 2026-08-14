import { describe, expect, test } from 'bun:test'
import { diaryNotebooks, notebookCategories, notebookPreview } from './notebookList'
import type { Notebook, NoteTagAssignment } from './types'

const assignment = (tagId: string, name: string, provenance = 'ai'): NoteTagAssignment => ({
  tag: {
    tagId,
    name,
    classId: name.startsWith('notebook-kind:') ? 'document-kind' : 'topic',
    parentTagId: null,
    isSystem: name.startsWith('notebook-kind:'),
    createdAt: '2026-08-14T00:00:00Z',
  },
  provenance,
  assignedBy: provenance === 'ai' ? 'kaiba-ai-tagger' : 'kaiba-web',
  deletable: true,
  createdAt: '2026-08-14T00:00:00Z',
})

const notebook = (id: string, updatedAt: string, tags: NoteTagAssignment[] = []): Notebook => ({
  notebookId: id,
  title: id,
  readOnly: false,
  createdAt: updatedAt,
  updatedAt,
  tags,
})

describe('diary notebook list', () => {
  test('sorts recent writing first and can filter by an AI classification', () => {
    const topic = assignment('topic-garden', 'garden')
    const values = [
      notebook('older', '2026-08-12T00:00:00Z', [topic]),
      notebook('newer', '2026-08-14T00:00:00Z'),
      notebook('middle', '2026-08-13T00:00:00Z', [topic]),
    ]
    expect(diaryNotebooks(values).map((value) => value.notebookId))
      .toEqual(['newer', 'middle', 'older'])
    expect(diaryNotebooks(values, topic.tag.tagId).map((value) => value.notebookId))
      .toEqual(['middle', 'older'])
  })

  test('omits internal backing notebooks but keeps imported and translated material', () => {
    const values = [
      notebook('chat', '2026-08-14T04:00:00Z', [assignment('kind-chat', 'notebook-kind:agent-conversation')]),
      notebook('memory', '2026-08-14T03:00:00Z', [assignment('kind-memory', 'notebook-kind:long-term-memory')]),
      notebook('tag-memo', '2026-08-14T02:00:00Z', [assignment('kind-tag', 'notebook-kind:tag-memo')]),
      notebook('import', '2026-08-14T01:00:00Z', [assignment('kind-import', 'notebook-kind:imported-material')]),
      notebook('translation', '2026-08-14T00:00:00Z', [assignment('kind-translation', 'notebook-kind:translation')]),
    ]
    expect(diaryNotebooks(values).map((value) => value.notebookId))
      .toEqual(['import', 'translation'])
  })

  test('shows useful categories without exposing notebook kind markers', () => {
    const topic = assignment('topic-garden', 'garden')
    const kind = assignment('kind-import', 'notebook-kind:imported-material', 'system')
    expect(notebookCategories(notebook('book', '', [topic, kind]))).toEqual([topic])
  })

  test('normalizes whitespace and truncates a Unicode preview to 80 characters', () => {
    expect(notebookPreview('  hello\n\nworld  ')).toBe('hello world')
    expect(notebookPreview('界'.repeat(81))).toBe(`${'界'.repeat(80)}…`)
    expect(notebookPreview(null)).toBe('No note text yet.')
  })
})
