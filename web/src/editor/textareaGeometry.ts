// Text-position geometry for a <textarea>. A textarea exposes no layout for
// its characters, so a hidden mirror <div> with the same box and font metrics
// lays the value out again and DOM Ranges over the mirror's single text node
// measure any position. Soft-wrapped lines therefore measure correctly, which
// a "line index * line height" estimate gets wrong. Without layout (a test DOM
// or a detached textarea) every query returns null and callers fall back to
// line-height estimates.

const copiedStyles = [
  'fontFamily', 'fontSize', 'fontWeight', 'fontStyle', 'fontVariant', 'fontStretch', 'fontFeatureSettings',
  'letterSpacing', 'wordSpacing', 'lineHeight', 'textTransform', 'textIndent', 'tabSize',
  'paddingTop', 'paddingRight', 'paddingBottom', 'paddingLeft',
  'whiteSpace', 'overflowWrap', 'wordBreak', 'direction',
] as const

/** A position's box in the textarea's unscrolled padding-box coordinates. */
export interface TextRect { top: number; bottom: number; left: number }

export class TextareaGeometry {
  private mirror: HTMLDivElement | null = null
  private node: Text | null = null
  private layoutKey = ''

  constructor(private readonly textarea: HTMLTextAreaElement) {}

  lineHeight(): number {
    const view = this.textarea.ownerDocument.defaultView
    const style = view?.getComputedStyle(this.textarea)
    const line = Number.parseFloat(style?.lineHeight ?? '')
    if (Number.isFinite(line) && line > 0) return line
    const font = Number.parseFloat(style?.fontSize ?? '')
    return Number.isFinite(font) && font > 0 ? font * 1.2 : 20
  }

  rect(pos: number): TextRect | null {
    const node = this.prepare()
    if (!node || !this.mirror) return null
    const length = node.data.length
    const at = Math.max(0, Math.min(pos, length - 1))
    const range = this.textarea.ownerDocument.createRange()
    range.setStart(node, at)
    range.setEnd(node, at + 1)
    const box = range.getClientRects()[0] ?? range.getBoundingClientRect()
    if (!box || box.height <= 0) return null
    const origin = this.mirror.getBoundingClientRect()
    return { top: box.top - origin.top, bottom: box.bottom - origin.top, left: box.left - origin.left }
  }

  /** Viewport (fixed-position) coordinates of a position, for overlays. */
  clientPoint(pos: number): { top: number; left: number; height: number } | null {
    const rect = this.rect(pos)
    if (!rect) return null
    const box = this.textarea.getBoundingClientRect()
    return {
      top: box.top + this.textarea.clientTop + rect.top - this.textarea.scrollTop,
      left: box.left + this.textarea.clientLeft + rect.left - this.textarea.scrollLeft,
      height: rect.bottom - rect.top,
    }
  }

  /** Measured selection boxes, including wrapped and full-width characters. */
  clientRangeRects(from: number, to: number): { top: number; left: number; width: number; height: number }[] {
    return this.clientRangesRects([{ from, to }])
  }

  clientRangesRects(ranges: readonly { from: number; to: number }[]): { top: number; left: number; width: number; height: number }[] {
    const node = this.prepare()
    if (!node || !this.mirror) return []
    const range = this.textarea.ownerDocument.createRange()
    const origin = this.mirror.getBoundingClientRect(), box = this.textarea.getBoundingClientRect()
    return ranges.flatMap(({ from, to }) => {
      if (to <= from) return []
      range.setStart(node, Math.min(from, node.data.length))
      range.setEnd(node, Math.min(to, node.data.length))
      return Array.from(range.getClientRects()).flatMap((rect) => {
        const top = Math.max(box.top, box.top + this.textarea.clientTop + rect.top - origin.top - this.textarea.scrollTop)
        const left = Math.max(box.left, box.left + this.textarea.clientLeft + rect.left - origin.left - this.textarea.scrollLeft)
        const bottom = Math.min(box.bottom, box.top + this.textarea.clientTop + rect.bottom - origin.top - this.textarea.scrollTop)
        const right = Math.min(box.right, box.left + this.textarea.clientLeft + rect.right - origin.left - this.textarea.scrollLeft)
        return bottom > top && right > left ? [{ top, left, width: right - left, height: bottom - top }] : []
      })
    })
  }

  isVisible(pos: number): boolean {
    const rect = this.rect(pos)
    if (!rect) return true
    const { scrollTop, scrollLeft, clientHeight, clientWidth } = this.textarea
    return rect.top >= scrollTop && rect.bottom <= scrollTop + clientHeight && rect.left >= scrollLeft && rect.left <= scrollLeft + clientWidth
  }

  /** Scrolls the textarea just enough to show `pos`. */
  reveal(pos: number, fallbackLine: number): void {
    const textarea = this.textarea
    const rect = this.rect(pos) ?? { top: (fallbackLine - 1) * this.lineHeight(), bottom: fallbackLine * this.lineHeight(), left: 0 }
    if (rect.top < textarea.scrollTop) textarea.scrollTop = Math.max(0, rect.top - this.lineHeight() / 2)
    else if (rect.bottom > textarea.scrollTop + textarea.clientHeight) textarea.scrollTop = rect.bottom - textarea.clientHeight + this.lineHeight() / 2
  }

  dispose(): void {
    this.mirror?.remove()
    this.mirror = null
    this.node = null
    this.layoutKey = ''
  }

  private prepare(): Text | null {
    const textarea = this.textarea
    const doc = textarea.ownerDocument
    const view = doc.defaultView
    if (!view || !textarea.isConnected || textarea.clientWidth <= 0) return null
    if (!this.mirror) {
      const mirror = doc.createElement('div')
      mirror.setAttribute('aria-hidden', 'true')
      Object.assign(mirror.style, { position: 'absolute', top: '0', left: '-100000px', visibility: 'hidden', pointerEvents: 'none', boxSizing: 'border-box', border: '0', margin: '0', overflow: 'hidden' })
      this.node = doc.createTextNode('')
      mirror.append(this.node)
      doc.body.append(mirror)
      this.mirror = mirror
    }
    const style = view.getComputedStyle(textarea)
    const key = [textarea.clientWidth, ...copiedStyles.map((name) => style[name])].join('|')
    if (key !== this.layoutKey) {
      for (const name of copiedStyles) this.mirror.style[name] = style[name]
      this.mirror.style.width = `${textarea.clientWidth}px`
      if (!style.whiteSpace || style.whiteSpace === 'normal') this.mirror.style.whiteSpace = 'pre-wrap'
      this.layoutKey = key
    }
    // The trailing zero-width space gives the end-of-text position a box.
    const text = `${textarea.value}\u200b`
    if (this.node!.data !== text) this.node!.data = text
    return this.node
  }
}
