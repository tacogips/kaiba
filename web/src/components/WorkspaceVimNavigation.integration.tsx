import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import { AppStoreProvider, useApp, type AppStore } from '../state/appStore'
import type { NoteGraphQLClient } from '../notes/client'
import { WorkspaceVimNavigation } from './WorkspaceVimNavigation'
import { VimSettings } from './VimSettings'

test('workspace i works from another pane, while configurable Ctrl-W chords move panes without reaching the browser', async () => {
  const originalFetch = globalThis.fetch
  globalThis.fetch = (() => new Promise<Response>(() => undefined)) as unknown as typeof fetch
  const api = { initialize: async () => {}, streamHeaders: () => ({}), appSetting: async () => undefined,
    tags: async () => [], tagClasses: async () => [], notebooks: async () => [], setAppSetting: async () => {},
  } as unknown as NoteGraphQLClient
  const host = document.createElement('div'); document.body.append(host)
  let app!: AppStore
  const write = vi.fn(), focus = vi.fn()
  const command = (action: string) => { if (action === 'write') write(); else focus(action) }
  const View = () => { app = useApp(); return <><WorkspaceVimNavigation onCommand={command} blocked={() => false} /><button>Details</button><textarea /></> }
  const dispose = render(() => <AppStoreProvider options={{ client: api }}><View /></AppStoreProvider>, host)
  const press = (element: Element, key: string, init: KeyboardEventInit = {}) => {
    const event = new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true, ...init }); element.dispatchEvent(event); return event
  }
  try {
    for (let i = 0; i < 4; i++) await new Promise((resolve) => setTimeout(resolve, 0))
    const button = host.querySelector('button')!, textarea = host.querySelector('textarea')!
    button.focus(); expect(press(button, 'i').defaultPrevented).toBe(true); expect(write).toHaveBeenCalledTimes(1)
    textarea.focus(); expect(press(textarea, 'i').defaultPrevented).toBe(false); expect(write).toHaveBeenCalledTimes(1)
    const textbox = document.createElement('div'); textbox.setAttribute('role', 'textbox'); host.append(textbox)
    expect(press(textbox, 'i').defaultPrevented).toBe(false); expect(write).toHaveBeenCalledTimes(1)
    const editorKey = vi.fn(); textarea.addEventListener('keydown', editorKey)
    expect(press(textarea, 'w', { ctrlKey: true, code: 'KeyW' }).defaultPrevented).toBe(true)
    expect(press(textarea, 'h').defaultPrevented).toBe(true); expect(focus).toHaveBeenLastCalledWith('left')
    expect(editorKey).not.toHaveBeenCalled()
    for (const [key, pane] of [['l', 'right'], ['k', 'reader'], ['w', 'next']] as const) {
      press(textarea, 'Unidentified', { ctrlKey: true, code: 'KeyW' }); press(textarea, key)
      expect(focus).toHaveBeenLastCalledWith(pane)
    }
    const previous = focus.mock.calls.length
    press(textarea, 'w', { ctrlKey: true }); press(textarea, 'a', { metaKey: true }); press(textarea, 'h')
    expect(focus).toHaveBeenCalledTimes(previous)
    press(button, 'w', { ctrlKey: true }); press(button, 'j'); expect(focus).toHaveBeenLastCalledWith('bottom')
    app.updateSettings({ workspaceVimKeys: { write: 'e', reader: '<C-w>r' } })
    expect(press(button, 'i').defaultPrevented).toBe(false)
    press(button, 'e'); expect(write).toHaveBeenCalledTimes(2)
    press(button, 'w', { ctrlKey: true }); press(button, 'r'); expect(focus).toHaveBeenLastCalledWith('reader')
    const dialog = document.createElement('div'); dialog.setAttribute('role', 'dialog'); host.append(dialog)
    expect(press(button, 'e').defaultPrevented).toBe(false); expect(write).toHaveBeenCalledTimes(2)
  } finally { dispose(); host.remove(); globalThis.fetch = originalFetch }
})


test('workspace key settings persist through the actual settings controls and reset to defaults', async () => {
  const originalFetch = globalThis.fetch
  globalThis.fetch = (() => new Promise<Response>(() => undefined)) as unknown as typeof fetch
  const save = vi.fn(async (_key: string, _json: string) => {})
  const api = { initialize: async () => {}, streamHeaders: () => ({}), appSetting: async () => undefined,
    tags: async () => [], tagClasses: async () => [], notebooks: async () => [], setAppSetting: save,
  } as unknown as NoteGraphQLClient
  let app!: AppStore
  const Settings = () => { app = useApp(); return <VimSettings /> }
  const host = document.createElement('div'); document.body.append(host)
  const dispose = render(() => <AppStoreProvider options={{ client: api }}><Settings /></AppStoreProvider>, host)
  const settle = async () => { for (let i = 0; i < 4; i++) await new Promise((resolve) => setTimeout(resolve, 0)) }
  try {
    await settle()
    const input = host.querySelector<HTMLInputElement>('[aria-label="Workspace key: reader"]')!
    input.value = '<C-w>r'; input.dispatchEvent(new Event('change', { bubbles: true }))
    expect(app.state.settings.workspaceVimKeys?.reader).toBe('<C-w>r')
    app.settingsSave.retry(); await settle()
    expect(save).toHaveBeenLastCalledWith('web', expect.stringContaining('"workspaceVimKeys":{"reader":"<C-w>r"}'))
    ;[...host.querySelectorAll('button')].find((button) => button.textContent === 'Reset workspace keys')!.click()
    expect(app.state.settings.workspaceVimKeys).toBeUndefined(); expect(input.value).toBe('<C-w>k')
    app.settingsSave.retry(); await settle()
    expect(JSON.parse(save.mock.calls.at(-1)![1] as string)).not.toHaveProperty('workspaceVimKeys')
  } finally { dispose(); host.remove(); globalThis.fetch = originalFetch }
})

