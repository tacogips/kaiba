import type { Note, NoteGraphNeighbor, NoteLink } from './types'

export function connectionGroup(kind: string): { title: string; explanation: string } {
  switch (kind) {
    case 'explicit-link': return { title: 'Saved links', explanation: 'Links saved between pages. Each entry shows the direction and link type.' }
    case 'shared-tag': return { title: 'Shared tags', explanation: 'Suggested because the pages have tags in common; this is not a saved link.' }
    case 'lexical': return { title: 'Similar text', explanation: 'Suggested because the pages contain similar wording; this is not a saved link.' }
    default: return { title: 'Related pages', explanation: 'Suggested connections to other pages.' }
  }
}

export function savedLinkDescription(neighbor: NoteGraphNeighbor, links: NoteLink[]): string {
  const matches = links.filter((link) =>
    (link.fromNoteId === neighbor.seedNoteId && link.toNoteId === neighbor.note.noteId)
    || (link.toNoteId === neighbor.seedNoteId && link.fromNoteId === neighbor.note.noteId))
  if (!matches.length) return 'Saved connection between this page and the destination'
  return matches.map((link) => {
    const kind = link.linkKind.replace(/[-_]+/g, ' ')
    const origin = link.provenance === 'human' ? 'Added manually' : `Added by ${link.provenance}`
    return `${link.fromNoteId === neighbor.seedNoteId ? 'Saved link to this destination' : 'Saved link from this destination'} · ${kind} · ${origin}`
  }).join('; ')
}

export function suggestedConnectionDescription(neighbor: NoteGraphNeighbor, source?: Note): string {
  if (neighbor.edgeKind === 'shared-tag') {
    const sourceTags = new Set(source?.tags?.map((assignment) => assignment.tag.tagId))
    const shared = neighbor.note.tags?.filter((assignment) => sourceTags.has(assignment.tag.tagId)).map((assignment) => assignment.tag.name) ?? []
    return shared.length ? `Shared tags: ${shared.join(', ')}` : 'Suggested: shared tags'
  }
  return neighbor.edgeKind === 'lexical' ? 'Suggested: similar wording' : 'Suggested connection'
}
