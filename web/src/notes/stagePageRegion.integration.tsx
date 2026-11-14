import { expect, test } from 'vitest'
import { stagePageRegion } from './stagePageRegion'
import { createWritingDrafts } from '../state/writingDrafts'
import { noteId, notebookId } from './ids'
import type { Note } from './types'
import type { AppStore } from '../state/appStore'

test('stages the selected image with the page draft and preserves its question until Send', async () => {
  const note: Note = { noteId: noteId('source'), notebookId: notebookId('book'), noteNumber: 2, title: null, bodyMarkdown: '', readOnly: true, createdAt: '', updatedAt: '' }
  const writingDrafts = createWritingDrafts()
  const app = { state: { noteId: note.noteId }, writingDrafts } as AppStore
  const draft = writingDrafts.get('discussion:note:source')
  draft.setText('Explain this'); draft.setMemoOnly(true)
  const file = new File([new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10, 0])], 'selection.png', { type: 'image/png' })
  expect(await stagePageRegion(app, note, file)).toBe(true)
  expect(draft.files()).toEqual([file]); expect(draft.text()).toBe('Explain this'); expect(draft.memoOnly()).toBe(false)
  draft.setBusy(true)
  await expect(stagePageRegion(app, note, file)).rejects.toThrow('current message')
  expect(draft.files()).toHaveLength(1)
})