test('space and g prefixes list their next keys at the bottom right and run workspace commands', async () => {
  const originalFetch = globalThis.fetch
  globalThis.fetch = (() => new Promise<Response>(() => undefined)) as unknown as typeof fetch
  const api = { initialize: async () => {}, streamHeaders: () => ({}), appSetting: async () => undefined,
    tags: async () => [], tagClasses: async () => [], notebooks: async () => [], setAppSetting: async () => {},
  } as unknown as NoteGraphQLClient
  const host = document.createElement('div'); document.body.append(host)
  let app!: AppStore
  const command = vi.fn()
  const View = () => { app = useApp(); return <><WorkspaceVimNavigation onCommand={command} blocked={() => false} /><button>Reader</button><textarea /></> }
  const dispose = render(() => <AppStoreProvider options={{ client: api }}><View /></AppStoreProvider>, host)
  const press = (element: Element, key: string, init: KeyboardEventInit = {}) => {
    const event = new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true, ...init }); element.dispatchEvent(event); return event
  }
  const hints = () => host.querySelector('[aria-label="Workspace next keys"]')
  try {
    for (let i = 0; i < 4; i++) await new Promise((resolve) => setTimeout(resolve, 0))
    const button = host.querySelector('button')!, textarea = host.querySelector('textarea')!
    button.focus()
    expect(press(button, ' ').defaultPrevented).toBe(true)
    expect(hints()?.querySelector('.vim-hints-prefix')?.textContent).toBe('<Space>')
    const rows = [...hints()!.querySelectorAll('.vim-hints-row')].map((row) => row.textContent)
    expect(rows).toContain('<Space>wToggle Writing / Preview')
    expect(rows).toContain('<Space>aOpen / close AI')
    press(button, 'w'); expect(command).toHaveBeenLastCalledWith('writing', undefined); expect(hints()).toBeNull()
    press(button, ' '); press(button, 'Escape'); expect(hints()).toBeNull()
    press(button, ' '); press(button, 'a'); expect(command).toHaveBeenLastCalledWith('agent', undefined)

    press(button, 'g'); expect([...hints()!.querySelectorAll('kbd')].map((key) => key.textContent)).toEqual(expect.arrayContaining(['gp', 'gg']))
    press(button, 'g'); expect(command).toHaveBeenLastCalledWith('firstPage', undefined)
    press(button, 'G', { shiftKey: true }); expect(command).toHaveBeenLastCalledWith('lastPage', undefined)
    press(button, '1'); press(button, '2'); press(button, 'g')
    expect(hints()?.querySelector('.vim-hints-prefix')?.textContent).toBe('12g')
    press(button, 'p'); expect(command).toHaveBeenLastCalledWith('gotoPage', 12)

    const calls = command.mock.calls.length
    press(button, 'g'); press(button, 'p')
    const prompt = host.querySelector<HTMLInputElement>('[aria-label="Page number to go to"]')!
    expect(prompt).not.toBeNull(); expect(command).toHaveBeenCalledTimes(calls)
    prompt.value = '7'; prompt.form!.requestSubmit()
    expect(command).toHaveBeenLastCalledWith('gotoPage', 7)

    // Text fields keep g; a Vim editor in normal mode hands over the leader.
    expect(press(textarea, 'g').defaultPrevented).toBe(false)
    expect(press(textarea, ' ').defaultPrevented).toBe(false)
    textarea.dataset.vimMode = 'normal'
    expect(press(textarea, ' ').defaultPrevented).toBe(true); press(textarea, 'd')
    expect(command).toHaveBeenLastCalledWith('details', undefined)
    textarea.dataset.vimPending = 'true'
    expect(press(textarea, ' ').defaultPrevented).toBe(false)
    delete textarea.dataset.vimPending
    // A keymap that maps the leader in the editor keeps it there.
    app.updateSettings({ vimKeymap: JSON.stringify({ version: 1, leader: ' ', maps: { n: [{ lhs: '<leader>w', action: 'kaiba.save' }] } }) })
    expect(press(textarea, ' ').defaultPrevented).toBe(false)
    expect(press(button, ' ').defaultPrevented).toBe(true)
  } finally { dispose(); host.remove(); globalThis.fetch = originalFetch }
})
