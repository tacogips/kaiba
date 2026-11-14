import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import { notebookId } from '../notes/ids'
import { createWritingDrafts } from '../state/writingDrafts'
import { NoteCapture } from './NoteCapture'
const fixture = vi.hoisted(() => ({ app: {} as Record<string, unknown> }))
vi.mock('../state/appStore', async (original) => ({ ...await original<object>(), useApp: () => fixture.app }))

test('adds Markdown to the active notebook without converting or dropping its formatting', async () => {
  const body = '# Second note\n\n**Bold** text.\n\n- One\n- Two\n\n```js\nconst value = 42\n```'
  const createNote = vi.fn(async () => ({ noteId: 'second', notebookId: 'book' }))
  const openNote = vi.fn()
  fixture.app = { state: { route: { kind: 'home' }, settings: { fontScale: 1.15 } }, writingDrafts: createWritingDrafts(), client: { createNote }, refreshCatalog: vi.fn(async () => {}), openNote, setMessage: vi.fn() }
  const host = document.createElement('div'); document.body.append(host)
  const dispose = render(() => <NoteCapture notebookId={notebookId('book')} empty={true} />, host)
  try {
    const input = host.querySelector('textarea')!
    input.value = body; input.dispatchEvent(new Event('input', { bubbles: true }))
    host.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
    await vi.waitFor(() => expect(createNote).toHaveBeenCalledWith('book', body))
    await vi.waitFor(() => expect(openNote).toHaveBeenCalledWith('second', 'book'))
    expect(input.value).toBe('')
  } finally { dispose(); host.remove() }
})
