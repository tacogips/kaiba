import type { TagClassId, TagId } from '../notes/ids'
import { For, Show, createMemo, type JSX } from 'solid-js'
import { useApp } from '../state/appStore'
import type { NoteTag } from '../notes/types'

// Right-pane content while no note is selected: notebook-wide aggregates.
// Tags: every tag across the notebook's notes (deduped) plus the notebook's
// own tags. Backlinks require selecting an individual note or page.

export function NotebookTagsTab(): JSX.Element {
  const app = useApp()

  const aggregated = createMemo(() => {
    const notebook = app.notebook()
    const counts = new Map<TagId, { tag: NoteTag; noteCount: number }>()
    for (const assignment of notebook?.tags ?? []) {
      counts.set(assignment.tag.tagId, { tag: assignment.tag, noteCount: 0 })
    }
    for (const note of app.notes()) {
      for (const assignment of note.tags ?? []) {
        const existing = counts.get(assignment.tag.tagId)
        if (existing) existing.noteCount += 1
        else counts.set(assignment.tag.tagId, { tag: assignment.tag, noteCount: 1 })
      }
    }
    const byClass = new Map<TagClassId | null, Array<{ tag: NoteTag; noteCount: number }>>()
    for (const entry of counts.values()) {
      const classId = entry.tag.classId
      byClass.set(classId, [...(byClass.get(classId) ?? []), entry])
    }
    return [...byClass.entries()]
      .map(([classId, tags]) => ({
        classId,
        tags: tags.sort((left, right) => left.tag.name.localeCompare(right.tag.name)),
      }))
      .sort((left, right) => (left.classId ?? '').localeCompare(right.classId ?? ''))
  })

  return (
    <div class="pane-section">
      <Show
        when={app.state.notebookId}
        fallback={<p class="pane-empty">Open a notebook to see its tags.</p>}
      >
        <Show when={aggregated().length === 0}>
          <p class="pane-empty">No tags in this notebook.</p>
        </Show>
        <div class="info-tags">
          <For each={aggregated()}>{(group) =>
            <section class="info-tag-group">
              <h3>{group.classId ?? 'untyped'}</h3>
              <For each={group.tags}>{(entry) =>
                <div class="info-tag-class">
                  <button
                    type="button"
                    class="tag-chip-open"
                    title={`Open tag details: ${entry.tag.name}`}
                    onClick={() => app.openTagPane(entry.tag.tagId)}
                  >#{entry.tag.name}</button>
                  <Show when={entry.noteCount > 0}>
                    <span class="tree-count">{entry.noteCount}</span>
                  </Show>
                </div>}
              </For>
            </section>}
          </For>
        </div>
      </Show>
    </div>
  )
}
