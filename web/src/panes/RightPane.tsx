import { Show, createMemo, type JSX } from 'solid-js'
import type { TagId } from '../notes/ids'
import { TabPanel, Tabs, type TabDescriptor } from '../components/Tabs'
import { MemoTab } from '../components/MemoTab'
import { NoteInfoTab } from '../components/NoteInfoTab'
import { LinkedDocsTab } from '../components/LinkedDocsTab'
import { NotebookLinksTab, NotebookTagsTab } from '../components/NotebookAggregateTabs'
import { TagPane } from '../components/TagPane'
import { useApp } from '../state/appStore'
import type { RightTab } from '../state/paneState'

// The right pane follows the selection: with a note selected it shows that
// note's memo timeline, info and links; with only a notebook open it shows the
// notebook-wide aggregates (all memos with note attribution, deduped tags,
// all links). Agent chat and plain memos share the Agent tab. A tag selection
// (`?tag=` on the route) replaces all of it with the cross-notebook tag pane.

export function RightPane(): JSX.Element {
  const app = useApp()
  const noteMode = createMemo(() => Boolean(app.state.noteId))
  const tagId = createMemo(() => app.tagPaneTagId())
  const tabs = createMemo<readonly TabDescriptor<RightTab>[]>(() => noteMode()
    ? [
        { value: 'memo', label: 'Agent' },
        { value: 'info', label: 'Info' },
        { value: 'links', label: 'Links' },
      ]
    : [
        { value: 'memo', label: 'Agent' },
        { value: 'info', label: 'Tags' },
        { value: 'links', label: 'Links' },
      ])
  return (
    <aside class="pane pane-right" aria-label={tagId() ? 'Tag details' : noteMode() ? 'Note details' : 'Notebook details'}>
      <Show
        when={app.state.pane.rightOpen}
        fallback={
          <div class="pane-rail">
            <button
              type="button"
              class="rail-button"
              aria-label="Open the details pane"
              aria-expanded={false}
              onClick={app.toggleRightPane}
            >‹</button>
            <span class="rail-label">Agent</span>
          </div>
        }
      >
        <Show when={!tagId()} fallback={<TagPane tagId={tagId() as TagId} />}>
        <div class="pane-head">
          <button
            type="button"
            class="pane-fold"
            aria-label="Collapse the details pane"
            aria-expanded={true}
            onClick={app.toggleRightPane}
          >›</button>
          <Tabs
            label={noteMode() ? 'Note details' : 'Notebook details'}
            tabs={tabs()}
            active={app.state.pane.rightTab}
            idPrefix="right"
            onSelect={app.setRightTab}
          />
        </div>
        <div class="pane-body">
          <TabPanel idPrefix="right" value="memo" active={app.state.pane.rightTab}>
            <MemoTab />
          </TabPanel>
          <TabPanel idPrefix="right" value="info" active={app.state.pane.rightTab}>
            <Show when={noteMode()} fallback={<NotebookTagsTab />}>
              <NoteInfoTab />
            </Show>
          </TabPanel>
          <TabPanel idPrefix="right" value="links" active={app.state.pane.rightTab}>
            <Show when={noteMode()} fallback={<NotebookLinksTab />}>
              <LinkedDocsTab />
            </Show>
          </TabPanel>
        </div>
        </Show>
      </Show>
    </aside>
  )
}
