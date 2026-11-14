import { render } from 'solid-js/web'
import { describe, expect, test } from 'vitest'
import type { NoteGraphQLClient } from '../notes/client'
import type { Note, Notebook } from '../notes/types'
import type { AppStore } from '../state/appStore'
import { TocTab } from './TocTab'

const notebook: Notebook = {
  notebookId: 'notebook-1',
  title: 'Research',
  readOnly: false,
  createdAt: '2026-08-13T00:00:00Z',
  updatedAt: '2026-08-13T00:00:00Z',
  tags: [],
}

const notes: Note[] = [
  {
    noteId: 'note-1',
    notebookId: notebook.notebookId,
    noteNumber: 1,
    title: 'Selected note',
    bodyMarkdown: '# Overview\n\n## Details',
    readOnly: false,
    createdAt: '2026-08-13T00:01:00Z',
    updatedAt: '2026-08-13T00:01:00Z',
  },
  {
    noteId: 'note-2',
    notebookId: notebook.notebookId,
    noteNumber: 2,
    title: 'Collapsed note',
    bodyMarkdown: '# Appendix',
    readOnly: false,
    createdAt: '2026-08-13T00:02:00Z',
    updatedAt: '2026-08-13T00:02:00Z',
  },
]

function testStore(): AppStore {
  return {
    state: {
      notebookId: notebook.notebookId,
      noteId: notes[0]?.noteId,
      activeHeadingId: '',
    },
    client: {} as NoteGraphQLClient,
    notes: () => notes,
    notebook: () => notebook,
    openNote: () => undefined,
    openNotebook: () => undefined,
    setActiveHeading: () => undefined,
  } as unknown as AppStore
}

describe('TocTab', () => {
  test('renders notebook -> note -> note heading hierarchy', async () => {
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(() => <TocTab app={testStore()} />, host)
    try {
      const notebookList = host.querySelector<HTMLUListElement>('ul[aria-label="Notebook contents"]')
      const notebookItem = notebookList?.querySelector(':scope > li')
      const noteItems = notebookItem?.querySelectorAll(':scope > ul > li')
      expect(notebookItem?.querySelector(':scope > .toc-notebook')?.textContent).toBe('Research')
      expect(noteItems).toHaveLength(2)

      const selectedNote = noteItems?.[0]
      const selectedHeadings = selectedNote?.querySelectorAll(':scope > ul[aria-label="Note contents"] > li')
      expect(selectedNote?.querySelector(':scope > .toc-note-row .toc-note')?.textContent).toBe('Selected note')
      expect(selectedHeadings).toHaveLength(1)
      expect(selectedHeadings?.[0]?.querySelector(':scope > .toc-entry')?.textContent).toBe('Overview')
      expect(selectedHeadings?.[0]?.querySelector(':scope > ul > li > .toc-entry')?.textContent).toBe('Details')

      const collapsedNote = noteItems?.[1]
      expect(collapsedNote?.querySelector(':scope > ul[aria-label="Note contents"]')).toBeNull()
      const disclosure = collapsedNote?.querySelector<HTMLButtonElement>('.toc-disclosure')
      expect(disclosure?.getAttribute('aria-expanded')).toBe('false')
      disclosure?.click()
      await new Promise<void>((resolve) => window.setTimeout(resolve, 0))
      expect(disclosure?.getAttribute('aria-expanded')).toBe('true')
      expect(collapsedNote?.querySelector(':scope > ul[aria-label="Note contents"] > li > .toc-entry')?.textContent)
        .toBe('Appendix')
    } finally {
      dispose()
      host.remove()
    }
  })
})
