import type { Note } from './types'
import type { AppStore } from '../state/appStore'
import { validateComposerFiles } from './memoComposer'

/** Stage only in the captured page's draft; never reroute an in-flight send. */
export async function stagePageRegion(app: AppStore, note: Note, file: File): Promise<boolean> {
  if (app.state.noteId !== note.noteId) return false
  const draft = app.writingDrafts.get(`discussion:note:${note.noteId}`)
  if (draft.busy() || draft.submission()) throw new Error('Wait for the current message to finish before attaching a selection.')
  const files = [file, ...draft.files()]
  const validation = await validateComposerFiles(files)
  if (!validation.accepted) throw new Error(validation.message)
  if (app.state.noteId !== note.noteId) return false
  draft.setFiles(files); draft.setMemoOnly(false)
  return true
}
