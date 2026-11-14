import { describe, expect, test } from 'bun:test'
import { parseNotebookDraft } from './notebookDraft'

describe('Markdown notebook source', () => {
  test('uses the first note first line as title, even if a later line is a heading', () => {
    const result = parseNotebookDraft('Field notes\n\n# A later heading\nBody\n\n<--->\n\n# Second note\nMore **text**')
    expect(result.title).toBe('Field notes')
    expect(result.notes.map((note) => note.bodyMarkdown)).toEqual(['Field notes\n\n# A later heading\nBody', '# Second note\nMore **text**'])
    expect(result.notes.map((note) => note.title)).toEqual(['Field notes', 'Second note'])
  })
  test('does not split fenced code, quoted lines, indented code, or Markdown rules', () => {
    const source = '# Notebook\n\n```text\n<--->\n```\n\n~~~\n<--->\n~~~\n\n> <--->\n\n---\n----\n-----\n\n    <--->\n\n<--->\nSecond'
    const result = parseNotebookDraft(source)
    expect(result.notes).toHaveLength(2)
    expect(result.notes[0]?.bodyMarkdown).toContain('```text\n<--->\n```')
    expect(result.notes[0]?.bodyMarkdown).toContain('> <--->')
    expect(result.notes[0]?.bodyMarkdown).toContain('---\n----\n-----')
    expect(result.notes[1]?.bodyMarkdown).toBe('Second')
    expect(result.fenceOpen).toBe(false)
  })
  test('preserves empty notes, CRLF source, and the offsets used by the outline', () => {
    const source = '# Notes\r\n\r\n<--->\r\n\r\n<--->\r\nFinal note\r\nA line  \r\nAnother'
    const result = parseNotebookDraft(source)
    expect(result.notes.map((note) => note.bodyMarkdown)).toEqual(['# Notes', '', 'Final note\r\nA line  \r\nAnother'])
    expect(result.notes[2]?.startOffset).toBe(source.indexOf('Final note'))
    expect(parseNotebookDraft('# Notes\n<--->').notes).toHaveLength(2)
  })
  test('keeps an unfinished code block intact and never takes the notebook title from another note', () => {
    expect(parseNotebookDraft('# Notes\n```\n<--->\nSecond').notes).toHaveLength(1)
    expect(parseNotebookDraft('# Notes\n```\n<--->\nSecond').fenceOpen).toBe(true)
    expect(parseNotebookDraft('<--->\nSecond').title).toBe('')
  })
  test('accepts three or more hyphens in angle brackets, only on a standalone line', () => {
    const ordinary = '# Notes\nInline <---> marker\n<-->\n<->\n<!-- kaiba:note -->\n----'
    expect(parseNotebookDraft(ordinary).notes).toHaveLength(1)
    for (const marker of ['<--->', '<---->', '<----->', '<-------->']) {
      expect(parseNotebookDraft(ordinary + `\n  ${marker} \t\nSecond`).notes).toHaveLength(2)
      expect(parseNotebookDraft(`# Notes\n\`\`\`text\n${marker}\n\`\`\``).notes).toHaveLength(1)
      expect(parseNotebookDraft(`# Notes\n> ${marker}\n    ${marker}`).notes).toHaveLength(1)
    }
    expect(parseNotebookDraft('# Notes\n<---->\nSecond\n<----->\nThird').notes.map((note) => note.bodyMarkdown)).toEqual(['# Notes', 'Second', 'Third'])
  })
})
