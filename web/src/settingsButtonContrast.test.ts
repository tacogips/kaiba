import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, test } from 'bun:test'

const css = readFileSync(resolve(import.meta.dir, 'light-theme.css'), 'utf8')
const rootBlock = css.match(/:root\s*\{([^}]*)\}/)?.[1]
if (!rootBlock) throw new Error('light-theme.css is missing its :root token block')
const tokens = new Map([...rootBlock.matchAll(/--([\w-]+):\s*(#[\da-fA-F]{6});/g)]
  .map(([, name, value]) => [name, value]))

function ruleBody(selector: string): string {
  const start = css.indexOf(selector)
  if (start < 0) throw new Error(`Missing CSS selector: ${selector}`)
  const open = css.indexOf('{', start + selector.length)
  const close = css.indexOf('}', open + 1)
  if (open < 0 || close < 0) throw new Error(`Malformed CSS rule: ${selector}`)
  return css.slice(open + 1, close).replace(/\s+/g, ' ')
}

function luminance(hex: string): number {
  const channels = hex.slice(1).match(/../g)?.map((channel) => Number.parseInt(channel, 16) / 255)
  if (!channels || channels.length !== 3) throw new Error(`Invalid color: ${hex}`)
  const [red = 0, green = 0, blue = 0] = channels.map((value) => {
    return value <= 0.03928 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4
  })
  return 0.2126 * red + 0.7152 * green + 0.0722 * blue
}

function contrast(foreground: string, background: string): number {
  const values = [luminance(foreground), luminance(background)].sort((a, b) => b - a)
  const lighter = Math.max(...values)
  const darker = Math.min(...values)
  return (lighter + 0.05) / (darker + 0.05)
}

function token(name: string): string {
  const value = tokens.get(name)
  if (!value) throw new Error(`Missing color token: --${name}`)
  return value
}

describe('Settings button contrast', () => {
  test('scopes primary, hover, and selected rules with the intended tokens and order', () => {
    const primary = '.chatbook .config-section button:not(.secondary)'
    const hover = '.chatbook .config-section button:not(.secondary):hover:not(:disabled)'
    const selected = '.chatbook .config-section button[aria-pressed="true"]'
    const primaryBody = ruleBody(primary)
    const hoverBody = ruleBody(hover)
    const selectedBody = ruleBody(selected)

    expect(primaryBody).toContain('color: var(--ink);')
    expect(primaryBody).toContain('border-color: var(--green-line);')
    expect(primaryBody).toContain('background: var(--green-primary);')
    expect(hoverBody).toContain('background: var(--green-hover);')
    expect(selectedBody).toContain('color: var(--green-ink);')
    expect(selectedBody).toContain('border-color: var(--green-focus);')
    expect(selectedBody).toContain('background: var(--green-selected);')
    expect(css.indexOf(selected)).toBeGreaterThan(css.indexOf(primary))
    expect([primaryBody, hoverBody, selectedBody].join(' ')).not.toContain('!important')
  })

  test('keeps primary, hover, selected, and selected-hover contrast at WCAG AA', () => {
    expect(tokens.size).toBeGreaterThanOrEqual(5)
    expect(contrast('#ffffff', '#000000')).toBeCloseTo(21, 0)
    expect(contrast(token('ink'), token('green-primary'))).toBeGreaterThanOrEqual(4.5)
    expect(contrast(token('ink'), token('green-hover'))).toBeGreaterThanOrEqual(4.5)
    expect(contrast(token('green-ink'), token('green-selected'))).toBeGreaterThanOrEqual(4.5)
    expect(contrast(token('green-ink'), token('green-hover'))).toBeGreaterThanOrEqual(4.5)
  })
})
