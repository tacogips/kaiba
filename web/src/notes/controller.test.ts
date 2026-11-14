import { describe, expect, test } from 'bun:test'
import { NotebookReadOnlyController } from './controller'
import type { Notebook } from './types'

const notebook = (): Notebook => ({
  notebookId: 'book-1',
  title: 'Launch',
  readOnly: false,
  createdAt: '2026-07-25T00:00:00Z',
  updatedAt: '2026-07-25T00:00:00Z',
  tags: [],
})

const folderAssignment = {
  tag: {
    tagId: 'tag-folder-work',
    name: 'Work',
    classId: 'folder',
    parentTagId: null,
    isSystem: false,
    createdAt: '2026-07-25T00:00:00Z',
  },
  provenance: 'human',
  assignedBy: 'kaiba-web',
  deletable: true,
  createdAt: '2026-07-25T00:00:01Z',
}

describe('read-only convergence', () => {
  test('rejects a refresh snapshot older than a completed unlock', async () => {
    const updates: Notebook[] = []
    const controller = new NotebookReadOnlyController({
      setReadOnly: async (_id, readOnly) => ({ ...notebook(), readOnly }),
    }, (updated) => updates.push(updated))
    const locked = { ...notebook(), readOnly: true }
    controller.adopt(locked)
    const refreshSnapshot = controller.snapshot()

    await controller.set(locked, false)

    expect(updates.at(-1)?.readOnly).toBe(false)
    expect(controller.adopt(locked, refreshSnapshot).readOnly).toBe(false)
  })

  test('serializes writes so a stale completion cannot replace the newest decision', async () => {
    const writes: boolean[] = []
    let releaseFirst: (() => void) | undefined
    const firstGate = new Promise<void>((resolve) => { releaseFirst = resolve })
    const updates: boolean[] = []
    const controller = new NotebookReadOnlyController({
      setReadOnly: async (_id, readOnly) => {
        writes.push(readOnly)
        if (writes.length === 1) await firstGate
        return { ...notebook(), readOnly }
      },
    }, (updated) => updates.push(updated.readOnly))
    const locked = { ...notebook(), readOnly: true }

    const unlock = controller.set(locked, false)
    const relock = controller.set({ ...locked, readOnly: false }, true)
    releaseFirst?.()
    await Promise.all([unlock, relock])

    expect(writes).toEqual([false, true])
    expect(updates).toEqual([true])
  })

  test('retains the prior canonical state and reports a current failure', async () => {
    const updates: Array<{ readOnly: boolean; error?: string }> = []
    const controller = new NotebookReadOnlyController({
      setReadOnly: async () => { throw new Error('offline') },
    }, (updated, error) => updates.push({ readOnly: updated.readOnly, error }))
    const locked = { ...notebook(), readOnly: true }

    await controller.set(locked, false)

    expect(updates).toEqual([{ readOnly: true, error: 'offline' }])
  })

  test('preserves a newer tag response when an older unlock response finishes later', async () => {
    let releaseUnlock: (() => void) | undefined
    const unlockGate = new Promise<void>((resolve) => { releaseUnlock = resolve })
    const locked = { ...notebook(), readOnly: true }
    const updates: Notebook[] = []
    const controller = new NotebookReadOnlyController({
      setReadOnly: async (_id, readOnly) => {
        await unlockGate
        return { ...locked, readOnly }
      },
    }, (updated) => updates.push(updated))
    controller.adopt(locked)

    const unlock = controller.set(locked, false)
    controller.adopt({
      ...locked,
      updatedAt: '2026-07-25T00:00:01Z',
      tags: [folderAssignment],
    })
    releaseUnlock?.()
    await unlock

    expect(updates.at(-1)).toMatchObject({
      readOnly: false,
      updatedAt: '2026-07-25T00:00:01Z',
      tags: [folderAssignment],
    })
  })

  test('preserves a newer unlock when an older tag response finishes later', async () => {
    const locked = { ...notebook(), readOnly: true }
    const controller = new NotebookReadOnlyController({
      setReadOnly: async (_id, readOnly) => ({ ...locked, readOnly }),
    }, () => {})
    controller.adopt(locked)
    const tagResponseSnapshot = controller.snapshot()

    await controller.set(locked, false)
    const adopted = controller.adopt({
      ...locked,
      updatedAt: '2026-07-25T00:00:01Z',
      tags: [folderAssignment],
    }, tagResponseSnapshot)

    expect(adopted).toMatchObject({
      readOnly: false,
      updatedAt: '2026-07-25T00:00:01Z',
      tags: [folderAssignment],
    })
  })
})
