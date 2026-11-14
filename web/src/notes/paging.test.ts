import { describe, expect, test } from 'bun:test'
import {
  NotebookPartialLoadError,
  loadNotebookPages,
  notebookPageLimit,
} from './paging'
import type { Notebook } from './types'

const notebook = (index: number): Notebook => ({
  notebookId: `book-${index}`,
  title: `Book ${index}`,
  readOnly: false,
  createdAt: '',
  updatedAt: '',
  tags: [],
})

describe('notebook paging', () => {
  test('uses bounded offsets and publishes generation-current partial pages', async () => {
    const offsets: number[] = []
    const snapshots: Array<{ count: number; hasMore: boolean }> = []
    const pages = [
      Array.from({ length: notebookPageLimit }, (_, index) => notebook(index)),
      [notebook(notebookPageLimit)],
    ]
    const result = await loadNotebookPages(
      {
        notebooks: async (offset, sort, tagFilterIdGroups, limit) => {
          offsets.push(offset)
          expect(sort).toBe('title')
          expect(tagFilterIdGroups).toEqual([['folder-work'], ['topic-launch']])
          expect(limit).toBe(notebookPageLimit)
          return pages.shift() ?? []
        },
      },
      'title',
      [['folder-work'], ['topic-launch']],
      () => true,
      (values, hasMore) => snapshots.push({ count: values.length, hasMore }),
    )
    expect(offsets).toEqual([0, notebookPageLimit])
    expect(snapshots).toEqual([
      { count: notebookPageLimit, hasMore: true },
      { count: notebookPageLimit + 1, hasMore: false },
    ])
    expect(result?.length).toBe(notebookPageLimit + 1)
  })

  test('deduplicates notebooks that shift across page boundaries', async () => {
    const pages = [
      Array.from({ length: notebookPageLimit }, (_, index) => notebook(index)),
      [notebook(notebookPageLimit - 1), notebook(notebookPageLimit)],
    ]
    const result = await loadNotebookPages(
      { notebooks: async () => pages.shift() ?? [] },
      'updatedAtDesc',
      [],
      () => true,
      () => {},
    )
    expect(result?.length).toBe(notebookPageLimit + 1)
    expect(new Set(result?.map((item) => item.notebookId)).size).toBe(notebookPageLimit + 1)
  })

  test('does not publish a stale generation', async () => {
    const snapshots: number[] = []
    const result = await loadNotebookPages(
      { notebooks: async () => [notebook(1)] },
      'updatedAtDesc',
      [],
      () => false,
      (values) => snapshots.push(values.length),
    )
    expect(result).toBeUndefined()
    expect(snapshots).toEqual([])
  })

  test('fails after a full duplicate page without discarding accepted data', async () => {
    const page = Array.from({ length: notebookPageLimit }, (_, index) => notebook(index))
    const snapshots: number[] = []
    let failure: unknown
    try {
      await loadNotebookPages(
        { notebooks: async () => page },
        'updatedAtDesc',
        [],
        () => true,
        (values) => snapshots.push(values.length),
      )
    } catch (error) {
      failure = error
    }
    expect(failure).toBeInstanceOf(NotebookPartialLoadError)
    expect((failure as NotebookPartialLoadError).message).toContain('no forward progress')
    expect((failure as NotebookPartialLoadError).notebooks).toHaveLength(notebookPageLimit)
    expect(snapshots).toEqual([notebookPageLimit, notebookPageLimit])
  })

  test('stops at the configured page cap', async () => {
    let pageIndex = 0
    let failure: unknown
    try {
      await loadNotebookPages(
        {
          notebooks: async () => {
            const start = pageIndex * notebookPageLimit
            pageIndex += 1
            return Array.from({ length: notebookPageLimit }, (_, index) => notebook(start + index))
          },
        },
        'updatedAtDesc',
        [],
        () => true,
        () => {},
        2,
      )
    } catch (error) {
      failure = error
    }
    expect(failure).toBeInstanceOf(NotebookPartialLoadError)
    expect((failure as NotebookPartialLoadError).message).toContain('after 2 pages')
    expect((failure as NotebookPartialLoadError).notebooks).toHaveLength(
      notebookPageLimit * 2,
    )
    expect(pageIndex).toBe(2)
  })
})
