import type { NoteId } from './ids'

export interface DocumentTranslationVersion {
  sourceNoteId: NoteId
  targetLanguage: string
  text: string
  isCurrent: boolean
}
export type DocumentDisplayMode = 'original' | 'text' | 'translation'
export interface DocumentViewSelection {
  mode: DocumentDisplayMode
  translation?: DocumentTranslationVersion
}
