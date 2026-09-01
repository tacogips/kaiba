import { afterEach, describe, expect, test } from 'vitest'
import { createComponent } from 'solid-js'
import { render } from 'solid-js/web'
import type { SetUserAgentCredentialInput, UserAgentCredentialState } from '../notes/types'
import { UserAgentSettings, providerLabel } from './UserAgentSettings'

interface FakeClient {
  state: UserAgentCredentialState
  setCalls: SetUserAgentCredentialInput[]
  enabledCalls: boolean[]
  clearCalls: number
  userAgentCredential(): Promise<UserAgentCredentialState>
  setUserAgentCredential(input: SetUserAgentCredentialInput): Promise<UserAgentCredentialState>
  setUserAgentCredentialEnabled(enabled: boolean): Promise<UserAgentCredentialState>
  clearUserAgentCredential(): Promise<UserAgentCredentialState>
}

function fakeClient(initial: Partial<UserAgentCredentialState> = {}): FakeClient {
  const client: FakeClient = {
    state: {
      featureEnabled: true,
      customBaseURLAllowed: false,
      providers: ['anthropic', 'openai', 'openrouter', 'openai-compatible'],
      credential: null,
      ...initial,
    },
    setCalls: [],
    enabledCalls: [],
    clearCalls: 0,
    async userAgentCredential() { return client.state },
    async setUserAgentCredential(input) {
      client.setCalls.push(input)
      client.state = {
        ...client.state,
        credential: {
          provider: input.provider,
          keyHint: input.apiKey.slice(-4),
          baseURL: input.baseURL ?? null,
          defaultModel: input.defaultModel,
          enabled: input.enabled ?? true,
          updatedAt: '2026-09-01T00:00:00Z',
        },
      }
      return client.state
    },
    async setUserAgentCredentialEnabled(enabled) {
      client.enabledCalls.push(enabled)
      if (client.state.credential) {
        client.state = { ...client.state, credential: { ...client.state.credential, enabled } }
      }
      return client.state
    },
    async clearUserAgentCredential() {
      client.clearCalls += 1
      client.state = { ...client.state, credential: null }
      return client.state
    },
  }
  return client
}

function mount(client: FakeClient): { container: HTMLElement; dispose: () => void } {
  const container = document.createElement('div')
  document.body.appendChild(container)
  const dispose = render(() => createComponent(UserAgentSettings, { client }), container)
  return { container, dispose }
}

async function settle(): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, 0))
  await new Promise((resolve) => setTimeout(resolve, 0))
}

function setInput(container: HTMLElement, id: string, value: string): void {
  const input = container.querySelector(`#${id}`) as HTMLInputElement
  input.value = value
  input.dispatchEvent(new Event('input', { bubbles: true }))
}

const cleanups: Array<() => void> = []
afterEach(() => {
  while (cleanups.length) cleanups.pop()?.()
  document.body.innerHTML = ''
})

describe('UserAgentSettings', () => {
  test('saves a key through the client and never renders it back', async () => {
    const client = fakeClient()
    const { container, dispose } = mount(client)
    cleanups.push(dispose)
    await settle()

    setInput(container, 'user-agent-api-key', 'sk-test-secret-1234')
    setInput(container, 'user-agent-model', 'claude-opus-5')
    const form = container.querySelector('form') as HTMLFormElement
    form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
    await settle()

    expect(client.setCalls).toEqual([{
      provider: 'anthropic',
      apiKey: 'sk-test-secret-1234',
      defaultModel: 'claude-opus-5',
      baseURL: null,
      enabled: true,
    }])
    const status = container.querySelector('[data-testid="user-agent-status"]')?.textContent ?? ''
    expect(status).toContain('key ending in 1234')
    expect(status).toContain('claude-opus-5')
    expect(container.innerHTML).not.toContain('sk-test-secret-1234')
    const keyField = container.querySelector('#user-agent-api-key') as HTMLInputElement
    expect(keyField.value).toBe('')
  })

  test('refuses to submit without a key', async () => {
    const client = fakeClient()
    const { container, dispose } = mount(client)
    cleanups.push(dispose)
    await settle()

    setInput(container, 'user-agent-model', 'gpt-5')
    const form = container.querySelector('form') as HTMLFormElement
    form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
    await settle()

    expect(client.setCalls).toEqual([])
    expect(container.querySelector('[role="alert"]')?.textContent).toContain('Enter the API key')
  })

  test('toggles and removes a stored credential', async () => {
    const client = fakeClient({
      credential: {
        provider: 'openrouter',
        keyHint: 'ab12',
        baseURL: null,
        defaultModel: 'openai/gpt-5',
        enabled: true,
        updatedAt: '2026-09-01T00:00:00Z',
      },
    })
    const { container, dispose } = mount(client)
    cleanups.push(dispose)
    await settle()

    const buttons = () => [...container.querySelectorAll('button')] as HTMLButtonElement[]
    const disable = buttons().find((button) => button.textContent === 'Disable')
    expect(disable).toBeDefined()
    disable?.click()
    await settle()
    expect(client.enabledCalls).toEqual([false])
    expect(container.querySelector('[data-testid="user-agent-status"]')?.textContent).toContain('disabled')

    const remove = buttons().find((button) => button.textContent === 'Remove key')
    remove?.click()
    await settle()
    expect(client.clearCalls).toBe(1)
    expect(container.querySelector('[data-testid="user-agent-status"]')).toBeNull()
  })

  test('explains when the server has the feature off', async () => {
    const client = fakeClient({ featureEnabled: false })
    const { container, dispose } = mount(client)
    cleanups.push(dispose)
    await settle()

    expect(container.textContent).toContain('turned off on this server')
    expect(container.querySelector('form')).toBeNull()
  })

  test('labels providers for people', () => {
    expect(providerLabel('anthropic')).toBe('Anthropic')
    expect(providerLabel('openai-compatible')).toBe('OpenAI-compatible endpoint')
    expect(providerLabel('custom')).toBe('custom')
  })
})
