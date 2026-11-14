import { describe, expect, test } from 'bun:test'
import {
  NotebookProgressController,
  NotebookReadOnlyController,
  NotebookScopeController,
  pruneNotebookActivatorEntries,
  replaceNotebook,
  stageNotebookUpdate,
  tagRemovalCanAffectConstraints,
  type PendingNotebookCommit,
} from './controller'
import type { Notebook } from './types'

const notebook = (progress: string): Notebook => ({
  notebookId: 'book-1',
  title: 'Launch',
  progress,
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

describe('progress convergence', () => {
  test('serializes writes and replays the newest intent outside view context', async () => {
    const writes: string[] = []
    let releaseFirst: (() => void) | undefined
    const firstGate = new Promise<void>((resolve) => { releaseFirst = resolve })
    const updates: string[] = []
    const controller = new NotebookProgressController({
      setProgress: async (_id, progress) => {
        writes.push(progress)
        if (writes.length === 1) await firstGate
        return notebook(progress)
      },
      readNotebook: async () => notebook('none'),
    }, (updated) => updates.push(updated.progress))

    const first = controller.move(notebook('none'), 'progress')
    const second = controller.move(notebook('progress'), 'done')
    releaseFirst?.()
    await Promise.all([first, second])
    expect(writes).toEqual(['progress', 'done'])
    expect(updates.at(-1)).toBe('done')
  })

  test('reconciles canonical state after current failure', async () => {
    const updates: Array<{ progress: string; error?: string }> = []
    const controller = new NotebookProgressController({
      setProgress: async () => { throw new Error('offline') },
      readNotebook: async () => notebook('pending'),
    }, (updated, error) => updates.push({ progress: updated.progress, error }))
    await controller.move(notebook('none'), 'done')
    expect(updates.at(-1)).toEqual({ progress: 'pending', error: 'offline' })
  })

  test('falls back to the last canonical state when write and refresh both fail', async () => {
    const updates: Array<{ progress: string; error?: string }> = []
    const controller = new NotebookProgressController({
      setProgress: async () => { throw new Error('write offline') },
      readNotebook: async () => { throw new Error('read offline') },
    }, (updated, error) => updates.push({ progress: updated.progress, error }))
    controller.adopt(notebook('none'))

    await controller.move(notebook('none'), 'done')
    expect(updates.at(-1)).toEqual({
      progress: 'none',
      error: 'write offline; canonical refresh failed: read offline',
    })
  })

  test('rejects a refresh snapshot older than a completed progress mutation', async () => {
    const controller = new NotebookProgressController({
      setProgress: async (_id, progress) => notebook(progress),
      readNotebook: async () => notebook('none'),
    }, () => {})
    controller.adopt(notebook('none'))
    const refreshSnapshot = controller.snapshot()

    await controller.move(notebook('none'), 'done')

    const staleProgressRefresh = { ...notebook('none'), title: 'Renamed on refresh' }
    expect(controller.adopt(staleProgressRefresh, refreshSnapshot)).toMatchObject({
      progress: 'done',
      title: 'Renamed on refresh',
    })
    expect(controller.adopt(notebook('done'), controller.snapshot()).progress).toBe('done')
  })

  test('stages a converge confirmation until an active drag ends', async () => {
    let releaseWrite: (() => void) | undefined
    const writeGate = new Promise<void>((resolve) => { releaseWrite = resolve })
    let visible = [notebook('none')]
    let draggingNotebookId: string | undefined
    let pending: PendingNotebookCommit | undefined
    const controller = new NotebookProgressController({
      setProgress: async (_id, progress) => {
        await writeGate
        return notebook(progress)
      },
      readNotebook: async () => notebook('none'),
    }, (updated) => {
      if (draggingNotebookId) {
        pending = stageNotebookUpdate(visible, pending, updated, 1)
      } else {
        visible = replaceNotebook(visible, updated)
      }
    })

    const convergence = controller.move(notebook('none'), 'done')
    const draggedCard = visible[0]
    draggingNotebookId = draggedCard?.notebookId
    releaseWrite?.()
    await convergence

    expect(draggingNotebookId).toBe('book-1')
    expect(visible[0]).toBe(draggedCard)
    expect(pending?.notebooks[0]?.progress).toBe('done')

    draggingNotebookId = undefined
    visible = pending?.notebooks ?? visible
    pending = undefined
    expect(visible[0]?.progress).toBe('done')
  })
})

describe('read-only convergence', () => {
  test('rejects a refresh snapshot older than a completed unlock', async () => {
    const updates: Notebook[] = []
    const controller = new NotebookReadOnlyController({
      setReadOnly: async (_id, readOnly) => ({ ...notebook('none'), readOnly }),
    }, (updated) => updates.push(updated))
    const locked = { ...notebook('none'), readOnly: true }
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
        return { ...notebook('none'), readOnly }
      },
    }, (updated) => updates.push(updated.readOnly))
    const locked = { ...notebook('none'), readOnly: true }

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
    const locked = { ...notebook('none'), readOnly: true }

    await controller.set(locked, false)

    expect(updates).toEqual([{ readOnly: true, error: 'offline' }])
  })

  test('preserves a newer tag response when an older unlock response finishes later', async () => {
    let releaseUnlock: (() => void) | undefined
    const unlockGate = new Promise<void>((resolve) => { releaseUnlock = resolve })
    const locked = { ...notebook('none'), readOnly: true }
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
    const locked = { ...notebook('none'), readOnly: true }
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

describe('cross-field notebook convergence', () => {
  test('preserves a completed unlock when an older progress response finishes later', async () => {
    let releaseProgress: (() => void) | undefined
    const progressGate = new Promise<void>((resolve) => { releaseProgress = resolve })
    const locked = { ...notebook('none'), readOnly: true }
    let visible = locked
    const progressController = new NotebookProgressController({
      setProgress: async (_id, progress) => {
        await progressGate
        return { ...notebook(progress), readOnly: true }
      },
      readNotebook: async () => locked,
    }, (updated) => { visible = reconcile(updated) })
    const readOnlyController = new NotebookReadOnlyController({
      setReadOnly: async (_id, readOnly) => ({ ...notebook('none'), readOnly }),
    }, (updated) => { visible = reconcile(updated) })
    const reconcile = (updated: Notebook): Notebook =>
      readOnlyController.visible(progressController.visible(updated))
    progressController.adopt(locked)
    readOnlyController.adopt(locked)

    const progressWrite = progressController.move(locked, 'done')
    await readOnlyController.set(visible, false)
    expect(visible).toMatchObject({ progress: 'done', readOnly: false })

    releaseProgress?.()
    await progressWrite
    expect(visible).toMatchObject({ progress: 'done', readOnly: false })
  })

  test('preserves completed progress when an older unlock response finishes later', async () => {
    let releaseUnlock: (() => void) | undefined
    const unlockGate = new Promise<void>((resolve) => { releaseUnlock = resolve })
    const locked = { ...notebook('none'), readOnly: true }
    let visible = locked
    const progressController = new NotebookProgressController({
      setProgress: async (_id, progress) => ({ ...notebook(progress), readOnly: true }),
      readNotebook: async () => locked,
    }, (updated) => { visible = reconcile(updated) })
    const readOnlyController = new NotebookReadOnlyController({
      setReadOnly: async (_id, readOnly) => {
        await unlockGate
        return { ...notebook('none'), readOnly }
      },
    }, (updated) => { visible = reconcile(updated) })
    const reconcile = (updated: Notebook): Notebook =>
      readOnlyController.visible(progressController.visible(updated))
    progressController.adopt(locked)
    readOnlyController.adopt(locked)

    const unlock = readOnlyController.set(locked, false)
    await progressController.move(locked, 'done')
    expect(visible).toMatchObject({ progress: 'done', readOnly: true })

    releaseUnlock?.()
    await unlock
    expect(visible).toMatchObject({ progress: 'done', readOnly: false })
  })
})

describe('notebook scope generation', () => {
  test('preserves single-filter replacement and supports ordered intersection groups', () => {
    const controller = new NotebookScopeController()
    expect(controller.tagFilterIdGroups()).toEqual([])

    controller.select({ kind: 'folder', tagId: 'folder-work', tagName: 'Work' })
    expect(controller.tagFilterIdGroups()).toEqual([['folder-work']])

    controller.add({ kind: 'tag', tagId: 'topic-launch', tagName: 'Launch', classId: 'topic' })
    expect(controller.current().constraints).toEqual([
      { kind: 'folder', tagId: 'folder-work', tagName: 'Work' },
      {
      kind: 'tag',
      tagId: 'topic-launch',
      tagName: 'Launch',
      classId: 'topic',
      },
    ])
    expect(controller.tagFilterIdGroups()).toEqual([['folder-work'], ['topic-launch']])

    controller.remove('folder-work')
    expect(controller.tagFilterIdGroups()).toEqual([['topic-launch']])
    controller.clear()
    expect(controller.tagFilterIdGroups()).toEqual([])
  })

  test('invalidates older folder-to-tag and tag-to-folder completions', () => {
    const controller = new NotebookScopeController()
    const folder = controller.select({ kind: 'folder', tagId: 'folder-work', tagName: 'Work' })
    const tag = controller.select({ kind: 'tag', tagId: 'topic-launch', tagName: 'Launch', classId: 'topic' })
    expect(controller.isCurrent(folder)).toBe(false)
    expect(controller.isCurrent(tag)).toBe(true)

    const newerFolder = controller.select({ kind: 'folder', tagId: 'folder-archive', tagName: 'Archive' })
    expect(controller.isCurrent(tag)).toBe(false)
    expect(controller.isCurrent(newerFolder)).toBe(true)
  })

  test('reconciles constraints independently and ignores duplicate additions', () => {
    const controller = new NotebookScopeController()
    controller.select({ kind: 'folder', tagId: 'folder-work', tagName: 'Old Work' })
    const beforeDuplicate = controller.add({
      kind: 'folder',
      tagId: 'folder-work',
      tagName: 'Ignored',
    })
    expect(controller.isCurrent(beforeDuplicate)).toBe(true)
    controller.add({ kind: 'tag', tagId: 'topic-launch', tagName: 'Launch', classId: 'topic' })

    controller.reconcile([
      {
        tagId: 'folder-work',
        name: 'Work',
        classId: 'folder',
        parentTagId: null,
        isSystem: false,
        createdAt: '',
      },
    ])

    expect(controller.current().constraints).toEqual([
      {
        kind: 'folder',
        tagId: 'folder-work',
        tagName: 'Work',
        classId: 'folder',
      },
    ])

    const beforeReclassification = controller.snapshot()
    controller.reconcile([
      {
        tagId: 'folder-work',
        name: 'Work topic',
        classId: 'topic',
        parentTagId: null,
        isSystem: false,
        createdAt: '',
      },
    ])
    expect(controller.isCurrent(beforeReclassification)).toBe(false)
    expect(controller.current().constraints).toEqual([
      {
        kind: 'tag',
        tagId: 'folder-work',
        tagName: 'Work topic',
        classId: 'topic',
      },
    ])

    const beforeDeletion = controller.snapshot()
    controller.reconcile([])
    expect(controller.isCurrent(beforeDeletion)).toBe(false)
    expect(controller.current().constraints).toEqual([])
  })

  test('prunes missing and disconnected notebook activators', () => {
    const retained = { isConnected: true }
    const activators = new Map([
      ['retained', retained],
      ['disconnected', { isConnected: false }],
      ['removed', { isConnected: true }],
    ])

    pruneNotebookActivatorEntries(activators, ['retained', 'disconnected'])

    expect([...activators.entries()]).toEqual([['retained', retained]])
  })

  test('detects descendant removals for every active tag class', () => {
    const topicRoot = {
      tagId: 'topic-roadmap',
      name: 'Roadmap',
      classId: 'topic',
      parentTagId: null,
      isSystem: false,
      createdAt: '',
    }
    const topicChild = {
      tagId: 'topic-web',
      name: 'Web',
      classId: 'topic',
      parentTagId: 'topic-roadmap',
      isSystem: false,
      createdAt: '',
    }
    const personal = {
      tagId: 'tag-personal',
      name: 'Personal',
      classId: null,
      parentTagId: null,
      isSystem: false,
      createdAt: '',
    }
    const tags = [topicRoot, topicChild, personal]
    const constraints = [{
      kind: 'tag' as const,
      tagId: 'topic-roadmap',
      tagName: 'Roadmap',
      classId: 'topic',
    }]

    expect(tagRemovalCanAffectConstraints(topicChild, constraints, tags)).toBe(true)
    expect(tagRemovalCanAffectConstraints(topicRoot, constraints, tags)).toBe(true)
    expect(tagRemovalCanAffectConstraints(personal, constraints, tags)).toBe(false)
  })
})
