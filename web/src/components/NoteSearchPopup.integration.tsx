import { Show, createSignal } from 'solid-js'
import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import type { NoteGraphQLClient } from '../notes/client'
import { noteId, notebookId } from '../notes/ids'
import type { Note, Notebook } from '../notes/types'
import { NoteSearchPopup } from './NoteSearchPopup'

test('quick search contains keyboard focus and restores it after Escape from a button', () => {
  const host = document.createElement('div')
  document.body.append(host)
  const [open, setOpen] = createSignal(false)
  const dispose = render(() => <>
    <button onClick={() => setOpen(true)}>Open search</button>
    <Show when={open()}><NoteSearchPopup client={{} as NoteGraphQLClient} tags={[]}
      onOpenNote={() => undefined} onClose={() => setOpen(false)} /></Show>
  </>, host)
  try {
    const opener = host.querySelector('button')!
    opener.focus()
    opener.click()
    expect(document.activeElement?.getAttribute('aria-label')).toBe('Search full note text')
    const close = host.querySelector<HTMLButtonElement>('button[aria-label="Close search"]')!
    close.focus()
    close.dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', shiftKey: true, bubbles: true, cancelable: true }))
    expect(document.activeElement?.getAttribute('aria-label')).toBe('Search full note text')
    document.activeElement!.dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', bubbles: true, cancelable: true }))
    expect(document.activeElement).toBe(close)
    close.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }))
    expect(host.querySelector('[role="dialog"]')).toBeNull()
    expect(document.activeElement).toBe(opener)
    opener.click()
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }))
    expect(host.querySelector('[role="dialog"]')).toBeNull()
    expect(document.activeElement).toBe(opener)
  } finally { dispose(); host.remove() }
})

test('identical page titles identify their notebook before opening a result', async () => {
  const host = document.createElement('div'); document.body.append(host)
  const open = vi.fn()
  const notes = ['native', 'mixed'].map((id) => ({ noteId: noteId(id), notebookId: notebookId(id), noteNumber: 1,
    title: 'Same title', bodyMarkdown: '', readOnly: true, createdAt: '', updatedAt: '' }) satisfies Note)
  const client = { searchNotes: vi.fn(async () => notes.map((note) => ({ note, snippet: 'ORCHID731', rank: 1, matchedTags: [], isLinkedNeighbor: false, termCoverage: 1 }))) } as unknown as NoteGraphQLClient
  const notebooks = notes.map((note) => ({ notebookId: note.notebookId, title: `${note.notebookId}.pdf` })) as Notebook[]
  const dispose = render(() => <NoteSearchPopup client={client} tags={[]} notebooks={notebooks}
    initialQuery="ORCHID731" onOpenNote={open} onClose={() => {}} />, host)
  try {
    await vi.waitFor(() => expect(host.querySelectorAll('.note-search-results button')).toHaveLength(2))
    const buttons = [...host.querySelectorAll<HTMLButtonElement>('.note-search-results button')]
    expect(buttons[0]!.textContent).toContain('native.pdf · #1')
    expect(buttons[1]!.textContent).toContain('mixed.pdf · #1')
    buttons[1]!.click()
    expect(open).toHaveBeenCalledWith(notes[1]!.noteId, notes[1]!.notebookId)
  } finally { dispose(); host.remove() }
})
