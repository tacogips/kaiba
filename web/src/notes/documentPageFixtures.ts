import { fileId } from './ids'
import type { DocumentPage } from './types'

/** Test fixture: a complete `Note.documentPage` from the fields a test cares about. */
export function testDocumentPage(
  page: Partial<Omit<DocumentPage, 'originFileId' | 'analysis'>> & {
    originFileId?: string
    analysis?: Partial<DocumentPage['analysis']>
  } = {},
): DocumentPage {
  return {
    pageNumber: page.pageNumber ?? 1,
    originFileId: fileId(page.originFileId ?? 'file-origin'),
    originMediaType: page.originMediaType ?? 'image/png',
    textExtractionMode: page.textExtractionMode ?? null,
    textStatus: page.textStatus ?? 'complete',
    textSource: page.textSource ?? null,
    analysis: {
      isDocument: null, language: null, writingMode: 'unknown', binding: 'unknown', title: null,
      ...page.analysis,
    },
  }
}
