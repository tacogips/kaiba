import { expect, test } from 'bun:test'
import { parseInlineSegments, parseMarkdownBlocks, plainInlineText } from './markdown'
import { parseNotebookDraft } from './notebookDraft'

test('an escaped note marker remains one note and displays without its escape backslash', () => {
  const source = String.raw`Notebook
\<><>
Still first
<><>
Second`
  const notes = parseNotebookDraft(source).notes
  expect(notes).toHaveLength(2)
  expect(notes[0]?.bodyMarkdown).toContain(String.raw`\<><>`)
  expect(plainInlineText(notes[0]!.bodyMarkdown)).toBe('Notebook\n<><>\nStill first')
})

test('Markdown punctuation escapes work in prose and formatting while code retains literal backslashes', () => {
  expect(plainInlineText(String.raw`\*literal\* \#heading \[link\](url) \<><> \\ \q`)).toBe('*literal* #heading [link](url) <><> \\ \\q')
  expect(parseInlineSegments(String.raw`**\<><>**`)).toEqual([{ kind: 'bold', text: '<><>' }])
  expect(parseInlineSegments('`\\<><>`')).toEqual([{ kind: 'code', text: '\\<><>' }])
  expect(parseMarkdownBlocks('```\n\\<><>\n```')).toEqual([{ kind: 'code', text: '\\<><>', language: null }])
})
