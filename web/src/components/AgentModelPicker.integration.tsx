import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import { AgentModelPicker } from './AgentModelPicker'

test('filters all vendors by substring and selects model and provider together', () => {
  const host = document.createElement('div'); document.body.append(host)
  const select = vi.fn()
  const dispose = render(() => <AgentModelPicker disabled={false} selectedModel="gpt-6.1-sol" selectedProvider="server:codex"
    models={[{ modelId: 'gpt-6.1-sol', provider: 'server:codex' }, { modelId: 'claude-opus-5-5', provider: 'server:claude-code' }, { modelId: 'gemini-4-argon', provider: 'server:gemini' }]}
    onSelect={select} />, host)
  try {
    const input = host.querySelector<HTMLInputElement>('[role="combobox"]')!
    input.focus(); expect(host.querySelectorAll('[role="option"]')).toHaveLength(3)
    input.value = 'PUS'; input.dispatchEvent(new Event('input', { bubbles: true }))
    expect(host.querySelectorAll('[role="option"]')).toHaveLength(1)
    expect(host.querySelector('[role="option"]')?.textContent).toContain('Claude')
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }))
    expect(select).toHaveBeenCalledWith('claude-opus-5-5', 'server:claude-code')
    expect(input.getAttribute('aria-expanded')).toBe('false')
    input.blur(); input.focus(); input.value = 'argon'; input.dispatchEvent(new Event('input', { bubbles: true }))
    expect(host.querySelectorAll('[role="option"]')).toHaveLength(1)
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }))
    expect(input.getAttribute('aria-expanded')).toBe('false')
  } finally { dispose(); host.remove() }
})
