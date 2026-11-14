import { For, Show, createEffect, createSignal, type JSX } from 'solid-js'
import { tagClassId } from '../notes/ids'
import { qualifiedTagLabel } from '../notes/tree'
import { documentPageMetadata } from '../notes/documentPages'
import { useApp } from '../state/appStore'
import { TagNotesPopup } from './TagNotesPopup'
import { WorkspaceIcon } from './WorkspaceIcon'
import '../reader-controls.css'

/** Edits assignments on this page; changing a chip never renames a shared tag. */
export function PageTagsEditor(): JSX.Element {
  const app = useApp()
  const note = () => app.notes().find((row) => row.noteId === app.state.noteId)
    ?? (app.state.note?.noteId === app.state.noteId ? app.state.note : undefined)
  const [viewingTag, setViewingTag] = createSignal<string>()
  const [editing, setEditing] = createSignal(false)
  const [draft, setDraft] = createSignal('')
  const [classId, setClassId] = createSignal('')
  const existingTag = () => app.state.tags.find((tag) => tag.name === draft().trim())
  const selectedClass = () => existingTag()?.classId ?? classId()
  const [original, setOriginal] = createSignal<string>()
  const [busy, setBusy] = createSignal(false)
  const [error, setError] = createSignal<{ noteId: string; message: string }>()
  createEffect(() => { const id = app.state.noteId; if (id) { setDraft(''); setOriginal(undefined); setError(undefined); setEditing(false); setViewingTag(undefined) } })
  const save = async (event: Event) => {
    event.preventDefault()
    const selected = note()
    const name = draft().trim()
    const previous = original()
    if (!selected || !name || busy()) return
    setBusy(true)
    setError(undefined)
    try {
      if (name !== previous) {
        const chosenClass = selectedClass()
        await app.client.applyNoteTag(selected.noteId, name, chosenClass ? tagClassId(chosenClass) : undefined)
        if (previous) {
          try { await app.client.removeNoteTag(selected.noteId, previous) }
          catch { throw new Error('The new tag was added, but the previous tag could not be removed. Retry removing it.') }
        }
      }
      setDraft(''); setOriginal(undefined); setEditing(false)
    } catch (failure) {
      setError({ noteId: selected.noteId, message: failure instanceof Error ? failure.message : 'Tag could not be saved' })
    } finally { await app.refreshCatalog(); setBusy(false) }
  }
  const remove = async (name: string) => {
    const selected = note()
    if (!selected || busy()) return
    setBusy(true); setError(undefined)
    try { await app.client.removeNoteTag(selected.noteId, name); await app.refreshCatalog() }
    catch (failure) { setError({ noteId: selected.noteId, message: failure instanceof Error ? failure.message : 'Tag could not be removed' }) }
    finally { setBusy(false) }
  }
  return <Show when={note() && documentPageMetadata(note())}>
    <section class="page-tags-editor" aria-label="Current page tags">
      <span class="page-tags-label">Page tags</span>
      <div class="page-tag-list"><For each={note()?.tags ?? []}>{(assignment) => <span class="page-tag-chip">
        <button type="button" class="tag-chip-open" title={`${assignment.tag.classId ?? 'Unclassified'}: ${qualifiedTagLabel(app.state.tags, assignment.tag.tagId)}`} onClick={() => { setEditing(false); setViewingTag(assignment.tag.name) }}>{assignment.tag.name}</button>
        <Show when={assignment.deletable}>
          <button type="button" class="page-tag-action" aria-label={`Edit tag ${assignment.tag.name}`} title="Edit tag" disabled={busy()} onClick={() => {
            setOriginal(assignment.tag.name); setDraft(assignment.tag.name); setClassId(assignment.tag.classId ?? ''); setEditing(true)
          }}><WorkspaceIcon name="edit" /></button>
          <button type="button" class="page-tag-action" aria-label={`Remove tag ${assignment.tag.name}`} title="Remove tag" disabled={busy()}
            onClick={() => void remove(assignment.tag.name)}><WorkspaceIcon name="close" /></button>
        </Show>
      </span>}</For></div>
      <button type="button" class="secondary reader-control" aria-label="Add page tag" title="Add page tag" onClick={() => {
        setOriginal(undefined); setDraft(''); setClassId(''); setEditing(true)
      }}><WorkspaceIcon name="add" /></button>
      <Show when={editing()}><div class="page-tag-popover" role="dialog" aria-label={original() ? 'Edit page tag' : 'Add page tag'}>
      <form onSubmit={(event) => void save(event)}
        onKeyDown={(event) => { if (event.key === 'Escape' && !busy()) { event.preventDefault(); setOriginal(undefined); setDraft(''); setEditing(false) } }}>
        <input type={selectedClass() === 'date' ? 'date' : 'text'} aria-label="Page tag" list="page-tag-suggestions" placeholder={original() ? 'Edit page tag' : 'Add page tag'} value={draft()}
          ref={(input) => queueMicrotask(() => { input.focus(); input.select() })}
          disabled={busy()} onInput={(event) => setDraft(event.currentTarget.value)} />
        <datalist id="page-tag-suggestions"><For each={app.state.tags.filter((tag) => tag.classId !== 'folder')}>{(tag) => <option value={tag.name} label={`${tag.classId ?? 'Unclassified'}: ${qualifiedTagLabel(app.state.tags, tag.tagId)}`} />}</For></datalist>
        <label class="page-tag-class-field">Type
          <select aria-label="Tag type" value={selectedClass()} disabled={busy() || Boolean(existingTag()?.classId)} onChange={(event) => setClassId(event.currentTarget.value)}>
            <option value="">Free tag</option>
            <For each={(app.state.tagClasses ?? []).filter((item) => item.classId !== 'folder')}>{(item) => <option value={item.classId} title={item.description ?? undefined}>{item.label}</option>}</For>
          </select>
        </label>
        <Show when={existingTag()}><small class="page-tag-ontology-hint">Existing tag · {qualifiedTagLabel(app.state.tags, existingTag()!.tagId)}</small></Show>
        <button type="submit" class="secondary reader-control" aria-label={original() ? 'Save tag' : 'Add tag'} title={original() ? 'Save' : 'Add'}
          aria-busy={busy()} disabled={busy() || !draft().trim()}><WorkspaceIcon name="check" /></button>
        <button type="button" class="secondary reader-control" aria-label="Cancel tag edit" title="Cancel" disabled={busy()}
          onClick={() => { setOriginal(undefined); setDraft(''); setEditing(false) }}><WorkspaceIcon name="close" /></button>
        <Show when={error()?.noteId === app.state.noteId}><p role="alert">{error()?.message}</p></Show>
      </form>
      </div></Show>
      <Show when={!editing() && error()?.noteId === app.state.noteId}>
        <button type="button" class="secondary reader-control reader-control-error" aria-label={error()?.message} title={error()?.message}
          onClick={() => setEditing(true)}><WorkspaceIcon name="warning" /></button>
      </Show>
      <Show when={viewingTag()} keyed>{(name) => <TagNotesPopup client={app.client} tagName={name} notebooks={app.state.notebooks ?? []}
        onOpenNote={(noteId, notebookId) => app.openNoteWithReturn(noteId, notebookId)} onClose={() => setViewingTag(undefined)} />}</Show>
    </section>
  </Show>
}
