import { describe, expect, test } from 'bun:test'
import { documentPageMetadata, pageStepForArrow, storedImageFileId } from './documentPages'
import { parseInlineSegments, plainInlineText } from './markdown'
import { fileId, noteId, notebookId } from './ids'

const note = { noteId: noteId('note'), notebookId: notebookId('book'), noteNumber: 1, title: null,
  bodyMarkdown: '', readOnly: false, createdAt: '', updatedAt: '' }

describe('document page metadata and navigation', () => {
  test('parses stored physical page metadata and preserves unknown analysis', () => {
    const page = documentPageMetadata({ ...note, metaJSON: JSON.stringify({ documentPage: {
      pageNumber: 3, ocrState: 'pending', originFileId: 'file-123', analysis: { binding: 'right', writingMode: 'vertical', language: 'ja' },
    } }) })
    expect(page?.pageNumber).toBe(3)
    expect(page?.analysis).toMatchObject({ binding: 'right', writingMode: 'vertical', language: 'ja' })
    expect(documentPageMetadata({ ...note, metaJSON: '{' })).toBeUndefined()
    expect(documentPageMetadata(note)).toBeUndefined()
  })
  test('arrows follow binding direction', () => {
    expect(pageStepForArrow('ArrowLeft', 'right')).toBe(1)
    expect(pageStepForArrow('ArrowRight', 'right')).toBe(-1)
    expect(pageStepForArrow('ArrowRight', 'left')).toBe(1)
    expect(pageStepForArrow('ArrowLeft', 'left')).toBe(-1)
    expect(pageStepForArrow('ArrowRight', 'unknown')).toBe(1)
    expect(pageStepForArrow('Enter', 'left')).toBe(0)
  })
  test('only exact local file image paths enter authenticated file transport', () => {
    expect(storedImageFileId('/files/file-123')).toBe(fileId('file-123'))
    for (const value of ['//evil.test/files/file-123', '/files/../private', '/files/file-123?x=y',
      'https://evil.test/files/file-123', '/files/file-123/other', '/files/%2e%2e']) {
      expect(storedImageFileId(value)).toBeUndefined()
    }
  })
})

describe('Markdown images', () => {
  test('images remain separate from links and code', () => {
    expect(parseInlineSegments('![Figure](/files/file-123) [Source](https://example.com) `![literal](x)`')).toEqual([
      { kind: 'image', text: 'Figure', href: '/files/file-123' }, { kind: 'text', text: ' ' },
      { kind: 'link', text: 'Source', href: 'https://example.com' }, { kind: 'text', text: ' ' },
      { kind: 'code', text: '![literal](x)' },
    ])
    expect(parseInlineSegments('![](/files/file-123)')).toEqual([{ kind: 'image', text: '', href: '/files/file-123' }])
    expect(plainInlineText('Photo ![caption](image.png)')).toBe('Photo caption')
  })
})
