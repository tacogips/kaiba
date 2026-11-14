export type PageRegionSource = HTMLCanvasElement | HTMLImageElement

export interface RegionRect { x: number; y: number; width: number; height: number }

/** Map CSS pixels on a zoomed/scrolled page to its actual canvas pixels. */
export function canvasRegion(canvas: Pick<HTMLCanvasElement, 'width' | 'height'>, bounds: Pick<DOMRect, 'left' | 'top' | 'width' | 'height'>,
  start: { x: number; y: number }, end: { x: number; y: number }): RegionRect {
  if (bounds.width <= 0 || bounds.height <= 0) throw new Error('The page is not ready for capture.')
  const left = Math.max(bounds.left, Math.min(start.x, end.x))
  const top = Math.max(bounds.top, Math.min(start.y, end.y))
  const right = Math.min(bounds.left + bounds.width, Math.max(start.x, end.x))
  const bottom = Math.min(bounds.top + bounds.height, Math.max(start.y, end.y))
  const x = Math.max(0, Math.floor((left - bounds.left) * canvas.width / bounds.width))
  const y = Math.max(0, Math.floor((top - bounds.top) * canvas.height / bounds.height))
  return { x, y, width: Math.max(0, Math.min(canvas.width - x, Math.ceil((right - left) * canvas.width / bounds.width))),
    height: Math.max(0, Math.min(canvas.height - y, Math.ceil((bottom - top) * canvas.height / bounds.height))) }
}

export async function capturePageRegion(source: PageRegionSource, region: RegionRect, filename: string): Promise<File> {
  if (region.width < 2 || region.height < 2) throw new Error('Select a larger area of the page.')
  const crop = document.createElement('canvas')
  const scale = Math.min(1, 1600 / Math.max(region.width, region.height))
  crop.width = Math.max(1, Math.round(region.width * scale)); crop.height = Math.max(1, Math.round(region.height * scale))
  const context = crop.getContext('2d')
  if (!context) throw new Error('Image capture is unavailable.')
  context.fillStyle = '#fff'; context.fillRect(0, 0, crop.width, crop.height)
  context.drawImage(source, region.x, region.y, region.width, region.height, 0, 0, crop.width, crop.height)
  const encode = (type: string, quality?: number) => new Promise<Blob>((resolve, reject) => {
    crop.toBlob((blob) => blob ? resolve(blob) : reject(new Error('The selected image could not be created.')), type, quality)
  })
  let image = await encode('image/png')
  if (image.size > 1_048_576) image = await encode('image/jpeg', .8)
  if (image.size > 1_048_576) throw new Error('The selected image is too large. Select a smaller area.')
  return new File([image], `${filename}.${image.type === 'image/png' ? 'png' : 'jpg'}`, { type: image.type })
}
