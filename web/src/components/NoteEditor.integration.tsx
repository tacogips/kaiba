import { render } from 'solid-js/web'
import { expect, test } from 'vitest'
import { AppStoreProvider } from '../state/appStore'
import type { NoteGraphQLClient } from '../notes/client'
import { noteId, notebookId } from '../notes/ids'
import { NoteEditor } from './NoteEditor'

async function settle() {
  for (let index = 0; index < 4; index += 1) await new Promise((resolve) => setTimeout(resolve, 0))
}

test('manual editing keeps a failed draft, detects changed source text, and saves to the existing note', async () => {
  const note = { noteId: noteId('note'), notebookId: notebookId('book'), noteNumber: 1, title: 'Original',
    bodyMarkdown: 'Original text', readOnly: false, createdAt: '', updatedAt: '', tags: [] }
  let latest = { ...note }
  let fail = true
  let writes = 0
  const api = {
    initialize: async () => undefined, streamHeaders: () => ({}), appSetting: async () => undefined,
    tags: async () => [], tagClasses: async () => [], notebooks: async () => [],
    note: async () => ({ ...latest }),
    updateNote: async (id: string, text: string) => {
      writes += 1
      expect(id).toBe('note')
      if (fail) throw new Error('Connection lost')
      latest = { ...latest, bodyMarkdown: text }
      return latest
    },
  } as unknown as NoteGraphQLClient
  const originalFetch = globalThis.fetch
  globalThis.fetch = (() => new Promise<Response>(() => undefined)) as unknown as typeof fetch
  const host = document.createElement('div')
  document.body.append(host)
  const dispose = render(() => <AppStoreProvider options={{ client: api,
    router: { currentHash: () => '#/', setHash: () => {}, addListener: () => {}, removeListener: () => {} },
  }}><NoteEditor note={note} /></AppStoreProvider>, host)
  const button = (text: string) => [...host.querySelectorAll('button')].find((item) => item.textContent === text)!
  const write = (text: string) => {
    const textarea = host.querySelector('textarea')!
    textarea.value = text
    textarea.dispatchEvent(new Event('input', { bubbles: true }))
  }
  const save = () => host.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
  try {
    await settle()
    button('Edit my note').click()
    expect(host.querySelector('textarea')?.value).toBe('Original text')
    write('My revised explanation')
    save()
    await settle()
    expect(host.querySelector('[role="alert"]')?.textContent).toContain('Connection lost')
    expect(host.querySelector('textarea')?.value).toBe('My revised explanation')
    latest = { ...latest, bodyMarkdown: 'A newer version from another client' }
    fail = false
    save()
    await settle()
    expect(writes).toBe(1)
    expect(host.querySelector('[role="alert"]')?.textContent).toContain('changed while you were editing')
    button('Discard draft and load latest text').click()
    await settle()
    expect(host.querySelector('textarea')?.value).toBe(latest.bodyMarkdown)
    write('Updated after reviewing the new version')
    save()
    await settle()
    expect(writes).toBe(2)
    expect(latest.bodyMarkdown).toBe('Updated after reviewing the new version')
    expect(host.querySelector('textarea')).toBeNull()
  } finally { dispose(); host.remove(); globalThis.fetch = originalFetch }
})
