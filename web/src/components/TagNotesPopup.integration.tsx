import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import type { NoteGraphQLClient } from '../notes/client'
import type { Note } from '../notes/types'
import { noteId, notebookId } from '../notes/ids'
import { TagNotesPopup } from './TagNotesPopup'

const result: Note = { noteId: noteId('note-tagged'), notebookId: notebookId('book'), noteNumber: 3,
  title: 'Tagged result', bodyMarkdown: '', readOnly: false, createdAt: '', updatedAt: '', tags: [] }

test('tag popup retries errors, paginates, and supports keyboard dismissal', async () => {
  const lookup = vi.fn().mockRejectedValueOnce(new Error('Offline')).mockResolvedValueOnce(Array.from({ length: 50 }, () => result)).mockResolvedValueOnce([])
  const close = vi.fn()
  const host = document.createElement('div')
  document.body.append(host)
  const dispose = render(() => <TagNotesPopup client={{ notesByTag: lookup } as unknown as NoteGraphQLClient}
    tagName="Topic" notebooks={[]} onOpenNote={() => {}} onClose={close} />, host)
  try {
    await vi.waitFor(() => expect(document.querySelector('[role="alert"]')?.textContent).toContain('Offline'))
    document.querySelector<HTMLButtonElement>('[aria-label="Retry tagged notes"]')!.click()
    await vi.waitFor(() => expect(document.querySelectorAll('[aria-label="Tagged notes"] li')).toHaveLength(50))
    const loadMore = [...document.querySelectorAll<HTMLButtonElement>('.tag-notes-popup button')].find((button) => button.textContent === 'Load more')!
    loadMore.click()
    await vi.waitFor(() => expect(lookup).toHaveBeenLastCalledWith('Topic', 50, 50))
    await vi.waitFor(() => expect(loadMore.isConnected).toBe(false))
    document.querySelector('[role="dialog"]')!.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
    expect(close).toHaveBeenCalledTimes(1)
  } finally { dispose(); host.remove() }
})

test('closing a tag popup ignores a pending occurrence response and restores focus', async () => {
  let resolve!: (notes: Note[]) => void
  const lookup = vi.fn(() => new Promise<Note[]>((done) => { resolve = done }))
  const trigger = document.createElement('button')
  document.body.append(trigger)
  trigger.focus()
  const host = document.createElement('div')
  document.body.append(host)
  const dispose = render(() => <TagNotesPopup client={{ notesByTag: lookup } as unknown as NoteGraphQLClient}
    tagName="Topic" notebooks={[]} onOpenNote={() => {}} onClose={() => {}} />, host)
  expect(document.activeElement?.getAttribute('aria-label')).toBe('Close tagged notes')
  dispose()
  resolve([result])
  await Promise.resolve()
  expect(document.querySelector('.tag-notes-popup')).toBeNull()
  expect(document.activeElement).toBe(trigger)
  host.remove(); trigger.remove()
})
