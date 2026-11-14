import { describe, expect, test } from 'bun:test'
import { noteImageEntries, steppedImageIndex } from './noteImages'
import type { NoteFileAttachment } from './types'

function attachment(partial: {
  fileId: string
  role: string
  position: number
  mediaType?: string
  originalFilename?: string | null
  createdAt?: string
}): NoteFileAttachment {
  return {
    noteId: 'note-1',
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
      attachment({ fileId: 'e2', role: 'embedded', position: 2 }),
      attachment({ fileId: 'p9', role: 'source-page-image', position: 9 }),
      attachment({ fileId: 'e1', role: 'embedded', position: 1 }),
      attachment({ fileId: 'p3', role: 'source-page-image', position: 3 }),
    ])
    expect(entries.map((entry) => entry.fileId)).toEqual(['p3', 'p9', 'e1', 'e2'])
    expect(entries[0]?.label).toBe('Page 3')
    expect(entries[2]?.label).toBe('Image 1')
  })

  test('non-image attachments and other roles are excluded', () => {
    const entries = noteImageEntries([
      attachment({ fileId: 'doc', role: 'source-page-image', position: 1, mediaType: 'application/pdf' }),
      attachment({ fileId: 'rel', role: 'related', position: 1 }),
      attachment({ fileId: 'ok', role: 'embedded', position: 1 }),
    ])
    expect(entries.map((entry) => entry.fileId)).toEqual(['ok'])
  })

  test('embedded images prefer their original filename as the label', () => {
    const entries = noteImageEntries([
      attachment({ fileId: 'e1', role: 'embedded', position: 1, originalFilename: 'figure-1.png' }),
    ])
    expect(entries[0]?.label).toBe('figure-1.png')
  })

  test('ties on position order deterministically by creation time then id', () => {
    const entries = noteImageEntries([
      attachment({ fileId: 'b', role: 'embedded', position: 1, createdAt: '2026-08-12T00:00:02Z' }),
      attachment({ fileId: 'a', role: 'embedded', position: 1, createdAt: '2026-08-12T00:00:01Z' }),
    ])
    expect(entries.map((entry) => entry.fileId)).toEqual(['a', 'b'])
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
