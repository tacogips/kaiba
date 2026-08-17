import { fileId as asFileId, noteId as asNoteId } from './ids'
import { describe, expect, test } from 'bun:test'
import { noteImageEntries, steppedImageIndex } from './noteImages'
import type { NoteFileAttachment } from './types'
import type { FileId } from './ids'

function attachment(partial: {
  fileId: FileId
  role: string
  position: number
  mediaType?: string
  originalFilename?: string | null
  createdAt?: string
}): NoteFileAttachment {
  return {
    noteId: asNoteId('note-1'),
    role: partial.role,
    position: partial.position,
    file: {
      fileId: partial.fileId,
      storageKind: 'local',
      mediaType: partial.mediaType ?? 'image/jpeg',
      byteSize: 1234,
      sha256: 'abc',
      originalFilename: partial.originalFilename ?? null,
      createdAt: partial.createdAt ?? '2026-08-12T00:00:00Z',
    },
  }
}

describe('note image entries', () => {
  test('page captures come first in page order, then embedded images in stored order', () => {
    const entries = noteImageEntries([
      attachment({ fileId: asFileId('e2'), role: 'embedded', position: 2 }),
      attachment({ fileId: asFileId('p9'), role: 'source-page-image', position: 9 }),
      attachment({ fileId: asFileId('e1'), role: 'embedded', position: 1 }),
      attachment({ fileId: asFileId('p3'), role: 'source-page-image', position: 3 }),
    ])
    expect(entries.map((entry) => entry.fileId)).toEqual([asFileId('p3'), asFileId('p9'), asFileId('e1'), asFileId('e2')])
    expect(entries[0]?.label).toBe('Page 3')
    expect(entries[2]?.label).toBe('Image 1')
  })

  test('non-image attachments and other roles are excluded', () => {
    const entries = noteImageEntries([
      attachment({ fileId: asFileId('doc'), role: 'source-page-image', position: 1, mediaType: 'application/pdf' }),
      attachment({ fileId: asFileId('rel'), role: 'related', position: 1 }),
      attachment({ fileId: asFileId('ok'), role: 'embedded', position: 1 }),
    ])
    expect(entries.map((entry) => entry.fileId)).toEqual([asFileId('ok')])
  })

  test('embedded images prefer their original filename as the label', () => {
    const entries = noteImageEntries([
      attachment({ fileId: asFileId('e1'), role: 'embedded', position: 1, originalFilename: 'figure-1.png' }),
    ])
    expect(entries[0]?.label).toBe('figure-1.png')
  })

  test('ties on position order deterministically by creation time then id', () => {
    const entries = noteImageEntries([
      attachment({ fileId: asFileId('b'), role: 'embedded', position: 1, createdAt: '2026-08-12T00:00:02Z' }),
      attachment({ fileId: asFileId('a'), role: 'embedded', position: 1, createdAt: '2026-08-12T00:00:01Z' }),
    ])
    expect(entries.map((entry) => entry.fileId)).toEqual([asFileId('a'), asFileId('b')])
  })
})

describe('carousel stepping', () => {
  test('stepping back past the first image closes (null)', () => {
    expect(steppedImageIndex(0, -1, 5)).toBeNull()
  })

  test('stepping forward stops at the last image', () => {
    expect(steppedImageIndex(4, 1, 5)).toBe(4)
    expect(steppedImageIndex(2, 1, 5)).toBe(3)
  })

  test('normal steps move by delta', () => {
    expect(steppedImageIndex(2, -1, 5)).toBe(1)
  })
})
