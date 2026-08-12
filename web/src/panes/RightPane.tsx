import { Show, type JSX } from 'solid-js'
import { TabPanel, Tabs, type TabDescriptor } from '../components/Tabs'
import { MemoListTab } from '../components/MemoListTab'
import { NoteInfoTab } from '../components/NoteInfoTab'
import { LinkedDocsTab } from '../components/LinkedDocsTab'
import { AgentChatTab } from '../components/AgentChatTab'
import { useApp } from '../state/appStore'
import type { RightTab } from '../state/paneState'

const tabs: readonly TabDescriptor<RightTab>[] = [
  { value: 'memos', label: 'Memos' },
  { value: 'info', label: 'Info' },
  { value: 'links', label: 'Links' },
  { value: 'chat', label: 'Chat' },
]

export function RightPane(): JSX.Element {
  const app = useApp()
  return (
    <aside class="pane pane-right" aria-label="Note details">
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
            <span class="rail-label">Details</span>
          </div>
        }
      >
        <div class="pane-head">
          <button
            type="button"
            class="pane-fold"
            aria-label="Collapse the details pane"
            aria-expanded={true}
            onClick={app.toggleRightPane}
          >›</button>
          <Tabs
            label="Note details"
            tabs={tabs}
            active={app.state.pane.rightTab}
            idPrefix="right"
            onSelect={app.setRightTab}
          />
        </div>
        <div class="pane-body">
          <TabPanel idPrefix="right" value="memos" active={app.state.pane.rightTab}>
            <MemoListTab />
          </TabPanel>
          <TabPanel idPrefix="right" value="info" active={app.state.pane.rightTab}>
            <NoteInfoTab />
          </TabPanel>
          <TabPanel idPrefix="right" value="links" active={app.state.pane.rightTab}>
            <LinkedDocsTab />
          </TabPanel>
          <TabPanel idPrefix="right" value="chat" active={app.state.pane.rightTab}>
            <AgentChatTab />
          </TabPanel>
        </div>
      </Show>
    </aside>
  )
}
