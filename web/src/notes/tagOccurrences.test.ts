import { describe, expect, test } from 'bun:test'
import { loadTagOccurrences, tagOccurrencesPageLimit, transitionTagOccurrences } from './tagOccurrences'
import type { Note } from './types'

function note(number: number): Note {
  return {
    noteId: `note-${number}`,
    notebookId: 'notebook-1',
    noteNumber: number,
    title: `Note ${number}`,
    bodyMarkdown: '',
    readOnly: false,
    createdAt: '',
    updatedAt: '',
    tags: [],
  }
}

describe('loadTagOccurrences', () => {
  test('clears prior occurrence buttons synchronously when selection changes', () => {
    expect(transitionTagOccurrences('tag-A', 'tag-B', [note(1)])).toEqual([])
    expect(transitionTagOccurrences('tag-A', 'tag-A', [note(1)])).toHaveLength(1)
  })

  test('loads all pages beyond 200 records and advances the offset by received length', async () => {
    const offsets: number[] = []
    const result = await loadTagOccurrences('tag', async (_tag, offset) => {
      offsets.push(offset)
      if (offset === 0) return Array.from({ length: tagOccurrencesPageLimit }, (_, index) => note(index))
      return [note(tagOccurrencesPageLimit)]
    }, () => true)

    expect(offsets).toEqual([0, tagOccurrencesPageLimit])
    expect(result?.map((entry) => entry.noteId)).toHaveLength(201)
  })

  test('continues past an exact 200-record multiple until an empty short page', async () => {
    const offsets: number[] = []
    const result = await loadTagOccurrences('tag', async (_tag, offset) => {
      offsets.push(offset)
      if (offset < tagOccurrencesPageLimit * 2) {
        return Array.from({ length: tagOccurrencesPageLimit }, (_, index) => note(offset + index))
      }
      return []
    }, () => true)

    expect(offsets).toEqual([0, 200, 400])
    expect(result).toHaveLength(400)
  })

  test('rejects a full page that makes no unique-record progress', async () => {
    const repeated = Array.from({ length: tagOccurrencesPageLimit }, (_, index) => note(index))
    await expect(loadTagOccurrences('tag', async () => repeated, () => true))
      .rejects.toThrow('did not advance')
  })

  test('does not publish A after B resolves first during rapid tag switching', async () => {
    let current = true
    let resolveA: ((value: Note[]) => void) | undefined
    const oldResult = loadTagOccurrences('A', () => new Promise<Note[]>((resolve) => {
      resolveA = resolve
    }), () => current)
    current = false
    const newResult = loadTagOccurrences('B', async () => [note(2)], () => true)
    await expect(newResult).resolves.toMatchObject([{ noteId: 'note-2' }])
    resolveA?.([note(1)])

    await expect(oldResult).resolves.toBeUndefined()
  })
})
