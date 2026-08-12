import type { NoteFileAttachment } from './types'

// Projection of a note's file attachments into the ordered image list the
// reader's carousel shows: captured source pages first (in page order), then
// images extracted from those pages (in stored order). Non-image attachments
// never appear.

export const sourcePageImageRole = 'source-page-image'
export const embeddedImageRole = 'embedded'

export interface NoteImageEntry {
  fileId: string
  mediaType: string
  /** Human label: "Page 3" for a page capture, the original filename or
   * "Image 2" for an embedded image. */
  label: string
  role: string
}

export function noteImageEntries(attachments: NoteFileAttachment[]): NoteImageEntry[] {
  const images = attachments.filter((attachment) => attachment.file.mediaType.startsWith('image/'))
  const byPosition = (a: NoteFileAttachment, b: NoteFileAttachment) =>
    a.position - b.position || a.file.createdAt.localeCompare(b.file.createdAt)
      || a.file.fileId.localeCompare(b.file.fileId)
  const pages = images.filter((attachment) => attachment.role === sourcePageImageRole).sort(byPosition)
  const embedded = images.filter((attachment) => attachment.role === embeddedImageRole).sort(byPosition)
  return [
    ...pages.map((attachment) => ({
      fileId: attachment.file.fileId,
      mediaType: attachment.file.mediaType,
      label: `Page ${attachment.position}`,
      role: attachment.role,
    })),
    ...embedded.map((attachment, index) => ({
      fileId: attachment.file.fileId,
      mediaType: attachment.file.mediaType,
      label: attachment.file.originalFilename ?? `Image ${index + 1}`,
      role: attachment.role,
    })),
  ]
}

/** The carousel position reached by a horizontal swipe or arrow step.
 * Stepping back (right swipe / right arrow) before the first image closes the
 * carousel, matching the page-flip metaphor: `null` means "return to the
 * note text". Steps past the last image stay on the last image. */
export function steppedImageIndex(current: number, delta: number, count: number): number | null {
  const next = current + delta
  if (next < 0) return null
  if (next >= count) return Math.max(0, count - 1)
  return next
}
