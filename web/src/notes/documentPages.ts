import { fileId, type FileId } from './ids'
import type { Note } from './types'

export interface DocumentPageMetadata {
  pageNumber: number
  ocrState: 'pending' | 'complete'
  originFileId: FileId
  analysis: {
    isDocument?: boolean
    language?: string
    writingMode: 'horizontal' | 'vertical' | 'unknown'
    binding: 'left' | 'right' | 'unknown'
    title?: string
  }
}

export function documentPageMetadata(note?: Note): DocumentPageMetadata | undefined {
  if (!note?.metaJSON) return undefined
  try {
    const page = JSON.parse(note.metaJSON)?.documentPage
    if (!page || !Number.isSafeInteger(page.pageNumber) || page.pageNumber < 1
      || !['pending', 'complete'].includes(page.ocrState)
      || typeof page.originFileId !== 'string' || !/^file-[a-zA-Z0-9-]+$/.test(page.originFileId)) return undefined
    const analysis = page.analysis ?? {}
    return {
      pageNumber: page.pageNumber, ocrState: page.ocrState, originFileId: fileId(page.originFileId),
      analysis: {
        isDocument: typeof analysis.isDocument === 'boolean' ? analysis.isDocument : undefined,
        language: typeof analysis.language === 'string' ? analysis.language : undefined,
        title: typeof analysis.title === 'string' ? analysis.title : undefined,
        writingMode: ['horizontal', 'vertical'].includes(analysis.writingMode) ? analysis.writingMode : 'unknown',
        binding: ['left', 'right'].includes(analysis.binding) ? analysis.binding : 'unknown',
      },
    }
  } catch { return undefined }
}

export function storedImageFileId(href: string): FileId | undefined {
  const match = /^\/files\/(file-[a-zA-Z0-9-]+)$/.exec(href)
  return match?.[1] ? fileId(match[1]) : undefined
}

export function pageStepForArrow(key: string, binding: 'left' | 'right' | 'unknown'): number {
  if (key !== 'ArrowLeft' && key !== 'ArrowRight') return 0
  const nextKey = binding === 'right' ? 'ArrowLeft' : 'ArrowRight'
  return key === nextKey ? 1 : -1
}
