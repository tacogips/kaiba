import { createSignal } from 'solid-js'
import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import { PageRegionSelector } from './PageRegionSelector'
import { capturePageRegion } from '../notes/pageRegionCapture'
vi.mock('../notes/pageRegionCapture', async (original) => ({ ...await original<object>(), capturePageRegion: vi.fn(async () => new File(['image'], 'selection.png', { type: 'image/png' })) }))

test('selects an image region, opens the capture callback, and cancels on Escape or navigation', async () => {
  const host = document.createElement('div'); document.body.append(host)
  const canvas = document.createElement('canvas'); canvas.width = 1200; canvas.height = 1600
  canvas.getBoundingClientRect = () => new DOMRect(100, 100, 600, 800)
  const onCapture = vi.fn()
  const [key, setKey] = createSignal('page-1')
  const dispose = render(() => <PageRegionSelector canvas={() => canvas} sourceKey={key()} pageNumber={1} disabled={false} onCapture={onCapture} />, host)
  const trigger = host.querySelector<HTMLButtonElement>('button')!
  try {
    trigger.click()
    const layer = host.querySelector<HTMLElement>('[role="dialog"]')!
    layer.getBoundingClientRect = () => new DOMRect(0, 0, 800, 1000)
    const pointer = (type: string, x: number, y: number) => layer.dispatchEvent(new PointerEvent(type, { clientX: x, clientY: y, pointerId: 1, button: 0, bubbles: true }))
    pointer('pointerdown', 200, 300); pointer('pointermove', 400, 500); pointer('pointerup', 400, 500)
    await vi.waitFor(() => expect(onCapture).toHaveBeenCalledOnce())
    expect(capturePageRegion).toHaveBeenCalledWith(canvas, { x: 200, y: 400, width: 400, height: 400 }, expect.stringContaining('page-1-selection'))
    expect(host.querySelector('[role="dialog"]')).toBeNull()
    trigger.click()
    host.querySelector('[role="dialog"]')!.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
    expect(host.querySelector('[role="dialog"]')).toBeNull()
    trigger.click(); setKey('page-2')
    expect(host.querySelector('[role="dialog"]')).toBeNull()
  } finally { dispose(); host.remove() }
})
