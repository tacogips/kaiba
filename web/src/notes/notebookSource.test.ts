import { expect, test } from 'bun:test'
import { notebookSource } from './notebookSource'
import { parseNotebookDraft } from './notebookDraft'

test('joins stored notes without turning literal separators or code into new notes', () => {
  const source = notebookSource(['First\n<><>\nLiteral\n```\n<><>\n```', 'Second'])
  expect(source).toBe('First\n\\<><>\nLiteral\n```\n<><>\n```\n\n<><>\n\nSecond')
  expect(parseNotebookDraft(source).notes).toHaveLength(2)
})
