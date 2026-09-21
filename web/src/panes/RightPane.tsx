import { For, Show, createMemo, type JSX } from 'solid-js'
import type { NotebookId, TagId } from '../notes/ids'
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

export function RightPane(props: { onClose?: () => void; conversationId?: NotebookId; onConversation?: (id: NotebookId) => void } = {}): JSX.Element {
  const app = useApp()
  const noteMode = createMemo(() => Boolean(app.state.noteId))
  const tagId = createMemo(() => app.tagPaneTagId())
  const tabs: readonly TabDescriptor<RightTab>[] = [
        { value: 'memo', label: 'AI' },
        { value: 'info', label: 'Tags' },
        { value: 'links', label: 'Links' },
        { value: 'history', label: 'History' },
      ]
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
            <span class="rail-label">AI / Tags / Links</span>
          </div>
        }
      >
        <div class="pane-head">
          <button
            type="button"
            class="pane-fold"
            aria-label="Collapse the details pane"
            aria-expanded={true}
            onClick={() => {
              app.toggleRightPane()
              props.onClose?.()
            }}
          >›</button>
          <Tabs
            label={noteMode() ? 'Note details' : 'Notebook details'}
            tabs={tabs}
            active={app.state.pane.rightTab}
            idPrefix="right"
            onSelect={(tab) => { app.closeTagPane(); app.setRightTab(tab) }}
          />
        </div>
        <Show when={!tagId()} fallback={<TagPane tagId={tagId() as TagId} />}>
        <div class="pane-body">
          <TabPanel idPrefix="right" value="memo" active={app.state.pane.rightTab}>
            <Show keyed when={props.conversationId} fallback={<MemoTab />}>
              {(id) => <MemoTab conversationNotebookId={id} />}
            </Show>
          </TabPanel>
          <TabPanel idPrefix="right" value="history" active={app.state.pane.rightTab}>
            <div class="agent-history">
              <For each={app.state.notebooks.filter((notebook) => notebook.type === 'AGENT_CHAT')}
                fallback={<p class="pane-empty">No conversations yet.</p>}>
                {(notebook) => <button type="button" class="tree-label" onClick={() => props.onConversation?.(notebook.notebookId)}>
                  <span class="tree-label-text">{notebook.title}</span>
                </button>}
              </For>
            </div>
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
