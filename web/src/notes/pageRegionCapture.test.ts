import { describe, expect, test } from 'bun:test'
import { canvasRegion } from './pageRegionCapture'

describe('Page selection image coordinates', () => {
  test('accounts for zoom, device pixels, scroll offset, and a reversed drag', () => {
    expect(canvasRegion({ width: 1200, height: 1600 }, { left: -50, top: -100, width: 600, height: 800 },
      { x: 250, y: 300 }, { x: 50, y: 100 })).toEqual({ x: 200, y: 400, width: 400, height: 400 })
  })
  test('clips a selection to the actual page image', () => {
    expect(canvasRegion({ width: 600, height: 800 }, { left: 50, top: 100, width: 600, height: 800 },
      { x: 0, y: 0 }, { x: 1000, y: 1000 })).toEqual({ x: 0, y: 0, width: 600, height: 800 })
  })
})
