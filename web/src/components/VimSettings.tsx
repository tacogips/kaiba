import { For, Show, createEffect, createSignal, on, type JSX } from 'solid-js'
import { useApp } from '../state/appStore'
import { vimModeEnabled } from '../notes/settings'
import { KEYMAP_PRESETS, compileUserKeymap, defaultKeymapText, type KeymapIssue } from '../editor/vimKeymap'
import './form-controls.css'
import '../editor/vim-editor.css'
import { defaultWorkspaceVimKeys, parseWorkspaceVimKeys, workspaceVimKeysIssue, type WorkspaceVimKeys } from '../notes/workspaceVimKeys'

/** The "Editor" card on the Config screen: the Vim mode switch (on by
 * default) and the keymap JSON editor. The keymap is stored with the other
 * web settings, so it follows the store across devices. */
export function VimSettings(): JSX.Element {
  const app = useApp()
  const stored = () => app.state.settings.vimKeymap
  const [text, setText] = createSignal(stored() ?? defaultKeymapText)
  const [edited, setEdited] = createSignal(false)
  const [issues, setIssues] = createSignal<readonly KeymapIssue[]>([])
  const [notice, setNotice] = createSignal('')
  const [workspaceError, setWorkspaceError] = createSignal('')

  // Settings load after the screen can render; adopt the stored keymap
  // unless the user has already started editing.
  createEffect(on(stored, (value) => { if (!edited()) setText(value ?? defaultKeymapText) }, { defer: true }))

  const edit = (value: string) => { setText(value); setEdited(true); setNotice('') }
  const apply = () => {
    const result = compileUserKeymap(text())
    setIssues(result.issues)
    if (!result.keymap) { setNotice('Keymap not applied: fix the errors below.'); return }
    app.updateSettings({ vimKeymap: text() })
    setEdited(false)
    const skipped = result.issues.filter((issue) => issue.severity === 'error').length
    setNotice(skipped ? `Keymap applied; ${skipped} ${skipped === 1 ? 'entry was' : 'entries were'} skipped.` : 'Keymap applied.')
  }
  const reset = () => {
    app.updateSettings({ vimKeymap: undefined })
    setText(defaultKeymapText)
    setEdited(false)
    setIssues([])
    setNotice('Using the built-in Vim bindings.')
  }

  return <section class="config-section vim-settings">
    <h2>Editor</h2>
    <label class="vim-settings-toggle">
      <input type="checkbox" checked={vimModeEnabled(app.state.settings)}
        onChange={(event) => app.updateSettings({ vimMode: event.currentTarget.checked })} />
      <span>Vim mode in Markdown editors</span>
    </label>
    <p>Editors open in normal mode. Press <kbd>i</kbd> to type, <kbd>Esc</kbd> to return, <kbd>:w</kbd> to save and <kbd>:q</kbd> to close.</p>
    <Show when={vimModeEnabled(app.state.settings)}>
      <details class="vim-settings-workspace">
        <summary>Workspace keybindings</summary>
        <p>Use Vim notation such as <code>{'<C-w>h'}</code>. The writing shortcut applies outside text fields.</p>
        <For each={Object.entries(defaultWorkspaceVimKeys)}>{([action, fallback]) =>
          <label>{({ write: 'Enter writing', left: 'Focus library', right: 'Focus details', bottom: 'Focus AI', reader: 'Focus reader', next: 'Next pane' } as Record<string, string>)[action]}
            <input aria-label={`Workspace key: ${action}`} value={app.state.settings.workspaceVimKeys?.[action as keyof WorkspaceVimKeys] ?? fallback}
              onChange={(event) => {
                const parsed = parseWorkspaceVimKeys({ [action]: event.currentTarget.value })
                if (!parsed[action as keyof WorkspaceVimKeys]) { setWorkspaceError('Enter a valid Vim key sequence.'); return }
                const next = { ...app.state.settings.workspaceVimKeys, ...parsed }
                const issue = workspaceVimKeysIssue(next)
                if (issue) { setWorkspaceError(issue); return }
                setWorkspaceError(''); app.updateSettings({ workspaceVimKeys: next })
              }} />
          </label>
        }</For>
        <Show when={workspaceError()}><p class="note-inline-error" role="alert">{workspaceError()}</p></Show>
        <button type="button" class="secondary" onClick={() => { setWorkspaceError(''); app.updateSettings({ workspaceVimKeys: undefined }) }}>Reset workspace keys</button>
      </details>
      <details class="vim-settings-keymap" open={Boolean(stored())}>
        <summary>Vim keybindings {stored() ? '(custom)' : '(built-in)'}</summary>
        <p>Edit the keymap JSON, then apply it. Each entry maps <code>lhs</code> to keys (<code>rhs</code>) or to an <code>action</code>:
          <code>kaiba.save</code>, <code>kaiba.close</code>, or the <code>hop.*</code> jumps when <code>hop.enabled</code> is true.
          Modes are <code>n</code>, <code>i</code>, <code>x</code>, <code>o</code> and <code>c</code> (command line).</p>
        <div class="config-presets" role="group" aria-label="Vim keymap presets">
          <For each={KEYMAP_PRESETS}>{(preset) =>
            <button type="button" class="secondary" aria-pressed={text() === preset.text}
              onClick={() => edit(preset.text)}>{preset.label}</button>}
          </For>
        </div>
        <textarea class="vim-settings-text" aria-label="Vim keymap JSON" spellcheck={false} rows={14}
          value={text()} onInput={(event) => edit(event.currentTarget.value)} />
        <div class="config-presets">
          <button type="button" onClick={apply}>Apply keymap</button>
          <button type="button" class="secondary" disabled={!stored()} onClick={reset}>Use built-in bindings</button>
        </div>
        <Show when={notice()}><p role="status">{notice()}</p></Show>
        <Show when={issues().length > 0}>
          <ul class="vim-settings-issues" aria-label="Keymap issues">
            <For each={issues()}>{(issue) => <li data-severity={issue.severity}><code>{issue.path}</code> {issue.message}</li>}</For>
          </ul>
        </Show>
      </details>
    </Show>
  </section>
}
